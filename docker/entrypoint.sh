#!/bin/sh
set -e

PROJECT_DIR="${NOMINATIM_PROJECT_DIR:-/var/lib/nominatim}"
mkdir -p "$PROJECT_DIR"

if [ -n "${NOMINATIM_REPLICATION_INTERVAL:-}" ] \
  && [ -z "${NOMINATIM_REPLICATION_UPDATE_INTERVAL:-}" ]; then
  export NOMINATIM_REPLICATION_UPDATE_INTERVAL="$NOMINATIM_REPLICATION_INTERVAL"
fi
if [ -n "${NOMINATIM_RECHECK_INTERVAL:-}" ] \
  && [ -z "${NOMINATIM_REPLICATION_RECHECK_INTERVAL:-}" ]; then
  export NOMINATIM_REPLICATION_RECHECK_INTERVAL="$NOMINATIM_RECHECK_INTERVAL"
fi

if [ "$#" -eq 0 ]; then
  exec nominatim --help
fi

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

      if [ -n "${NOMINATIM_PBF_URL:-}" ] \
        && ! echo " $* " | grep -Eq ' --osm-file(=| )'; then
        pbf_dir="${NOMINATIM_PBF_DIR:-/data}"
        mkdir -p "$pbf_dir"
        pbf_file="${NOMINATIM_PBF_FILE:-$pbf_dir/$(basename "$NOMINATIM_PBF_URL")}"
        if [ ! -f "$pbf_file" ]; then
          echo "Downloading $NOMINATIM_PBF_URL to $pbf_file"
          wget -O "$pbf_file" "$NOMINATIM_PBF_URL"
        fi
        set -- "$@" --osm-file "$pbf_file"
      fi
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
