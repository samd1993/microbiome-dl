#!/bin/bash
#SBATCH --job-name=mgdl_cncb
#SBATCH --time=2-00:00:00
#SBATCH --mem=4G
#SBATCH --cpus-per-task=2
#SBATCH --output=slurm-cncb-%A_%a.log
# ---------------------------------------------------------------------------------------------
# Download reads from the Chinese repositories GSA (NGDC) and CNGB — the "problem-child" mirror.
# Slower + flakier than ENA/SRA, so this is a SEPARATE, resume-heavy job. Only needed if your
# study includes GSA/CNGB accessions. Mechanisms (verified over plain HTTPS):
#   GSA : https://download.cncb.ac.cn/<part>/<CRA>/<CRR>/<CRR>_f1.fastq.gz (+ _r2). <part> (gsa,gsa2,
#         ...) varies per CRA; pass it in the manifest (gsa_part col) to skip probing.
#   CNGB: alias-named files under a per-run dir; each with a .md5 sidecar.
# Manifest (CNCB_MANIFEST), one row per run; header optional:
#   repo(GSA|CNGB)  project  run  sample_id  host_species  basename  download_base  [gsa_part]
# Output: $OUTDIR/reads/<project>/<basename>_R{1,2}.fastq.gz
# RESUME-SAFE: keeps .part files so wget -c continues big files across resubmits.
# ---------------------------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pipeline_reenter "$@"
activate_env
command -v curl >/dev/null || { echo "FATAL: curl not found"; exit 1; }

MANIFEST="${CNCB_MANIFEST:?set CNCB_MANIFEST}"; [[ -f "$MANIFEST" ]] || { echo "FATAL: not found: $MANIFEST"; exit 1; }
CHUNK="${CHUNK:-100000}"; FORCE="${FORCE:-0}"; RUN_MAX="${PER_RUN_MAX:-28800}"
GSA_HOST="https://download.cncb.ac.cn"; WGET="wget -q -c -t 40 --waitretry=20 --timeout=180"
LOGDIR="$OUTDIR/logs"; mkdir -p "$LOGDIR"
TASK="${SLURM_ARRAY_TASK_ID:-0}"; JOB="${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-$$}}"
STATUS="$LOGDIR/status_cncb_${JOB}_${TASK}.tsv"; MANUAL="$LOGDIR/cncb_manual_${JOB}_${TASK}.tsv"; : > "$STATUS"; : > "$MANUAL"
DATA="$MANIFEST"; head -1 "$MANIFEST" | grep -qiP '^\s*repo\t' && { DATA="$LOGDIR/.cncb_nohdr_${JOB}.tsv"; tail -n +2 "$MANIFEST" > "$DATA"; }
START=$(( TASK * CHUNK ))
st(){ printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$STATUS"; }
alive(){ local i; for i in 1 2 3; do case "$(curl -s -o /dev/null -w '%{http_code}' -r 0-0 --max-time 45 "$1" 2>/dev/null)" in 20[06]) return 0;; esac; sleep 8; done; return 1; }
fetch(){ local url="$1" out="$2" end=$(( $(date +%s) + RUN_MAX )); while [[ $(date +%s) -lt $end ]]; do $WGET -O "$out" "$url" 2>/dev/null; [[ -s "$out" ]] && $GZT "$out" 2>/dev/null && return 0; sleep 10; done; return 1; }

sed -n "$((START+1)),$((START+CHUNK))p" "$DATA" | while IFS=$'\t' read -r repo project run sample species base durl part; do
  [[ -z "${run:-}" ]] && continue
  DEST="$OUTDIR/reads/${project:-UNKNOWN}"; mkdir -p "$DEST"; R1="$DEST/${base}_R1.fastq.gz"; R2="$DEST/${base}_R2.fastq.gz"
  [[ "$FORCE" != 1 && -s "$R1" ]] && { st "$run" "$sample" SKIP_EXISTS "$project"; continue; }
  if [[ "$repo" == "GSA" ]]; then
    P="${part:-}"; if [[ -z "$P" ]]; then for p in gsa gsa2 gsa3 gsa4 gsa5; do alive "$GSA_HOST/$p/$project/$run/${run}_f1.fastq.gz" && { P="$p"; break; }; done; fi
    [[ -z "$P" ]] && { st "$run" "$sample" FAIL_NO_PARTITION "$project"; printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$project" "$run" "$sample" "$base" >> "$MANUAL"; continue; }
    b="$GSA_HOST/$P/$project/$run"
    if fetch "$b/${run}_f1.fastq.gz" "$R1.part"; then mv -f "$R1.part" "$R1"
      if fetch "$b/${run}_r2.fastq.gz" "$R2.part"; then mv -f "$R2.part" "$R2"; st "$run" "$sample" OK_PAIRED "$P"; else st "$run" "$sample" RETRY_PARTIAL_R2 "$P"; fi
    else st "$run" "$sample" RETRY_PARTIAL_R1 "$P"; fi   # keep .part for resume
  else  # CNGB
    dir="${durl%/}/$run/"; [[ -z "$durl" ]] && { st "$run" "$sample" FAIL_NO_DIR "$project"; printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$project" "$run" "$sample" "$base" >> "$MANUAL"; continue; }
    listing=$(curl -s --max-time 90 "$dir" | grep -oE 'href="[^"]+\.(fq|fastq)\.gz"' | sed -E 's/^href="//; s/"$//' | sort -u)
    r1f=$(echo "$listing" | grep -E '(_1|_f1|_r1)\.(fq|fastq)\.gz$' | head -1); r2f=$(echo "$listing" | grep -E '(_2|_r2)\.(fq|fastq)\.gz$' | head -1)
    if [[ -n "$r1f" ]] && fetch "$dir$r1f" "$R1.part"; then mv -f "$R1.part" "$R1"
      exp=$(curl -s --max-time 30 "$dir$r1f.md5" | awk '{print $NF}'); act=$(md5sum "$R1"|cut -d' ' -f1); note=CNGB; [[ -n "$exp" ]] && { [[ "$exp" == "$act" ]] && note=CNGB_md5ok || note=CNGB_md5diff; }
      if [[ -n "$r2f" ]] && fetch "$dir$r2f" "$R2.part"; then mv -f "$R2.part" "$R2"; st "$run" "$sample" "OK_PAIRED_$note" "$dir"; else st "$run" "$sample" "RETRY_PARTIAL_R2" "$dir"; fi
    else st "$run" "$sample" FAIL_MANUAL "$project"; printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$project" "$run" "$sample" "$base" >> "$MANUAL"; fi
  fi
done
echo "[$(date +%T)] cncb task $TASK done."; awk -F'\t' '{c[$3]++} END{for(k in c) printf "  %s: %d\n",k,c[k]}' "$STATUS"
[[ -s "$MANUAL" ]] && echo "  >> $(grep -c . "$MANUAL") run(s) need manual download: $MANUAL"
exit 0
