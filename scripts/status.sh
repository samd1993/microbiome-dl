#!/bin/bash
# Progress + failure roll-up. Run any time.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
L="$OUTDIR/logs"
echo "==================== reads (ENA/SRA) ===================="
cat "$L"/status_reads_*.tsv 2>/dev/null | awk -F'\t' '{c[$3]++} END{for(k in c) printf "  %-16s %d\n",k,c[k]}' || echo "  (none yet)"
cat "$L"/failed_reads_*.tsv 2>/dev/null | sort -u > "$L/all_failed_reads.tsv" 2>/dev/null || true
echo "  failed runs -> $L/all_failed_reads.tsv ($(grep -c . "$L/all_failed_reads.tsv" 2>/dev/null || echo 0)); resubmit that file as READS_MANIFEST to retry"
echo; echo "==================== CNCB (GSA/CNGB) ===================="
cat "$L"/status_cncb_*.tsv 2>/dev/null | awk -F'\t' '{c[$3]++} END{for(k in c) printf "  %-22s %d\n",k,c[k]}' || echo "  (none)"
cat "$L"/cncb_manual_*.tsv 2>/dev/null | sort -u > "$L/all_cncb_manual.tsv" 2>/dev/null || true
echo; echo "==================== files on disk ===================="
printf "  reads   : %s files   (%s)\n" "$(find "$OUTDIR/reads" -name '*.fastq.gz' 2>/dev/null | wc -l | tr -d ' ')" "$(du -sh "$OUTDIR/reads" 2>/dev/null | cut -f1)"
printf "  genomes : %s files   (%s)\n" "$(find "$OUTDIR/host_genomes" -name '*.fna.gz' 2>/dev/null | wc -l | tr -d ' ')" "$(du -sh "$OUTDIR/host_genomes" 2>/dev/null | cut -f1)"
