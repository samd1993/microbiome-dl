#!/bin/bash
#SBATCH --job-name=mgdl_reads
#SBATCH --time=2-00:00:00
#SBATCH --mem=8G
#SBATCH --cpus-per-task=4
#SBATCH --output=slurm-reads-%A_%a.log
# ---------------------------------------------------------------------------------------------
# Download ENA/SRA FASTQs for a chunk of runs with fastq-dl (ENA-first, SRA fallback).
# Study-agnostic: works for any host. Resume-safe — a run whose target already exists is skipped,
# so resubmit the same array after any timeout/node failure.
#
# Consumes READS_MANIFEST (TSV, one row per run; header optional). Columns:
#   repo  project  run_accession  sample_id  host_species  basename  fastq_ftp(;)  fastq_md5(;)
# Output: $OUTDIR/reads/<project>/<basename>_R{1,2}.fastq.gz   (SE: <basename>.fastq.gz)
#
# Submit via scripts/submit_all.sh (which injects --array/--partition/--output). Or directly:
#   sbatch --array=0-N%C scripts/download_reads.sbatch
# ---------------------------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pipeline_reenter "$@"      # re-exec into container if configured (no-op otherwise)
activate_env

MANIFEST="${READS_MANIFEST:?set READS_MANIFEST}"
CHUNK="${CHUNK:-25}"; CPUS="${CPUS:-${SLURM_CPUS_PER_TASK:-4}}"
FORCE="${FORCE:-0}"; VERIFY_MD5="${VERIFY_MD5:-1}"; RUN_TIMEOUT="${PER_RUN_MAX:-28800}"
command -v fastq-dl >/dev/null || { echo "FATAL: fastq-dl not on PATH"; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "FATAL: READS_MANIFEST not found: $MANIFEST"; exit 1; }

LOGDIR="$OUTDIR/logs"; mkdir -p "$LOGDIR"
TASK="${SLURM_ARRAY_TASK_ID:-0}"; JOB="${SLURM_ARRAY_JOB_ID:-$$}"
STATUS="$LOGDIR/status_reads_${JOB}_${TASK}.tsv"; FAILED="$LOGDIR/failed_reads_${JOB}_${TASK}.tsv"
: > "$STATUS"; : > "$FAILED"

# skip a header line if present (first field literally 'repo')
DATA="$MANIFEST"
if head -1 "$MANIFEST" | grep -qiP '^\s*repo\t'; then DATA="$LOGDIR/.reads_nohdr_${JOB}.tsv"; tail -n +2 "$MANIFEST" > "$DATA"; fi
START=$(( TASK * CHUNK ))
echo "[$(date +%T)] reads task $TASK: rows $((START+1))..$((START+CHUNK)) of $(basename "$MANIFEST")"

st(){ printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$STATUS"; }
fail(){ printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$project" "$run" "$sample" "$species" "$base" "$ftp" "$md5" >> "$FAILED"; }
resolve(){ local d="$1" r="$2" a b
  for a in "$d/${r}_1.fastq.gz" "$d/${r}_R1.fastq.gz" "$d/${r}.fastq.gz"; do [[ -s "$a" ]] && { case "$a" in *_1.fastq.gz|*_R1.fastq.gz) b="${a/_1./_2.}"; b="${b/_R1./_R2.}"; [[ -s "$b" ]] && echo "$a|$b" || echo "$a|";; *) echo "$a|";; esac; return; }; done
  a=$(ls "$d"/*_1.fastq.gz "$d"/*_R1.fastq.gz 2>/dev/null | head -1); if [[ -n "$a" ]]; then b="${a/_1./_2.}"; b="${b/_R1./_R2.}"; [[ -s "$b" ]] && echo "$a|$b" || echo "$a|"; return; fi
  a=$(ls "$d"/*.fastq.gz 2>/dev/null | grep -vE '_(2|R2)\.fastq\.gz$' | head -1); [[ -n "$a" ]] && echo "$a|"; }

sed -n "$((START+1)),$((START+CHUNK))p" "$DATA" | while IFS=$'\t' read -r repo project run sample species base ftp md5; do
  [[ -z "${run:-}" ]] && continue
  DEST="$OUTDIR/reads/${project:-UNKNOWN}"; mkdir -p "$DEST"
  R1="$DEST/${base}_R1.fastq.gz"; SE="$DEST/${base}.fastq.gz"
  if [[ "$FORCE" != 1 && ( -s "$R1" || -s "$SE" ) ]]; then st "$run" "$sample" SKIP_EXISTS "$project"; continue; fi
  TMP="$DEST/.tmp_${run}"; rm -rf "$TMP"; mkdir -p "$TMP"; ok=0
  for attempt in 1 2 3; do
    if timeout "$RUN_TIMEOUT" fastq-dl -a "$run" -o "$TMP" --cpus "$CPUS" >"$TMP/fastq-dl.log" 2>&1; then ok=1; break; fi
    echo "[$(date +%T)] $run: attempt $attempt failed (rc=$?); retry"; sleep $((attempt*15))
  done
  [[ "$ok" != 1 ]] && { st "$run" "$sample" FAIL_DOWNLOAD "$project"; fail; rm -rf "$TMP"; continue; }
  pair=$(resolve "$TMP" "$run"); [[ -z "$pair" ]] && { st "$run" "$sample" FAIL_NOFILES "$project"; fail; rm -rf "$TMP"; continue; }
  s1="${pair%%|*}"; s2="${pair##*|}"
  if [[ -n "$s2" && -s "$s2" ]]; then
    mv -f "$s1" "$R1"; mv -f "$s2" "$DEST/${base}_R2.fastq.gz"
    if ! $GZT "$R1" 2>/dev/null || ! $GZT "$DEST/${base}_R2.fastq.gz" 2>/dev/null; then rm -f "$R1" "$DEST/${base}_R2.fastq.gz"; st "$run" "$sample" FAIL_GZIP "$project"; fail; rm -rf "$TMP"; continue; fi
    note=paired; [[ "$VERIFY_MD5" == 1 && "$md5" == *";"* ]] && { e1="${md5%%;*}"; e2="${md5##*;}"; a1=$(md5sum "$R1"|cut -d' ' -f1); a2=$(md5sum "$DEST/${base}_R2.fastq.gz"|cut -d' ' -f1); [[ "$a1" == "$e1" && "$a2" == "$e2" ]] && note=paired_md5ok || note=paired_md5diff; }
  else
    mv -f "$s1" "$SE"; if ! $GZT "$SE" 2>/dev/null; then rm -f "$SE"; st "$run" "$sample" FAIL_GZIP "$project"; fail; rm -rf "$TMP"; continue; fi
    note=single; [[ "$VERIFY_MD5" == 1 && -n "$md5" && "$md5" != *";"* ]] && { a1=$(md5sum "$SE"|cut -d' ' -f1); [[ "$a1" == "$md5" ]] && note=single_md5ok || note=single_md5diff; }
  fi
  rm -rf "$TMP"; st "$run" "$sample" OK "$note"
done
echo "[$(date +%T)] reads task $TASK done -> $STATUS"
awk -F'\t' '{c[$3]++} END{for(k in c) printf "  %s: %d\n",k,c[k]}' "$STATUS"
