#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Cold-cut over an existing external PostgreSQL + Redis deployment to the
local-directory docker-compose.local.yml stack.

This helper intentionally migrates PostgreSQL only. Redis is cold-cut to an
empty local instance, so transient Redis-backed state (sessions, refresh
tokens, verification codes, scheduler caches, etc.) will be rebuilt after the
cutover.

Usage:
  ./migrate-external-to-local.sh [options]

Options:
  --source-dir DIR            Existing deployment directory (default: /opt/sub2api-deploy)
  --target-dir DIR            Target local-state deployment directory (default: current directory)
  --source-compose-file FILE  Compose file inside source dir (default: docker-compose.yml)
  --target-compose-file FILE  Compose file inside target dir (default: docker-compose.local.yml)
  --dump-file PATH            PostgreSQL dump output path (default: <target>/backups/postgres-cutover-<ts>.sql)
  --pg-dump-image IMAGE       Docker image used for pg_dump (default: postgres:18-alpine)
  --skip-stop-source          Do not stop the source sub2api container before dumping
  --keep-target-data          Do not overwrite target data/ with source data/
  --yes                       Run non-interactively
  -h, --help                  Show this help

Required setup before running:
  1. The target directory already contains docker-compose.local.yml and .env.
  2. The target .env is configured for the local postgres/redis stack
     (POSTGRES_* / REDIS_PASSWORD / app secrets).
  3. The source .env still contains the external DATABASE_* connection info.
EOF
}

SOURCE_DIR="/opt/sub2api-deploy"
TARGET_DIR="$(pwd)"
SOURCE_COMPOSE_FILE="docker-compose.yml"
TARGET_COMPOSE_FILE="docker-compose.local.yml"
DUMP_FILE=""
PG_DUMP_IMAGE="postgres:18-alpine"
SKIP_STOP_SOURCE=0
KEEP_TARGET_DATA=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)
      SOURCE_DIR="$2"
      shift 2
      ;;
    --target-dir)
      TARGET_DIR="$2"
      shift 2
      ;;
    --source-compose-file)
      SOURCE_COMPOSE_FILE="$2"
      shift 2
      ;;
    --target-compose-file)
      TARGET_COMPOSE_FILE="$2"
      shift 2
      ;;
    --dump-file)
      DUMP_FILE="$2"
      shift 2
      ;;
    --pg-dump-image)
      PG_DUMP_IMAGE="$2"
      shift 2
      ;;
    --skip-stop-source)
      SKIP_STOP_SOURCE=1
      shift
      ;;
    --keep-target-data)
      KEEP_TARGET_DATA=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_file() {
  [[ -f "$1" ]] || {
    echo "Required file not found: $1" >&2
    exit 1
  }
}

dotenv_get() {
  local file="$1"
  local key="$2"
  local line
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1
  printf '%s' "${line#*=}"
}

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N]: " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

directory_nonempty() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  find "$dir" -mindepth 1 -maxdepth 1 | read -r
}

require_cmd docker
require_cmd grep
require_cmd date
require_cmd cp

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

SOURCE_ENV_FILE="$SOURCE_DIR/.env"
TARGET_ENV_FILE="$TARGET_DIR/.env"
SOURCE_COMPOSE_PATH="$SOURCE_DIR/$SOURCE_COMPOSE_FILE"
TARGET_COMPOSE_PATH="$TARGET_DIR/$TARGET_COMPOSE_FILE"

require_file "$SOURCE_ENV_FILE"
require_file "$TARGET_ENV_FILE"
require_file "$SOURCE_COMPOSE_PATH"
require_file "$TARGET_COMPOSE_PATH"

SRC_DB_HOST="$(dotenv_get "$SOURCE_ENV_FILE" DATABASE_HOST || true)"
SRC_DB_PORT="$(dotenv_get "$SOURCE_ENV_FILE" DATABASE_PORT || true)"
SRC_DB_USER="$(dotenv_get "$SOURCE_ENV_FILE" DATABASE_USER || true)"
SRC_DB_PASSWORD="$(dotenv_get "$SOURCE_ENV_FILE" DATABASE_PASSWORD || true)"
SRC_DB_NAME="$(dotenv_get "$SOURCE_ENV_FILE" DATABASE_DBNAME || true)"
SRC_DB_SSLMODE="$(dotenv_get "$SOURCE_ENV_FILE" DATABASE_SSLMODE || true)"

TGT_DB_USER="$(dotenv_get "$TARGET_ENV_FILE" POSTGRES_USER || true)"
TGT_DB_PASSWORD="$(dotenv_get "$TARGET_ENV_FILE" POSTGRES_PASSWORD || true)"
TGT_DB_NAME="$(dotenv_get "$TARGET_ENV_FILE" POSTGRES_DB || true)"

[[ -n "$SRC_DB_HOST" && -n "$SRC_DB_PORT" && -n "$SRC_DB_USER" && -n "$SRC_DB_PASSWORD" && -n "$SRC_DB_NAME" ]] || {
  echo "Source .env must contain DATABASE_HOST, DATABASE_PORT, DATABASE_USER, DATABASE_PASSWORD, and DATABASE_DBNAME." >&2
  exit 1
}

[[ -n "$TGT_DB_USER" && -n "$TGT_DB_PASSWORD" && -n "$TGT_DB_NAME" ]] || {
  echo "Target .env must contain POSTGRES_USER, POSTGRES_PASSWORD, and POSTGRES_DB." >&2
  exit 1
}

SRC_DB_SSLMODE="${SRC_DB_SSLMODE:-require}"

mkdir -p "$TARGET_DIR/data" "$TARGET_DIR/postgres_data" "$TARGET_DIR/redis_data" "$TARGET_DIR/backups"

if directory_nonempty "$TARGET_DIR/postgres_data"; then
  echo "Refusing to continue: $TARGET_DIR/postgres_data is not empty." >&2
  echo "Use a fresh target directory or clear postgres_data before cutover." >&2
  exit 1
fi

if directory_nonempty "$TARGET_DIR/redis_data"; then
  echo "Refusing to continue: $TARGET_DIR/redis_data is not empty." >&2
  echo "Use a fresh target directory or clear redis_data before cutover." >&2
  exit 1
fi

if [[ -z "$DUMP_FILE" ]]; then
  DUMP_FILE="$TARGET_DIR/backups/postgres-cutover-$(date +%Y%m%d-%H%M%S).sql"
fi

echo "Source deployment : $SOURCE_DIR"
echo "Target deployment : $TARGET_DIR"
echo "Source database   : $SRC_DB_HOST:$SRC_DB_PORT/$SRC_DB_NAME"
echo "Target database   : $TGT_DB_NAME (container: sub2api-postgres)"
echo "pg_dump image     : $PG_DUMP_IMAGE"
echo "Postgres dump     : $DUMP_FILE"
echo
echo "Redis policy      : local Redis starts empty (transient Redis state is dropped)"
echo "Cutover behavior  : old sub2api will be stopped before the final pg_dump unless --skip-stop-source is used"
echo

confirm "Proceed with the cold cutover helper?" || {
  echo "Cancelled."
  exit 0
}

if [[ "$KEEP_TARGET_DATA" -eq 0 ]]; then
  if directory_nonempty "$TARGET_DIR/data"; then
    backup_dir="$TARGET_DIR/data.pre-cutover-$(date +%Y%m%d-%H%M%S)"
    echo "Backing up existing target data/ to $(basename "$backup_dir")"
    mv "$TARGET_DIR/data" "$backup_dir"
    mkdir -p "$TARGET_DIR/data"
  fi

  if [[ -d "$SOURCE_DIR/data" ]]; then
    echo "Copying source data/ into target deployment"
    cp -a "$SOURCE_DIR/data/." "$TARGET_DIR/data/"
  fi
fi

echo "Starting target postgres + redis"
(
  cd "$TARGET_DIR"
  docker compose -f "$TARGET_COMPOSE_FILE" up -d postgres redis
)

echo "Waiting for target postgres"
for _ in $(seq 1 30); do
  if (
    cd "$TARGET_DIR" &&
    docker compose -f "$TARGET_COMPOSE_FILE" exec -T postgres \
      pg_isready -U "$TGT_DB_USER" -d "$TGT_DB_NAME" >/dev/null 2>&1
  ); then
    break
  fi
  sleep 2
done

(
  cd "$TARGET_DIR" &&
  docker compose -f "$TARGET_COMPOSE_FILE" exec -T postgres \
    pg_isready -U "$TGT_DB_USER" -d "$TGT_DB_NAME"
)

echo "Waiting for target redis"
for _ in $(seq 1 30); do
  if (
    cd "$TARGET_DIR" &&
    docker compose -f "$TARGET_COMPOSE_FILE" exec -T redis \
      redis-cli ping >/dev/null 2>&1
  ); then
    break
  fi
  sleep 1
done

(
  cd "$TARGET_DIR" &&
  docker compose -f "$TARGET_COMPOSE_FILE" exec -T redis \
    redis-cli ping
)

if [[ "$SKIP_STOP_SOURCE" -eq 0 ]]; then
  echo "Stopping source sub2api before final dump"
  (
    cd "$SOURCE_DIR"
    docker compose -f "$SOURCE_COMPOSE_FILE" stop sub2api
  )
fi

echo "Creating final PostgreSQL dump"
docker run --rm \
  -e PGPASSWORD="$SRC_DB_PASSWORD" \
  -e PGSSLMODE="$SRC_DB_SSLMODE" \
  "$PG_DUMP_IMAGE" \
  pg_dump \
    -h "$SRC_DB_HOST" \
    -p "$SRC_DB_PORT" \
    -U "$SRC_DB_USER" \
    -d "$SRC_DB_NAME" \
    --no-owner \
    --no-privileges \
  > "$DUMP_FILE"

echo "Importing dump into local postgres"
(
  cd "$TARGET_DIR"
  docker compose -f "$TARGET_COMPOSE_FILE" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "$TGT_DB_USER" -d "$TGT_DB_NAME" < "$DUMP_FILE"
)

echo "Starting target sub2api"
(
  cd "$TARGET_DIR"
  docker compose -f "$TARGET_COMPOSE_FILE" up -d sub2api
)

cat <<EOF

Cutover helper finished.

Next verification commands:
  cd $TARGET_DIR
  docker compose -f $TARGET_COMPOSE_FILE ps
  docker compose -f $TARGET_COMPOSE_FILE logs --tail=100 sub2api
  docker compose -f $TARGET_COMPOSE_FILE exec -T postgres pg_isready -U "$TGT_DB_USER" -d "$TGT_DB_NAME"
  docker compose -f $TARGET_COMPOSE_FILE exec -T redis redis-cli ping

Rollback:
  1. cd $TARGET_DIR && docker compose -f $TARGET_COMPOSE_FILE stop sub2api
  2. cd $SOURCE_DIR && docker compose -f $SOURCE_COMPOSE_FILE start sub2api

Remember: Redis was intentionally cold-cut to an empty local instance.
EOF
