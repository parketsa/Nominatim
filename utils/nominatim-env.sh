#!/bin/sh
set -eu

# Wrapper to run Nominatim tasks using docker-style environment variables.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
NOMINATIM_CLI_FALLBACK="${REPO_ROOT}/nominatim-cli.py"

PROJECT_DIR="${NOMINATIM_PROJECT_DIR:-${PROJECT_DIR:-$PWD}}"
ACTION="${1:-import}"

runtime_home_for_user() {
  getent passwd "$1" 2>/dev/null | cut -d: -f6
}

normalize_runtime_env() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  if [ -z "${HOME:-}" ] || [ "$HOME" = "/root" ]; then
    runtime_home=$(runtime_home_for_user "$(id -u)")
    if [ -n "$runtime_home" ]; then
      export HOME="$runtime_home"
    fi
  fi

  if [ "${PGSSLCERT:-}" = "/root/.postgresql/postgresql.crt" ]; then
    unset PGSSLCERT
  fi

  if [ "${PGSSLKEY:-}" = "/root/.postgresql/postgresql.key" ]; then
    unset PGSSLKEY
  fi
}

die() {
  echo "error: $*" >&2
  exit 2
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

is_false() {
  case "${1:-}" in
    0|false|FALSE|no|NO|n|N) return 0 ;;
    *) return 1 ;;
  esac
}

download() {
  url="$1"
  dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url"
  else
    die "curl or wget is required to download $url"
  fi
}

run_nominatim() {
  if command -v nominatim >/dev/null 2>&1; then
    nominatim "$@"
    return
  fi

  if [ -n "${NOMINATIM_SOURCE_DIR:-}" ] && [ -f "${NOMINATIM_SOURCE_DIR}/nominatim-cli.py" ]; then
    python3 "${NOMINATIM_SOURCE_DIR}/nominatim-cli.py" "$@"
    return
  fi

  if [ -f "/opt/nominatim/nominatim-cli.py" ]; then
    python3 "/opt/nominatim/nominatim-cli.py" "$@"
    return
  fi

  if [ -f "$NOMINATIM_CLI_FALLBACK" ]; then
    python3 "$NOMINATIM_CLI_FALLBACK" "$@"
    return
  fi

  die "nominatim not found in PATH and no nominatim-cli.py fallback available"
}

normalize_runtime_env
mkdir -p "$PROJECT_DIR"

PBF_URL="${NOMINATIM_PBF_URL:-${PBF_URL:-}}"
PBF_PATH="${NOMINATIM_PBF_PATH:-${PBF_PATH:-}}"
REPLICATION_URL="${NOMINATIM_REPLICATION_URL:-${REPLICATION_URL:-}}"
REPLICATION_INTERVAL="${NOMINATIM_REPLICATION_INTERVAL:-${REPLICATION_UPDATE_INTERVAL:-${NOMINATIM_REPLICATION_UPDATE_INTERVAL:-}}}"
REPLICATION_RECHECK="${NOMINATIM_RECHECK_INTERVAL:-${REPLICATION_RECHECK_INTERVAL:-${NOMINATIM_REPLICATION_RECHECK_INTERVAL:-}}}"
UPDATE_MODE="${NOMINATIM_UPDATE_MODE:-${UPDATE_MODE:-none}}"
THREADS="${NOMINATIM_THREADS:-${THREADS:-}}"
IMPORT_WIKIPEDIA="${NOMINATIM_IMPORT_WIKIPEDIA:-${IMPORT_WIKIPEDIA:-}}"
IMPORT_SECONDARY_WIKIPEDIA="${NOMINATIM_IMPORT_SECONDARY_WIKIPEDIA:-${IMPORT_SECONDARY_WIKIPEDIA:-}}"

if [ -n "${IMPORT_STYLE:-}" ] && [ -z "${NOMINATIM_IMPORT_STYLE:-}" ]; then
  export NOMINATIM_IMPORT_STYLE="$IMPORT_STYLE"
fi

if [ -n "${NOMINATIM_PASSWORD:-}" ] && [ -z "${PGPASSWORD:-}" ]; then
  export PGPASSWORD="$NOMINATIM_PASSWORD"
fi

if [ -n "$REPLICATION_URL" ]; then
  export NOMINATIM_REPLICATION_URL="$REPLICATION_URL"
fi
if [ -n "$REPLICATION_INTERVAL" ]; then
  export NOMINATIM_REPLICATION_UPDATE_INTERVAL="$REPLICATION_INTERVAL"
fi
if [ -n "$REPLICATION_RECHECK" ]; then
  export NOMINATIM_REPLICATION_RECHECK_INTERVAL="$REPLICATION_RECHECK"
fi

case "$ACTION" in
  import)
    if [ -n "$PBF_URL" ] && [ -n "$PBF_PATH" ]; then
      die "set only one of NOMINATIM_PBF_URL/PBF_URL or NOMINATIM_PBF_PATH/PBF_PATH"
    fi

    if [ -n "$PBF_URL" ]; then
      OSMFILE="${PROJECT_DIR}/data.osm.pbf"
      if [ ! -f "$OSMFILE" ]; then
        echo "Downloading PBF from $PBF_URL"
        download "$PBF_URL" "$OSMFILE"
      else
        echo "Using existing PBF file: $OSMFILE"
      fi
    elif [ -n "$PBF_PATH" ]; then
      OSMFILE="$PBF_PATH"
    else
      die "no PBF source set (NOMINATIM_PBF_URL/PBF_URL or NOMINATIM_PBF_PATH/PBF_PATH)"
    fi

    if is_true "$IMPORT_WIKIPEDIA"; then
      echo "Downloading Wikipedia importance dump"
      download "https://nominatim.org/data/wikimedia-importance.csv.gz" \
        "${PROJECT_DIR}/wikimedia-importance.csv.gz"
    elif [ -n "$IMPORT_WIKIPEDIA" ] && ! is_false "$IMPORT_WIKIPEDIA"; then
      [ -f "$IMPORT_WIKIPEDIA" ] || die "IMPORT_WIKIPEDIA path not found: $IMPORT_WIKIPEDIA"
      cp -n "$IMPORT_WIKIPEDIA" "${PROJECT_DIR}/wikimedia-importance.csv.gz"
    fi

    if is_true "$IMPORT_SECONDARY_WIKIPEDIA"; then
      echo "Downloading Wikipedia secondary importance dump"
      download "https://nominatim.org/data/wikimedia-secondary-importance.sql.gz" \
        "${PROJECT_DIR}/secondary_importance.sql.gz"
    elif [ -n "$IMPORT_SECONDARY_WIKIPEDIA" ] && ! is_false "$IMPORT_SECONDARY_WIKIPEDIA"; then
      [ -f "$IMPORT_SECONDARY_WIKIPEDIA" ] || die "IMPORT_SECONDARY_WIKIPEDIA path not found: $IMPORT_SECONDARY_WIKIPEDIA"
      cp -n "$IMPORT_SECONDARY_WIKIPEDIA" "${PROJECT_DIR}/secondary_importance.sql.gz"
    fi

    if [ -z "$THREADS" ]; then
      if command -v nproc >/dev/null 2>&1; then
        THREADS="$(nproc)"
      elif command -v getconf >/dev/null 2>&1; then
        THREADS="$(getconf _NPROCESSORS_ONLN)"
      else
        THREADS=1
      fi
    fi

    run_nominatim import --project-dir "$PROJECT_DIR" -j "$THREADS" \
      --osm-file "$OSMFILE"

    run_nominatim index --project-dir "$PROJECT_DIR" -j "$THREADS"
    run_nominatim admin --project-dir "$PROJECT_DIR" --check-database

    if [ -n "$REPLICATION_URL" ]; then
      run_nominatim replication --project-dir "$PROJECT_DIR" --init
    fi
    ;;

  replication)
    case "$(printf '%s' "$UPDATE_MODE" | tr 'A-Z' 'a-z')" in
      continuous)
        run_nominatim replication --project-dir "$PROJECT_DIR"
        ;;
      once)
        run_nominatim replication --project-dir "$PROJECT_DIR" --once
        ;;
      catch-up)
        run_nominatim replication --project-dir "$PROJECT_DIR" --catch-up
        ;;
      none|"")
        echo "UPDATE_MODE is none; skipping replication"
        ;;
      *)
        die "unsupported UPDATE_MODE: $UPDATE_MODE"
        ;;
    esac
    ;;

  replication-init)
    run_nominatim replication --project-dir "$PROJECT_DIR" --init
    ;;

  check)
    run_nominatim admin --project-dir "$PROJECT_DIR" --check-database
    ;;

  *)
    cat <<'EOF'
Usage: utils/nominatim-env.sh [import|replication|replication-init|check]

Uses docker-style environment variables to run Nominatim tasks.
EOF
    exit 2
    ;;
esac
