#!/usr/bin/env python3
"""
Build the unified sample-level mapping that a downstream pipeline consumes: for every sample, its
local read paths + resolved host reference genome(s), plus a `priority` flag (top-N-per-host).

Study-area agnostic. One row per sample:
  sample_id, host_species, host_species_canonical, host_taxid, priority, layout,
  R1_path, R2_path, <src>_accession/<src>_match_rank/<src>_genome_path for each source,
  host_filtration_genome_paths (the FASTA[s] to subtract host reads against), status, notes

Reads local files from <outdir>/reads/**, genome files from <genome_dir>, resolution + canonical
from <resolved_dir> (produced by genomes/resolve_host_genomes.py).

Read files are matched to a sample by the naming convention:
  <outdir>/reads/<project>/<sample_id>__<...>_R{1,2}.fastq.gz   (SE: <sample_id>__<...>.fastq.gz)

Usage:
  python build_mapping.py --samples samples.tsv --outdir OUT --resolved-dir OUT/manifests \
         --sources refseq genbank --top-n 10 --output OUT/master_index.tsv
"""
import argparse, csv, glob, os, re
from collections import defaultdict
DEFAULT_PINNED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config", "pinned_genomes.tsv")

def load_pinned(path):
    """species -> (genome_path, label); these hosts use a fixed local genome (human/mouse T2T by default)."""
    pinned = {}
    try:
        for line in open(path or DEFAULT_PINNED):
            if line.startswith("#") or not line.strip(): continue
            f = line.rstrip("\n").split("\t")
            if len(f) >= 2 and f[0].strip(): pinned[f[0].strip()] = (f[1].strip(), f[2].strip() if len(f) > 2 else "")
    except FileNotFoundError: pass
    return pinned

def load_resolved(path):
    d = {}
    try:
        for r in csv.DictReader(open(path), delimiter="\t"): d[r["host_species"]] = r
    except FileNotFoundError: pass
    return d

def index_genomes(gdir):
    idx = {}
    for p in glob.glob(f"{gdir}/*.fna.gz"):
        m = re.search(r'(GC[AF]_\d+\.\d+)', os.path.basename(p))
        if m: idx[m.group(1)] = os.path.abspath(p)
    return idx

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", required=True)
    ap.add_argument("--outdir", required=True, help="dir containing reads/")
    ap.add_argument("--genome-dir", default=None, help="default <outdir>/host_genomes")
    ap.add_argument("--resolved-dir", default=None, help="default <outdir>/manifests")
    ap.add_argument("--sources", nargs="+", default=["refseq", "genbank"])
    ap.add_argument("--top-n", type=int, default=10, help="samples kept per host (0 = keep all)")
    ap.add_argument("--pinned", default=None, help="TSV of species using a fixed local genome; default config/pinned_genomes.tsv (human+mouse T2T)")
    ap.add_argument("--output", default=None)
    a = ap.parse_args()
    pinned = load_pinned(a.pinned)
    gdir = a.genome_dir or f"{a.outdir}/host_genomes"
    rdir = a.resolved_dir or f"{a.outdir}/manifests"
    out = a.output or f"{a.outdir}/master_index.tsv"

    resolved = {s: load_resolved(f"{rdir}/{s}_resolved.tsv") for s in a.sources}
    canon = {}
    try:
        for r in csv.DictReader(open(f"{rdir}/host_species_canonical.tsv"), delimiter="\t"):
            canon[r["host_species"]] = (r["host_species_canonical"], r["host_taxid"])
    except FileNotFoundError: pass
    GIDX = index_genomes(gdir)

    def reads_for(sample_id):
        r1 = sorted(glob.glob(f"{a.outdir}/reads/*/{sample_id}__*_R1.fastq.gz"))
        r2 = sorted(glob.glob(f"{a.outdir}/reads/*/{sample_id}__*_R2.fastq.gz"))
        se = [p for p in glob.glob(f"{a.outdir}/reads/*/{sample_id}__*.fastq.gz")
              if not p.endswith(("_R1.fastq.gz", "_R2.fastq.gz"))]
        r1 = [os.path.abspath(p) for p in r1] + [os.path.abspath(p) for p in se]
        r2 = [os.path.abspath(p) for p in r2]
        layout = "paired" if r2 else ("single" if se else "")
        return ";".join(r1), ";".join(r2), layout

    def depth(paths):
        t = 0
        for p in paths.split(";"):
            if p:
                try: t += os.path.getsize(p)
                except OSError: pass
        return t

    delim = "\t" if a.samples.endswith((".tsv", ".txt")) else ","
    src_cols = []
    for s in a.sources: src_cols += [f"{s}_accession", f"{s}_match_rank", f"{s}_genome_path"]
    COLS = (["sample_id", "host_species", "host_species_canonical", "host_taxid", "priority", "layout",
             "R1_path", "R2_path"] + src_cols + ["host_filtration_genome_paths", "n_filtration_genomes", "status", "notes"])
    rows = []
    for row in csv.DictReader(open(a.samples), delimiter=delim):
        sid = (row.get("sample_id") or "").strip(); sp = (row.get("host_species") or "").strip()
        if not sid: continue
        r1, r2, layout = reads_for(sid)
        can, tid = canon.get(sp, (sp, ""))
        rec = dict(sample_id=sid, host_species=sp, host_species_canonical=can, host_taxid=tid,
                   priority="", layout=layout, R1_path=r1, R2_path=r2,
                   status=("complete" if r1 else "no_reads"), notes=("host_unresolved" if sp.lower() in ("", "unknown") else ""))
        if sp in pinned:
            gpath, label = pinned[sp]
            for s in a.sources:
                rec[f"{s}_accession"] = ""; rec[f"{s}_match_rank"] = "pinned"; rec[f"{s}_genome_path"] = ""
            rec["host_filtration_genome_paths"] = gpath
            rec["n_filtration_genomes"] = "1"
            rec["notes"] = f"pinned:{label}" if label else "pinned"
        else:
            fpaths = []
            for s in a.sources:
                g = resolved.get(s, {}).get(sp, {})
                acc = g.get("accession", ""); gp = GIDX.get(acc, "")
                rec[f"{s}_accession"] = acc; rec[f"{s}_match_rank"] = g.get("match_rank", ""); rec[f"{s}_genome_path"] = gp
                if gp: fpaths.append(gp)
            rec["host_filtration_genome_paths"] = ";".join(fpaths)
            rec["n_filtration_genomes"] = str(len(fpaths))
            if not fpaths and rec["notes"] != "host_unresolved": rec["notes"] = "no_host_genome"
        rec["_depth"] = depth(r1) + depth(r2); rec["_sp"] = sp
        rows.append(rec)

    # priority = top-N per host species (by read depth); keep all if <=N or top_n==0
    if a.top_n and a.top_n > 0:
        grp = defaultdict(list)
        for i, r in enumerate(rows): grp[r["_sp"]].append(i)
        for sp, idxs in grp.items():
            idxs.sort(key=lambda i: rows[i]["_depth"], reverse=True)
            for rank, i in enumerate(idxs): rows[i]["priority"] = "yes" if rank < a.top_n else "no"
    else:
        for r in rows: r["priority"] = "yes"

    with open(out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=COLS, delimiter="\t", extrasaction="ignore"); w.writeheader()
        for r in rows: w.writerow(r)
    from collections import Counter
    print(f"wrote {out}: {len(rows)} samples")
    print("  priority=yes:", sum(1 for r in rows if r["priority"] == "yes"))
    print("  distinct host species:", len({r["_sp"] for r in rows if r["_sp"]}),
          "| canonical:", len({r["host_species_canonical"] for r in rows if r["host_species_canonical"]}))
    print("  status:", dict(Counter(r["status"] for r in rows)))

if __name__ == "__main__":
    main()
