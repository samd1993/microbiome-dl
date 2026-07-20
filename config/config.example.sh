# =============================================================================
# metagenome-download-pipeline — configuration
# Copy to config/config.sh and edit for your environment. Everything is optional
# except OUTDIR; sensible defaults are used otherwise. Study-area agnostic:
# works for any host (human body sites, animal gut, environmental host-associated, etc.).
# =============================================================================

# ---- output ----------------------------------------------------------------
# All downloads + mapping land under here. Use an ABSOLUTE path that your compute
# nodes can see (e.g. shared scratch).
export OUTDIR="${OUTDIR:-/path/to/output/metagenome_dl}"

# ---- inputs ----------------------------------------------------------------
# Per-run reads manifest and host-species list — see docs/manifests.md.
export READS_MANIFEST="${READS_MANIFEST:-$OUTDIR/manifests/reads.tsv}"        # ENA/SRA runs
export CNCB_MANIFEST="${CNCB_MANIFEST:-$OUTDIR/manifests/cncb.tsv}"           # GSA/CNGB runs (optional)
export SAMPLES_TABLE="${SAMPLES_TABLE:-$OUTDIR/manifests/samples.tsv}"        # for genome resolution + mapping

# ---- software ---------------------------------------------------------------
# A conda env with: fastq-dl>=2.0, sra-tools, aria2, pigz, python>=3.9, curl, wget.
# Set CONDA_ENV to a name or an absolute prefix path; leave CONDA_BIN default.
# Leave both empty to use whatever is already on PATH.
export CONDA_BIN="${CONDA_BIN:-conda}"
export CONDA_ENV="${CONDA_ENV:-metagenome-dl}"

# ---- container (OPTIONAL) ----------------------------------------------------
# If your tools live inside an Apptainer/Singularity image, set CONTAINER to the
# .sif path and BINDS to the paths to mount. Each job will re-exec itself into the
# container automatically. Leave CONTAINER empty to run directly on the host.
export CONTAINER="${CONTAINER:-}"                 # e.g. /path/to/tools.sif
export BINDS="${BINDS:-}"                         # e.g. /scratch  or  /host/path:/in/container

# ---- Slurm ------------------------------------------------------------------
export SBATCH_PARTITION="${SBATCH_PARTITION:-short}"
export SBATCH_TIME="${SBATCH_TIME:-2-00:00:00}"
export SBATCH_ACCOUNT="${SBATCH_ACCOUNT:-}"       # optional --account
export SBATCH_QOS="${SBATCH_QOS:-}"               # optional --qos

# ---- tuning -----------------------------------------------------------------
export CHUNK="${CHUNK:-25}"          # runs per read-download array task
export CONC="${CONC:-10}"            # max concurrent array tasks (be nice to the archive)
export CPUS="${CPUS:-4}"             # cpus per read task (aria2c connections for fastq-dl)
export GENOME_JOBS="${GENOME_JOBS:-8}"   # concurrent genome downloads
export PER_RUN_MAX="${PER_RUN_MAX:-28800}"  # per-file wall cap (s) for slow mirrors (CNCB)

# ---- genome resolution ------------------------------------------------------
# Host reference genome sources + how far to climb taxonomy when a species has none.
export GENOME_SOURCES="${GENOME_SOURCES:-refseq genbank}"   # any of: refseq genbank
export FALLBACK_RANKS="${FALLBACK_RANKS:-species genus family order}"  # match order
export TOP_N_PER_HOST="${TOP_N_PER_HOST:-10}"   # subsample cap per host species (0 = keep all)
