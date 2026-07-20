# microbiome-dl

A study-area-agnostic pipeline to **download shotgun metagenome reads and their host reference
genomes**, and produce a single **sample → reads → host-genome mapping** for a downstream
host-read-filtration / assembly / MAG pipeline.

"Host" is whatever your samples come from — it works identically for **human microbiomes** (any body
site, any health condition), **animal gut**, insects, or any host-associated metagenome. You supply a
sample sheet; the pipeline fetches reads from ENA/SRA (and optionally GSA/CNGB), resolves and downloads
the appropriate RefSeq/GenBank **host** genome per species (with taxonomic fallback), and writes a
tidy mapping table.

## What it does
1. **Reads** — `fastq-dl` (ENA-first, SRA fallback, md5-checked), resume-safe Slurm array jobs. Optional GSA/CNGB downloader for Chinese-archive accessions.
2. **Host genomes** — resolves a genome per host species from NCBI (RefSeq and/or GenBank), matching **Species → Genus → Family → Order** and picking the *representative*, most-contiguous assembly; downloads via `aria2c`. Also records the NCBI-canonical name + taxid (collapses synonyms).
3. **Mapping** — one row per sample with local read paths, host-genome path(s) to filter against, and a `priority` flag = **top-N samples per host** (≤N keep all, >N keep the N most-sequenced).

## Requirements
- Slurm (jobs are `sbatch` arrays) and outbound HTTPS to ENA/NCBI (and CNCB if used).
- Tools via conda: `conda env create -f envs/environment.yml` (fastq-dl, sra-tools, aria2, pigz, python).
  Or point the pipeline at an existing env / Apptainer image (see **Config**).

## Quick start
```bash
git clone <this-repo> && cd microbiome-dl
cp config/config.example.sh config/config.sh     # then edit OUTDIR etc.
conda env create -f envs/environment.yml          # or set CONDA_ENV/CONTAINER in config

# 1. put your sample sheet at $OUTDIR/manifests/samples.tsv  (see docs/manifests.md, examples/samples.tsv)
python mapping/prepare_inputs.py --samples $OUTDIR/manifests/samples.tsv --outdir $OUTDIR
python genomes/resolve_host_genomes.py --samples $OUTDIR/manifests/samples.tsv --outdir $OUTDIR/manifests \
       --sources refseq genbank --fallback species genus family order

# 2. download (dry-run first, then --go)
bash scripts/submit_all.sh
bash scripts/submit_all.sh --go        # reads + genomes;  DO_CNCB=1 to also submit GSA/CNGB
bash scripts/status.sh                  # progress + failures

# 3. build the mapping your pipeline reads
python mapping/build_mapping.py --samples $OUTDIR/manifests/samples.tsv --outdir $OUTDIR \
       --resolved-dir $OUTDIR/manifests --sources refseq genbank --top-n 10 \
       --output $OUTDIR/master_index.tsv
```

## Config (`config/config.sh`)
All behavior is set here (see `config/config.example.sh`): `OUTDIR`, conda (`CONDA_ENV`) or
`CONTAINER`+`BINDS` (jobs auto re-exec into an Apptainer image if set), Slurm
(`SBATCH_PARTITION/TIME/ACCOUNT`), tuning (`CHUNK`, `CONC`, `CPUS`, `PER_RUN_MAX`), and genome options
(`GENOME_SOURCES`, `FALLBACK_RANKS`, `TOP_N_PER_HOST`). Nothing is hard-coded to a cluster or study.

## Outputs
```
$OUTDIR/
├── reads/<project>/<sample>__<host>__<run>_R{1,2}.fastq.gz   # SE: <...>.fastq.gz
├── host_genomes/<species>__<accession>.fna.gz                 # raw FASTAs (index with your own aligner)
├── manifests/  reads.tsv cncb.tsv *_resolved.tsv genomes_download.tsv host_species_canonical.tsv
├── logs/       per-task status + failure roll-ups
└── master_index.tsv                                           # the file your pipeline consumes
```

## Host-read filtration (intended use of the mapping)
For each sample: build an index from `host_filtration_genome_paths` (concatenate if >1), map trimmed
reads, keep the **unmapped** reads, then assemble/bin. `match_rank` tells you how close the reference is
(species = exact; genus/family/order = nearest available relative — a proxy that removes conserved host
DNA). Genomes are shipped raw (`.fna.gz`) so you index them with your preferred aligner.

## Notes
- **Resume-safe**: a target that already exists is skipped; re-submit the exact same array after a
  timeout/failure. `status.sh` writes a re-submittable failed-runs manifest.
- **CNCB (GSA/CNGB)** is slow/flaky — kept as a separate, resume-heavy job (`.part` files persist so
  `wget -c` continues large files across resubmits). Only needed if your accessions include it.
- **No container required** for downstream use — outputs are plain files with absolute paths.
- See `docs/manifests.md` for every file format.
