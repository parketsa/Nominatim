#!/bin/sh
set -e

PROJECT_DIR="${NOMINATIM_PROJECT_DIR:-/var/lib/nominatim}"
mkdir -p "$PROJECT_DIR"

exec nominatim --project-dir "$PROJECT_DIR" "$@"
