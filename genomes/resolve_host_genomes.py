#!/usr/bin/env python3
"""
Resolve a host reference genome for every host species in a samples table, from NCBI.

Study-area agnostic: "host" is whatever your metagenomes come from (human body site, animal gut,
insect, environmental host, ...). For a human-microbiome study this simply resolves Homo sapiens.

For each unique host_species and each requested source (refseq/genbank), it matches by
Species -> Genus -> Family -> Order (configurable) and picks the best assembly
(NCBI 'representative' first, then most contiguous: assembly level, then scaffold/contig N50, then size).
Also records the NCBI-canonical scientific name + taxid (collapses synonyms).

Inputs : a samples TSV/CSV with a `host_species` column (optional `genus`,`family`,`order` columns
         improve fallback; otherwise genus is derived from the species binomial).
Outputs (in --outdir):
  <source>_resolved.tsv          one row per host species (accession, match_rank, level, N50, ...)
  genomes_download.tsv           deduped download list for scripts/download_genomes.sbatch
  host_species_canonical.tsv     host_species -> canonical name + taxid

Usage:
  python resolve_host_genomes.py --samples samples.tsv --outdir OUT \
         --sources refseq genbank --fallback species genus family order
"""
import argparse, csv, json, sys, time, urllib.request, urllib.parse
API = "https://api.ncbi.nlm.nih.gov/datasets/v2/genome/taxon"
TAX = "https://api.ncbi.nlm.nih.gov/datasets/v2/taxonomy/taxon"
LEVELRANK = {"Complete Genome": 4, "Chromosome": 3, "Scaffold": 2, "Contig": 1}

def get(url):
    for a in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/json"}), timeout=60) as fh:
                return json.load(fh)
        except Exception as e:
            if a == 3: sys.stderr.write(f"  GET fail {url}: {e}\n"); return {}
            time.sleep(3 * (a + 1))

def sanitize(s): return __import__("re").sub(r'[^A-Za-z0-9._-]', '_', s or "")

def query(taxon, source):
    return get(f"{API}/{urllib.parse.quote(taxon)}/dataset_report?filters.assembly_source={source}&page_size=500").get("reports", []) or []

def best(reports):
    scored = []
    for r in reports:
        acc = r.get("accession")
        if not acc: continue
        ai = r.get("assembly_info", {}) or {}; st = r.get("assembly_stats", {}) or {}; org = r.get("organism", {}) or {}
        rep = 1 if ai.get("refseq_category") in ("reference genome", "representative genome") else 0
        n50 = int(st.get("scaffold_n50") or st.get("contig_n50") or 0)
        scored.append(((rep, LEVELRANK.get(ai.get("assembly_level"), 0), n50, int(st.get("total_sequence_length") or 0)), acc, ai, st, org))
    if not scored: return None
    scored.sort(key=lambda x: x[0], reverse=True); _, acc, ai, st, org = scored[0]
    return dict(accession=acc, organism=org.get("organism_name", ""), assembly_name=ai.get("assembly_name", ""),
                level=ai.get("assembly_level", ""), scaffold_n50=st.get("scaffold_n50", ""),
                total_len=st.get("total_sequence_length", ""), n_candidates=len(scored))

def canonical(name):
    d = get(f"{TAX}/{urllib.parse.quote(name)}")
    node = (d.get("taxonomy_nodes") or [{}])[0]; t = node.get("taxonomy", {}) or {}
    if node.get("errors") or not t.get("tax_id"): return (name, "")
    return (t.get("organism_name", name), str(t.get("tax_id", "")))

def ftp_url(acc, asm):
    p = acc.split("_")[1].split(".")[0]
    d = f"{acc}_{sanitize(asm)}"
    return f"https://ftp.ncbi.nlm.nih.gov/genomes/all/{acc[:3]}/{p[0:3]}/{p[3:6]}/{p[6:9]}/{d}/{d}_genomic.fna.gz"

def load_hosts(path):
    delim = "\t" if path.endswith((".tsv", ".txt")) else ","
    hosts = {}
    with open(path) as fh:
        for row in csv.DictReader(fh, delimiter=delim):
            sp = (row.get("host_species") or "").strip()
            if not sp or sp in hosts: continue
            genus = (row.get("genus") or "").strip() or sp.split()[0]
            hosts[sp] = dict(genus=genus, family=(row.get("family") or "").strip(), order=(row.get("order") or "").strip())
    return hosts

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--sources", nargs="+", default=["refseq", "genbank"])
    ap.add_argument("--fallback", nargs="+", default=["species", "genus", "family", "order"])
    ap.add_argument("--sleep", type=float, default=0.4)
    a = ap.parse_args()
    import os; os.makedirs(a.outdir, exist_ok=True)
    hosts = load_hosts(a.samples)
    print(f"{len(hosts)} unique host species", flush=True)

    cache = {}
    def resolve_cached(taxon, source):
        k = (taxon, source)
        if k not in cache: time.sleep(a.sleep); cache[k] = best(query(taxon, source))
        return cache[k]

    genomes = {}  # accession -> (species, assembly_name)
    for source in a.sources:
        rows = []
        for sp, lin in sorted(hosts.items()):
            chain = []
            for rk in a.fallback:
                t = sp if rk == "species" else lin.get(rk, "")
                if t: chain.append((t, rk))
            hit = rank = matched = ""
            for t, rk in chain:
                hit = resolve_cached(t, source)
                if hit: rank, matched = rk, t; break
            if hit:
                genomes.setdefault(hit["accession"], (sp, hit["assembly_name"]))
                rows.append(dict(host_species=sp, match_rank=rank, matched_taxon=matched, **hit))
            else:
                rows.append(dict(host_species=sp, match_rank="NONE", matched_taxon="", accession="", organism="",
                                 assembly_name="", level="", scaffold_n50="", total_len="", n_candidates=0))
        out = f"{a.outdir}/{source}_resolved.tsv"
        cols = ["host_species", "match_rank", "matched_taxon", "accession", "organism", "assembly_name", "level", "scaffold_n50", "total_len", "n_candidates"]
        with open(out, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=cols, delimiter="\t"); w.writeheader()
            for r in rows: w.writerow(r)
        from collections import Counter
        print(f"{source}: " + ", ".join(f"{k}={v}" for k, v in sorted(Counter(r['match_rank'] for r in rows).items())))

    # deduped download list
    with open(f"{a.outdir}/genomes_download.tsv", "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t"); w.writerow(["accession", "species", "assembly_name", "target_filename", "ftp_url"])
        for acc, (sp, asm) in sorted(genomes.items()):
            # name by matched organism accession so it's unambiguous regardless of which host it serves
            w.writerow([acc, sp, asm, f"{sanitize(sp)}__{acc}.fna.gz", ftp_url(acc, asm)])

    # canonical names
    with open(f"{a.outdir}/host_species_canonical.tsv", "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t"); w.writerow(["host_species", "host_species_canonical", "host_taxid"])
        for sp in sorted(hosts):
            time.sleep(a.sleep); can, tid = canonical(sp); w.writerow([sp, can, tid])
    print(f"wrote {a.outdir}/genomes_download.tsv ({len(genomes)} unique genomes) + canonical + per-source resolved")

if __name__ == "__main__":
    main()
