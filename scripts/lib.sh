#!/bin/bash
# Shared helpers sourced by every script: config load, optional container re-exec,
# conda activation, integrity check. Keeps the individual jobs portable.
set -uo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_LIB_DIR/.." && pwd)"
# Prefer a user config.sh; fall back to the committed example.
CONFIG="${CONFIG:-$REPO_ROOT/config/config.sh}"
[[ -f "$CONFIG" ]] || CONFIG="$REPO_ROOT/config/config.example.sh"
# shellcheck disable=SC1090
source "$CONFIG"

# Re-exec into the Apptainer/Singularity image if CONTAINER is set and we're not
# already inside one. This lets tools live in a container without the caller caring.
pipeline_reenter() {
  [[ -z "${CONTAINER:-}" ]] && return 0
  [[ -n "${APPTAINER_CONTAINER:-}${SINGULARITY_CONTAINER:-}" ]] && return 0
  local binds=()
  [[ -n "${BINDS:-}" ]] && binds=(--bind "$BINDS")
  [[ -d /var/spool/slurmd ]] && binds+=(--bind /var/spool/slurmd)   # so $0 (batch copy) resolves
  exec apptainer exec "${binds[@]}" --env CONFIG="$CONFIG" "$CONTAINER" bash "$0" "$@"
}

# Activate the configured conda env (no-op if CONDA_ENV empty).
activate_env() {
  [[ -z "${CONDA_ENV:-}" ]] && return 0
  local base; base="$("${CONDA_BIN:-conda}" info --base 2>/dev/null)" || return 0
  # shellcheck disable=SC1091
  source "$base/etc/profile.d/conda.sh"
  conda activate "$CONDA_ENV" 2>/dev/null || echo "WARN: could not activate conda env '$CONDA_ENV'" >&2
}

# gzip integrity checker (parallel if available)
GZT="gzip -t"; command -v pigz >/dev/null 2>&1 && GZT="pigz -t"

# optional sbatch flags from config
sbatch_extra() {
  local x=""
  [[ -n "${SBATCH_ACCOUNT:-}" ]] && x+=" --account=$SBATCH_ACCOUNT"
  [[ -n "${SBATCH_QOS:-}" ]]     && x+=" --qos=$SBATCH_QOS"
  echo "$x"
}
