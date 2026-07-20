#!/bin/bash
# ---------------------------------------------------------------------------------------------
# One-shot submitter. Reads config, stages dirs, and submits the download jobs to Slurm,
# injecting cluster options (--partition/--time/--output/--account) so the .sbatch files stay portable.
#   bash scripts/submit_all.sh          # DRY RUN — prints the sbatch commands
#   bash scripts/submit_all.sh --go     # actually submit
# Toggle which stages run with env: DO_READS=1 DO_GENOMES=1 DO_CNCB=0 (defaults below).
# ---------------------------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
GO="${1:-}"
DO_READS="${DO_READS:-1}"; DO_GENOMES="${DO_GENOMES:-1}"; DO_CNCB="${DO_CNCB:-0}"
mkdir -p "$OUTDIR"/{reads,host_genomes,logs,manifests}
L="$OUTDIR/logs"
extra="$(sbatch_extra)"
COMMON="--partition=$SBATCH_PARTITION --time=$SBATCH_TIME$extra"

nrows(){ local f="$1"; [[ -f "$f" ]] || { echo 0; return; }; local n; n=$(grep -c . "$f"); head -1 "$f" | grep -qiP '^\s*repo\t' && n=$((n-1)); echo "$n"; }
uidx(){ echo $(( ($1 + $2 - 1)/$2 - 1 )); }
run(){ echo "+ $*"; [[ "$GO" == "--go" ]] && "$@" || true; }

echo "OUTDIR=$OUTDIR  partition=$SBATCH_PARTITION  (mode: ${GO:-dry-run})"; echo

if [[ "$DO_GENOMES" == 1 ]]; then
  echo "## host genomes"
  run sbatch $COMMON --output="$L/genomes_%j.log" "$HERE/download_genomes.sbatch"
fi
if [[ "$DO_READS" == 1 ]]; then
  n=$(nrows "$READS_MANIFEST"); u=$(uidx "$n" "$CHUNK")
  echo "## reads (ENA/SRA): $n runs -> array 0-$u%$CONC"
  run sbatch $COMMON --array=0-"$u"%"$CONC" --output="$L/reads_%A_%a.log" \
      --cpus-per-task="$CPUS" "$HERE/download_reads.sbatch"
fi
if [[ "$DO_CNCB" == 1 ]]; then
  n=$(nrows "$CNCB_MANIFEST"); cc="${CHUNK_CNCB:-10}"; u=$(uidx "$n" "$cc")
  echo "## CNCB (GSA/CNGB): $n runs -> array 0-$u%${CONC_CNCB:-3}  (CHUNK=$cc)"
  run env CHUNK="$cc" sbatch $COMMON --array=0-"$u"%"${CONC_CNCB:-3}" --output="$L/cncb_%A_%a.log" "$HERE/download_cncb.sbatch"
fi
echo; echo "Monitor:  bash $HERE/status.sh"
