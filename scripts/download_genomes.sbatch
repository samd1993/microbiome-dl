#!/bin/bash
#SBATCH --job-name=mgdl_genomes
#SBATCH --time=2-00:00:00
#SBATCH --mem=4G
#SBATCH --cpus-per-task=8
#SBATCH --output=slurm-genomes-%j.log
# ---------------------------------------------------------------------------------------------
# Download host reference genomes (RefSeq/GenBank FASTAs) with aria2c. Resume-safe; verifies gzip;
# falls back to NCBI FTP dir-listing if a constructed URL misses.
# Consumes a genome download list produced by genomes/resolve_host_genomes.py:
#   accession  species  assembly_name  target_filename  ftp_url
# Output: $OUTDIR/host_genomes/<target_filename>
#   sbatch scripts/download_genomes.sbatch          # uses $OUTDIR/manifests/genomes_download.tsv
# ---------------------------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pipeline_reenter "$@"
activate_env

LIST="${GENOME_LIST:-$OUTDIR/manifests/genomes_download.tsv}"
DEST="${GENOME_DIR:-$OUTDIR/host_genomes}"; JOBS="${GENOME_JOBS:-8}"
[[ -f "$LIST" ]] || { echo "FATAL: genome list not found: $LIST"; exit 1; }
mkdir -p "$DEST" "$OUTDIR/logs"
ARIA_IN="$OUTDIR/logs/aria2_genomes.txt"; FAILED="$OUTDIR/logs/genomes_failed.tsv"; : > "$ARIA_IN"; : > "$FAILED"

todo=0; have=0
while IFS=$'\t' read -r acc sp asm target url; do
  [[ "$acc" == "accession" || -z "${url:-}" ]] && continue
  if [[ -s "$DEST/$target" ]] && $GZT "$DEST/$target" 2>/dev/null; then have=$((have+1)); continue; fi
  [[ -e "$DEST/$target" ]] && rm -f "$DEST/$target"
  printf '%s\n  out=%s\n  dir=%s\n' "$url" "$target" "$DEST" >> "$ARIA_IN"; todo=$((todo+1))
done < "$LIST"
echo "[$(date +%T)] genomes: $todo to fetch, $have already valid -> $DEST"

if [[ $todo -gt 0 ]] && command -v aria2c >/dev/null; then
  aria2c -i "$ARIA_IN" -j "$JOBS" -x 4 -s 4 -c --auto-file-renaming=false --max-tries=5 --retry-wait=15 --console-log-level=warn || echo "WARN: aria2c returned non-zero"
fi

echo "[$(date +%T)] verifying + dir-listing fallback ..."
ok=0; bad=0
while IFS=$'\t' read -r acc sp asm target url; do
  [[ "$acc" == "accession" || -z "${target:-}" ]] && continue
  if [[ -s "$DEST/$target" ]] && $GZT "$DEST/$target" 2>/dev/null; then ok=$((ok+1)); continue; fi
  p=$(echo "$acc" | sed -E 's/GC[AF]_([0-9]{3})([0-9]{3})([0-9]{3}).*/\1\/\2\/\3/')
  real=$(curl -s --max-time 40 "https://ftp.ncbi.nlm.nih.gov/genomes/all/${acc:0:3}/$p/" | grep -oE "${acc}[^\"/]*" | head -1)
  [[ -n "$real" ]] && aria2c "https://ftp.ncbi.nlm.nih.gov/genomes/all/${acc:0:3}/$p/$real/${real}_genomic.fna.gz" --dir "$DEST" --out "$target" -x4 -s4 -c --max-tries=3 --console-log-level=warn 2>/dev/null
  if [[ -s "$DEST/$target" ]] && $GZT "$DEST/$target" 2>/dev/null; then ok=$((ok+1)); else bad=$((bad+1)); printf '%s\t%s\t%s\t%s\n' "$acc" "$sp" "$target" "$url" >> "$FAILED"; fi
done < "$LIST"
echo "[$(date +%T)] genomes done. valid=$ok missing/corrupt=$bad (in $DEST)"
[[ $bad -gt 0 ]] && echo "  failures -> $FAILED (rerun to retry)"
exit 0
