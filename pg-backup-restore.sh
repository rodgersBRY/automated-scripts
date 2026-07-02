#!/usr/bin/env bash
#
# pg-backup-restore.sh — Backup, restore, list, and verify Postgres dumps
# running in a Docker container. Works against any project's Postgres
# container; nothing here is tied to a specific project.
#
# Usage:
#   pg-backup-restore.sh backup  [-c <container>] [label]         [-u user] [-n dbname] [-d backup-dir]
#   pg-backup-restore.sh restore [-c <container>] <target>        [-u user] [-n dbname] [-d backup-dir]
#   pg-backup-restore.sh list                                     [-d backup-dir]
#   pg-backup-restore.sh verify  [-c <container>] <target> [--fix]
#
# Flags:
#   -c, --container <name>   Postgres container name (required unless set via .pgdbrc)
#   -u, --db-user <user>     Database user   (default: postgres)
#   -n, --db-name <name>     Database name   (default: postgres)
#   -d, --backup-dir <path>  Backup directory (default: ./backup, relative to cwd)
#   -h, --help                Help
#
# Per-project defaults (.pgdbrc):
#   If a file named .pgdbrc exists in the current directory, it is sourced
#   before flags are parsed, so you can set CONTAINER/DB_USER/DB_NAME/BACKUP_DIR
#   once per project instead of passing them every time. CLI flags still
#   override whatever .pgdbrc sets. Example .pgdbrc:
#     CONTAINER=my_postgres
#     DB_USER=myapp
#     DB_NAME=myapp
#
# <target> for restore/verify can be:
#   - a timestamped folder name under the backup dir, e.g. 2026-07-02_143000
#   - a full path to a .backup file
#
# Examples:
#   pg-backup-restore.sh backup -c my_postgres                    # timestamped backup
#   pg-backup-restore.sh backup -c my_postgres pre-migration      # labeled backup
#   pg-backup-restore.sh list
#   pg-backup-restore.sh verify -c my_postgres 2026-07-02_143000
#   pg-backup-restore.sh restore -c my_postgres 2026-07-02_143000 # auto-fixes CRLF corruption
#   pg-backup-restore.sh backup                                   # uses ./.pgdbrc for -c/-u/-n

set -euo pipefail

err()  { echo "ERROR: $*" >&2; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

# Defaults set for KABS for now — override with -c/-u/-n, or change these
# directly if you point this clone of the script at a different project.
CONTAINER="postgresql-h2ao6kswvxdqxa2az9wl2td8"
DB_USER="kabs"
DB_NAME="kabs"
BACKUP_DIR="$(pwd)/backup"

# Per-project defaults: source ./.pgdbrc if present, before flags are parsed,
# so CLI flags can still override anything it sets.
if [ -f "./.pgdbrc" ]; then
    info "Loaded project config from ./.pgdbrc"
    # shellcheck source=/dev/null
    source "./.pgdbrc"
fi

show_usage() {
    sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'
}

check_docker() {
    docker info > /dev/null 2>&1 || { err "Docker is not running."; exit 1; }
}

check_container() {
    [ -n "$CONTAINER" ] || { err "No container specified. Pass -c/--container <name>."; exit 1; }
    docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || { err "Container '$CONTAINER' is not running."; exit 1; }
}

# Resolve a target (folder name or path) to an actual backup file on disk.
resolve_backup_file() {
    local target="$1"
    if [ -f "$target" ]; then
        echo "$target"
        return 0
    fi
    local dir="$BACKUP_DIR/$target"
    for name in "$DB_NAME.backup" "${DB_NAME}_compressed.backup" "kabs.backup" "kabs_compressed.backup"; do
        if [ -f "$dir/$name" ]; then
            echo "$dir/$name"
            return 0
        fi
    done
    err "No backup file found for '$target' (looked for a literal path, and inside $dir/)"
    exit 1
}

# Returns 0 if the file reads cleanly as a pg custom-format archive, 1 if it
# looks like CRLF corruption (e.g. from a 'docker exec -t' pg_dump).
check_archive_readable() {
    local file="$1"
    docker cp "$file" "$CONTAINER:/tmp/pgdb_check.backup" > /dev/null
    local ok=0
    docker exec "$CONTAINER" pg_restore -l /tmp/pgdb_check.backup > /dev/null 2>/tmp/pgdb_check_err.txt || ok=1
    docker exec "$CONTAINER" rm -f /tmp/pgdb_check.backup > /dev/null 2>&1 || true
    return $ok
}

# Binary-safe CRLF -> LF recovery (only touches literal \r\n pairs).
fix_crlf() {
    perl -0777 -pe 's/\r\n/\n/g' "$1" > "$2"
}

cmd_backup() {
    local label="${1:-}"
    if [ -n "$label" ] && ! [[ "$label" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "Label may only contain letters, numbers, dashes and underscores."
        exit 1
    fi

    check_docker
    check_container

    local ts dest_name dest_dir
    ts="$(date +%Y-%m-%d_%H%M%S)"
    dest_name="$ts"
    [ -n "$label" ] && dest_name="${ts}_${label}"
    dest_dir="$BACKUP_DIR/$dest_name"
    mkdir -p "$dest_dir"

    info "Backing up $DB_NAME from container '$CONTAINER' to $dest_dir/$DB_NAME.backup ..."
    docker exec "$CONTAINER" pg_dump --blobs --format=c --compress=9 -U "$DB_USER" "$DB_NAME" > "$dest_dir/$DB_NAME.backup"

    local size
    size="$(du -h "$dest_dir/$DB_NAME.backup" | cut -f1)"
    info "Backup complete: $dest_dir/$DB_NAME.backup ($size)"
}

cmd_list() {
    if [ ! -d "$BACKUP_DIR" ]; then
        warn "Backup directory does not exist: $BACKUP_DIR"
        return
    fi

    local found=0
    while IFS= read -r file; do
        found=1
        local dir_name size mtime
        dir_name="$(basename "$(dirname "$file")")"
        size="$(du -h "$file" | cut -f1)"
        mtime="$(date -r "$file" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c '%y' "$file" 2>/dev/null)"
        printf "%-28s %-24s %-8s %s\n" "$dir_name" "$(basename "$file")" "$size" "$mtime"
    done < <(find "$BACKUP_DIR" -maxdepth 2 -name "*.backup" | sort -r)

    [ "$found" -eq 0 ] && warn "No backups found under $BACKUP_DIR"
}

cmd_verify() {
    local target="${1:-}" fix=0
    [ -n "$target" ] || { err "Usage: $(basename "$0") verify -c <container> <target> [--fix]"; exit 1; }
    [ "${2:-}" = "--fix" ] && fix=1

    check_docker
    check_container

    local file
    file="$(resolve_backup_file "$target")"

    info "Checking $file ..."
    if check_archive_readable "$file"; then
        info "OK — archive reads cleanly."
        return
    fi

    warn "Archive failed to read. This matches the signature of CRLF corruption (e.g. pg_dump run through 'docker exec -t')."

    if [ "$fix" -eq 0 ]; then
        err "Corrupted. Re-run with --fix to attempt recovery, or use 'restore' which auto-fixes."
        exit 1
    fi

    local fixed="${file%.backup}.fixed.backup"
    info "Attempting CRLF recovery -> $fixed"
    fix_crlf "$file" "$fixed"

    if check_archive_readable "$fixed"; then
        info "Recovered successfully: $fixed"
    else
        rm -f "$fixed"
        err "Recovery failed — the file may be corrupted for a different reason."
        exit 1
    fi
}

cmd_restore() {
    local target="${1:-}"
    [ -n "$target" ] || { err "Usage: $(basename "$0") restore -c <container> <target>"; exit 1; }

    check_docker
    check_container

    local file
    file="$(resolve_backup_file "$target")"

    if ! check_archive_readable "$file"; then
        warn "Archive failed to read — attempting automatic CRLF recovery."
        local fixed="${file%.backup}.fixed.backup"
        fix_crlf "$file" "$fixed"
        if ! check_archive_readable "$fixed"; then
            rm -f "$fixed"
            err "Recovery failed. The file may be corrupted for a reason other than CRLF mangling."
            exit 1
        fi
        info "Recovered: $fixed"
        file="$fixed"
    fi

    echo ""
    echo "  Target container : $CONTAINER"
    echo "  Target database  : $DB_NAME"
    echo "  Target user      : $DB_USER"
    echo "  Source file      : $file"
    echo ""
    warn "This will overwrite existing objects in '$DB_NAME' on container '$CONTAINER'."
    read -r -p "Continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Aborted."
        exit 0
    fi

    info "Restoring $file into $DB_NAME ..."
    docker exec -i "$CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner --clean --if-exists < "$file"
    info "Restore complete."
}

# ---------------------------------------------------------------- arg parsing
[ $# -eq 0 ] && { show_usage; exit 1; }
COMMAND="$1"; shift

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--container)  CONTAINER="$2"; shift 2 ;;
        -u|--db-user)    DB_USER="$2"; shift 2 ;;
        -n|--db-name)    DB_NAME="$2"; shift 2 ;;
        -d|--backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        -h|--help)       show_usage; exit 0 ;;
        *)               POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]:-}"

case "$COMMAND" in
    backup)  cmd_backup "${1:-}" ;;
    restore) cmd_restore "${1:-}" ;;
    list)    cmd_list ;;
    verify)  cmd_verify "${1:-}" "${2:-}" ;;
    help|--help|-h) show_usage ;;
    *)
        err "Unknown command: $COMMAND"
        show_usage
        exit 1
        ;;
esac
