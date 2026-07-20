# Input & output file formats

All files are TSV (tab-separated) with a header. `host_species` is whatever your metagenomes come
from — `Homo sapiens` for a human study (any body site / condition), an animal, an insect, etc.

## Input: `samples.tsv` (you provide this)
One row per **sample**. This is the only file you must create.

| column | required | notes |
|---|---|---|
| `sample_id` | ✅ | unique; becomes the filename prefix, so keep it filename-safe |
| `host_species` | ✅ | binomial preferred (e.g. `Homo sapiens`); used to fetch the host genome |
| `repo` | ✅ | `ENA` / `SRA` (both handled by fastq-dl) or `GSA` / `CNGB` |
| `run_accessions` | ✅ | one or more run accessions, `;`-separated |
| `project` | optional | groups outputs into `reads/<project>/`; defaults to `UNKNOWN` |
| `genus`,`family`,`order` | optional | improve host-genome fallback when the species has no assembly |
| `fastq_ftp`,`fastq_md5` | optional | `|`-separated per run (ENA); enables md5 check |
| `download_base` | optional | CNGB per-run base URL |
| `gsa_part` | optional | GSA partition (`gsa`,`gsa2`,…) — skips probing if known |

See `examples/samples.tsv`.

## Derived (made by `mapping/prepare_inputs.py`)
- **`reads.tsv`** — per run, for `scripts/download_reads.sbatch`:
  `repo  project  run_accession  sample_id  host_species  basename  fastq_ftp  fastq_md5`
- **`cncb.tsv`** — per run, for `scripts/download_cncb.sbatch`:
  `repo  project  run  sample_id  host_species  basename  download_base  gsa_part`

`basename = <sample_id>__<host_species>__<run>` — reads land as `<basename>_R{1,2}.fastq.gz`, which lets
`build_mapping.py` find a sample's files by its `sample_id`.

## Derived (made by `genomes/resolve_host_genomes.py`)
- **`<source>_resolved.tsv`** — one row per host species: `accession, match_rank (species/genus/family/order), level, scaffold_n50, …`
- **`genomes_download.tsv`** — deduped list for `download_genomes.sbatch`: `accession species assembly_name target_filename ftp_url`
- **`host_species_canonical.tsv`** — `host_species → host_species_canonical + host_taxid` (collapses synonyms)

## Output: `master_index.tsv` (made by `mapping/build_mapping.py`)
One row per sample — the file your pipeline reads. Key columns: `sample_id, host_species,
host_species_canonical, host_taxid, priority (top-N-per-host), layout, R1_path, R2_path,
<source>_accession/_match_rank/_genome_path, host_filtration_genome_paths, status, notes`.
