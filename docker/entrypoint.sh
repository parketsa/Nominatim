#!/bin/sh
set -e

PROJECT_DIR="${NOMINATIM_PROJECT_DIR:-/var/lib/nominatim}"
mkdir -p "$PROJECT_DIR"

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
    exec nominatim "$cmd" --project-dir "$PROJECT_DIR" "$@"
    ;;
esac
