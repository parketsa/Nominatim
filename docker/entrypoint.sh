#!/bin/sh
set -e

runtime_home_for_user() {
  getent passwd "$1" 2>/dev/null | cut -d: -f6
}

switch_to_runtime_user() {
  if [ "$(id -u)" -ne 0 ] || [ "${NOMINATIM_ALLOW_ROOT:-}" = "1" ]; then
    return 0
  fi

  runtime_user="${NOMINATIM_RUNTIME_USER:-nominatim}"
  if [ "$runtime_user" = "root" ]; then
    return 0
  fi

  if ! id "$runtime_user" >/dev/null 2>&1; then
    echo "Configured runtime user '$runtime_user' does not exist." >&2
    exit 2
  fi

  if ! command -v runuser >/dev/null 2>&1; then
    echo "runuser is required to drop root privileges in entrypoint." >&2
    exit 2
  fi

  runtime_home=$(runtime_home_for_user "$runtime_user")
  if [ -n "$runtime_home" ]; then
    export HOME="$runtime_home"
  fi

  exec runuser -u "$runtime_user" --preserve-environment -- "$0" "$@"
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

switch_to_runtime_user "$@"
normalize_runtime_env

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

if [ -n "${NOMINATIM_PASSWORD:-}" ] && [ -z "${PGPASSWORD:-}" ]; then
  export PGPASSWORD="$NOMINATIM_PASSWORD"
fi

if [ "$#" -eq 0 ]; then
  exec nominatim --help
fi

to_lower() {
  printf '%s' "$1" | tr 'A-Z' 'a-z'
}

db_conninfo() {
  if [ -z "${NOMINATIM_DATABASE_DSN:-}" ]; then
    return 1
  fi

  printf '%s' "$NOMINATIM_DATABASE_DSN" | sed 's/^pgsql://; s/;/ /g'
}

sql_escape_literal() {
  printf '%s' "$1" | sed "s/'/''/g"
}

sql_escape_ident() {
  printf '%s' "$1" | sed 's/\"/\"\"/g'
}

ensure_web_user() {
  webuser="${NOMINATIM_DATABASE_WEBUSER:-www-data}"

  conninfo=$(db_conninfo) || return 0

  webuser_lit=$(sql_escape_literal "$webuser")
  webuser_ident=$(sql_escape_ident "$webuser")

  psql "$conninfo dbname=postgres" -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$webuser_lit'" \
    | grep -q 1 && return 0

  if [ -n "${NOMINATIM_PASSWORD:-}" ]; then
    webpass_lit=$(sql_escape_literal "$NOMINATIM_PASSWORD")
    psql "$conninfo dbname=postgres" -v ON_ERROR_STOP=1 \
      -c "CREATE ROLE \"$webuser_ident\" LOGIN PASSWORD '$webpass_lit'"
  else
    psql "$conninfo dbname=postgres" -v ON_ERROR_STOP=1 \
      -c "CREATE ROLE \"$webuser_ident\" LOGIN"
  fi
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
  ensure_web_user
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
      ensure_web_user
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
