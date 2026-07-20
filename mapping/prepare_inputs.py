#!/usr/bin/env python3
"""
Convert a per-sample sheet into the per-run manifests the download jobs consume.

Input samples sheet (TSV/CSV) — one row per sample, minimum columns:
  sample_id, host_species, repo (ENA|SRA|GSA|CNGB), run_accessions (one or more, ';'-separated)
Optional: project, fastq_ftp (';'), fastq_md5 (';'), download_base (CNGB), gsa_part (GSA).

Outputs (in --outdir/manifests):
  reads.tsv   per-run rows for scripts/download_reads.sbatch   (ENA/SRA)
  cncb.tsv    per-run rows for scripts/download_cncb.sbatch    (GSA/CNGB)
Naming: basename = <sample_id>__<host_species_underscored>__<run>  (so mapping can find files by sample_id).

Usage: python prepare_inputs.py --samples samples.tsv --outdir OUT
"""
import argparse, csv, os, re

def us(s): return re.sub(r'\s+', '_', (s or "").strip())

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", required=True)
    ap.add_argument("--outdir", required=True)
    a = ap.parse_args()
    mdir = f"{a.outdir}/manifests"; os.makedirs(mdir, exist_ok=True)
    delim = "\t" if a.samples.endswith((".tsv", ".txt")) else ","
    reads = open(f"{mdir}/reads.tsv", "w", newline=""); cncb = open(f"{mdir}/cncb.tsv", "w", newline="")
    rw = csv.writer(reads, delimiter="\t"); cw = csv.writer(cncb, delimiter="\t")
    rw.writerow(["repo", "project", "run_accession", "sample_id", "host_species", "basename", "fastq_ftp", "fastq_md5"])
    cw.writerow(["repo", "project", "run", "sample_id", "host_species", "basename", "download_base", "gsa_part"])
    n_r = n_c = 0
    for row in csv.DictReader(open(a.samples), delimiter=delim):
        sid = (row.get("sample_id") or "").strip(); sp = (row.get("host_species") or "").strip()
        repo = (row.get("repo") or "ENA").strip().upper(); proj = (row.get("project") or "UNKNOWN").strip()
        runs = [r for r in re.split(r'[;, ]+', row.get("run_accessions", "") or "") if r]
        ftps = (row.get("fastq_ftp") or "").split("|"); md5s = (row.get("fastq_md5") or "").split("|")
        for i, run in enumerate(runs):
            base = f"{sid}__{us(sp)}__{run}"
            if repo in ("GSA", "CNGB"):
                cw.writerow([repo, proj, run, sid, sp, base, row.get("download_base", ""), row.get("gsa_part", "")]); n_c += 1
            else:
                rw.writerow(["ENA", proj, run, sid, sp, base, ftps[i] if i < len(ftps) else "", md5s[i] if i < len(md5s) else ""]); n_r += 1
    reads.close(); cncb.close()
    print(f"wrote {mdir}/reads.tsv ({n_r} runs) and {mdir}/cncb.tsv ({n_c} runs)")

if __name__ == "__main__":
    main()
