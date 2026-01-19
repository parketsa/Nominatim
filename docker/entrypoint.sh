#!/bin/sh
set -e

PROJECT_DIR="${NOMINATIM_PROJECT_DIR:-/nominatim/data}"
mkdir -p "$PROJECT_DIR"

if [ -n "${PBF_URL:-}" ] && [ -z "${NOMINATIM_PBF_URL:-}" ]; then
  export NOMINATIM_PBF_URL="$PBF_URL"
fi
if [ -n "${PBF_PATH:-}" ] && [ -z "${NOMINATIM_PBF_PATH:-}" ]; then
  export NOMINATIM_PBF_PATH="$PBF_PATH"
fi
if [ -n "${REPLICATION_URL:-}" ] && [ -z "${NOMINATIM_REPLICATION_URL:-}" ]; then
  export NOMINATIM_REPLICATION_URL="$REPLICATION_URL"
fi
if [ -n "${UPDATE_MODE:-}" ] && [ -z "${NOMINATIM_UPDATE_MODE:-}" ]; then
  export NOMINATIM_UPDATE_MODE="$UPDATE_MODE"
fi

if [ -n "${NOMINATIM_REPLICATION_INTERVAL:-}" ] && [ -z "${NOMINATIM_REPLICATION_UPDATE_INTERVAL:-}" ]; then
  export NOMINATIM_REPLICATION_UPDATE_INTERVAL="$NOMINATIM_REPLICATION_INTERVAL"
fi
if [ -n "${NOMINATIM_RECHECK_INTERVAL:-}" ] && [ -z "${NOMINATIM_REPLICATION_RECHECK_INTERVAL:-}" ]; then
  export NOMINATIM_REPLICATION_RECHECK_INTERVAL="$NOMINATIM_RECHECK_INTERVAL"
fi

if [ "$#" -eq 0 ]; then
  exec nominatim --help
fi

to_lower() {
  printf '%s' "$1" | tr 'A-Z' 'a-z'
}

maybe_import() {
  if [ -z "${NOMINATIM_PBF_URL:-}" ] && [ -z "${NOMINATIM_PBF_PATH:-}" ]; then
    return 0
  fi

  if nominatim admin --check-database --project-dir "$PROJECT_DIR" >/dev/null 2>&1; then
    echo "Database already initialized; skipping import"
    return 0
  fi

  echo "Running initial import"
  /usr/local/bin/nominatim-env.sh import
}

maybe_start_replication() {
  if [ -z "${NOMINATIM_REPLICATION_URL:-}" ]; then
    return 0
  fi

  update_mode=$(to_lower "${NOMINATIM_UPDATE_MODE:-none}")

  if [ "$update_mode" = "none" ] || [ -z "$update_mode" ]; then
    return 0
  fi

  nominatim replication --project-dir "$PROJECT_DIR" --init

  case "$update_mode" in
    continuous)
      echo "Starting continuous replication"
      nominatim replication --project-dir "$PROJECT_DIR" &
      ;;
    once)
      echo "Running replication once"
      nominatim replication --project-dir "$PROJECT_DIR" --once &
      ;;
    catch-up|catchup)
      echo "Running replication catch-up"
      nominatim replication --project-dir "$PROJECT_DIR" --catch-up &
      ;;
    check)
      echo "Checking for updates"
      nominatim replication --project-dir "$PROJECT_DIR" --check-for-updates &
      ;;
    *)
      echo "Unknown NOMINATIM_UPDATE_MODE: $NOMINATIM_UPDATE_MODE" >&2
      ;;
  esac
}

case "$1" in
  -*)
    exec nominatim "$@"
    ;;
  *)
    cmd="$1"
    shift

    if [ "$cmd" = "import" ]; then
      if [ -n "${NOMINATIM_THREADS:-}" ] \
        && ! echo " $* " | grep -Eq ' (-j|--threads)( |$)'; then
        set -- "$@" -j "$NOMINATIM_THREADS"
      fi

      if [ -n "${NOMINATIM_PBF_PATH:-}" ] \
        && ! echo " $* " | grep -Eq ' --osm-file(=| )'; then
        set -- "$@" --osm-file "$NOMINATIM_PBF_PATH"
      elif [ -n "${NOMINATIM_PBF_URL:-}" ] \
        && ! echo " $* " | grep -Eq ' --osm-file(=| )'; then
        pbf_dir="${NOMINATIM_PBF_DIR:-$PROJECT_DIR}"
        mkdir -p "$pbf_dir"
        pbf_file="${NOMINATIM_PBF_FILE:-$pbf_dir/$(basename "$NOMINATIM_PBF_URL")}"
        if [ ! -f "$pbf_file" ]; then
          echo "Downloading $NOMINATIM_PBF_URL to $pbf_file"
          wget -O "$pbf_file" "$NOMINATIM_PBF_URL"
        fi
        set -- "$@" --osm-file "$pbf_file"
      fi
    fi

    if [ "$cmd" = "serve" ]; then
      maybe_import
      nominatim refresh --project-dir "$PROJECT_DIR" --website --functions
      maybe_start_replication
    fi

    if [ "$cmd" = "replication" ] && [ -n "${NOMINATIM_UPDATE_MODE:-}" ]; then
      case "$NOMINATIM_UPDATE_MODE" in
        once)
          set -- "$@" --once
          ;;
        catch-up|catchup)
          set -- "$@" --catch-up
          ;;
        check)
          set -- "$@" --check-for-updates
          ;;
      esac
    fi

    exec nominatim "$cmd" --project-dir "$PROJECT_DIR" "$@"
    ;;
esac
