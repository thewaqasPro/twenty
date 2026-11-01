#!/usr/bin/env bash
# ==============================================================================
# Twenty CRM - Automated Backup & Offsite Replication Script
# Checklist Item 11: Day-2 Operations, Database Dumps, Secrets & S3 Replication
# ==============================================================================
set -euo pipefail

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [ERROR]${NC} $*" >&2; }

# Locate repository root and files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env.production"

# Source environment variables if available
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
  log_info "Loaded environment configuration from ${ENV_FILE}"
fi

# Also source .env.dokploy if available for VPS IP & Dokploy context
DOKPLOY_ENV="${PROJECT_ROOT}/.env.dokploy"
if [[ -f "${DOKPLOY_ENV}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${DOKPLOY_ENV}"
  set +a
fi

# Configuration with robust fallbacks
TIMESTAMP="$(date -u +"%Y%m%d_%H%M%SZ")"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/backups}"
BACKUP_PREFIX="twenty-backup-${TIMESTAMP}"
TEMP_DIR="$(mktemp -d -t twenty-backup-XXXXXX)"

# Ensure backup directory exists
mkdir -p "${BACKUP_DIR}"

# Guarantee cleanup of unencrypted temp files on exit
cleanup() {
  if [[ -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}
trap cleanup EXIT ERR INT TERM

# ------------------------------------------------------------------------------
# 1. Resolve PostgreSQL Container & Database Name
# ------------------------------------------------------------------------------
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-database-postgresql-adg7lr}"
PG_USER="${PG_DATABASE_USER:-postgres}"
PG_DB="${PG_DATABASE_NAME:-kynd_crm}"

# Attempt to extract database name from PG_DATABASE_URL if set
if [[ -n "${PG_DATABASE_URL:-}" ]]; then
  EXTRACTED_DB="$(echo "${PG_DATABASE_URL}" | sed -E 's/.*\/(.*)/\1/' | cut -d'?' -f1)"
  if [[ -n "${EXTRACTED_DB}" ]]; then
    PG_DB="${EXTRACTED_DB}"
  fi
fi

# ------------------------------------------------------------------------------
# 2. Execute pg_dump (Container-native or Direct Fallback)
# ------------------------------------------------------------------------------
DUMP_FILE="${TEMP_DIR}/twenty-database.dump"

# Check if Docker daemon is accessible and container is running
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${POSTGRES_CONTAINER}$"; then
  log_info "Executing pg_dump inside Docker container '${POSTGRES_CONTAINER}'..."
  if ! docker exec -i "${POSTGRES_CONTAINER}" pg_dump -U "${PG_USER}" -F c -b -v "${PG_DB}" > "${DUMP_FILE}" 2>"${TEMP_DIR}/pg_dump.log"; then
    log_error "docker exec pg_dump failed! Output:"
    cat "${TEMP_DIR}/pg_dump.log" >&2
    exit 1
  fi
elif command -v pg_dump >/dev/null 2>&1 && [[ -n "${PG_DATABASE_URL:-}" ]]; then
  log_info "Local Docker daemon not running. Falling back to direct client execution via PG_DATABASE_URL..."
  # If PG_DATABASE_URL uses internal container hostname that cannot be resolved off-host, substitute with VPS IP
  EFFECTIVE_PG_URL="${PG_DATABASE_URL}"
  if [[ "${PG_DATABASE_URL}" == *"@database-postgresql-adg7lr:"* ]] && [[ -n "${DOKPLOY_VPS_IP:-}" ]]; then
    EFFECTIVE_PG_URL="${PG_DATABASE_URL//@database-postgresql-adg7lr:/@${DOKPLOY_VPS_IP}:}"
    log_info "Substituted internal hostname with public VPS endpoint: ${DOKPLOY_VPS_IP}"
  fi

  if ! pg_dump -Fc -b "${EFFECTIVE_PG_URL}" > "${DUMP_FILE}" 2>"${TEMP_DIR}/pg_dump.log"; then
    log_error "Direct pg_dump failed! Output:"
    cat "${TEMP_DIR}/pg_dump.log" >&2
    exit 1
  fi
else
  # Check if another postgres container is running under a different name
  DISCOVERED_PG="$(docker ps --filter "name=postgres" --format '{{.Names}}' 2>/dev/null | head -n 1 || true)"
  if [[ -n "${DISCOVERED_PG}" ]]; then
    log_warn "Target container '${POSTGRES_CONTAINER}' not found, but '${DISCOVERED_PG}' is active."
    if ! docker exec -i "${DISCOVERED_PG}" pg_dump -U "${PG_USER}" -F c -b -v "${PG_DB}" > "${DUMP_FILE}" 2>"${TEMP_DIR}/pg_dump.log"; then
      log_error "docker exec pg_dump failed! Output:"
      cat "${TEMP_DIR}/pg_dump.log" >&2
      exit 1
    fi
  else
    log_error "Cannot execute database dump: Neither Docker container '${POSTGRES_CONTAINER}' nor direct 'pg_dump' with accessible URL could be executed."
    exit 1
  fi
fi

DUMP_SIZE="$(du -h "${DUMP_FILE}" | cut -f1)"
log_success "Database dump completed successfully (${DUMP_SIZE})"

# ------------------------------------------------------------------------------
# 3. Archive Environment Secrets & Metadata
# ------------------------------------------------------------------------------
log_info "Collecting environment secrets and cryptographic keys..."

if [[ -f "${ENV_FILE}" ]]; then
  cp "${ENV_FILE}" "${TEMP_DIR}/.env.production"
else
  log_warn ".env.production not found! Creating minimal metadata manifest."
fi

# Generate metadata manifest
cat <<EOF > "${TEMP_DIR}/manifest.json"
{
  "backupTimestamp": "${TIMESTAMP}",
  "databaseName": "${PG_DB}",
  "postgresContainer": "${POSTGRES_CONTAINER}",
  "gitCommit": "$(cd "${PROJECT_ROOT}" && git rev-parse HEAD 2>/dev/null || echo "unknown")",
  "gitBranch": "$(cd "${PROJECT_ROOT}" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
}
EOF

# Package into unencrypted tarball inside temp directory
TAR_FILE="${TEMP_DIR}/${BACKUP_PREFIX}.tar.gz"
tar -czf "${TAR_FILE}" -C "${TEMP_DIR}" twenty-database.dump .env.production manifest.json

# ------------------------------------------------------------------------------
# 4. Symmetric AES-256 Encryption (OpenSSL PBKDF2)
# ------------------------------------------------------------------------------
ENC_ARCHIVE="${BACKUP_DIR}/${BACKUP_PREFIX}.tar.gz.enc"

# Encryption passphrase resolution (Priority: BACKUP_PASSPHRASE -> ENCRYPTION_KEY -> APP_SECRET)
PASSPHRASE="${BACKUP_PASSPHRASE:-${ENCRYPTION_KEY:-${APP_SECRET:-}}}"
if [[ -z "${PASSPHRASE}" ]]; then
  log_error "No encryption passphrase found! Please set BACKUP_PASSPHRASE or ensure ENCRYPTION_KEY is present in .env.production."
  exit 1
fi

log_info "Encrypting backup archive with AES-256-CBC (PBKDF2)..."
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
  -in "${TAR_FILE}" \
  -out "${ENC_ARCHIVE}" \
  -pass "pass:${PASSPHRASE}"

chmod 600 "${ENC_ARCHIVE}"
ENC_SIZE="$(du -h "${ENC_ARCHIVE}" | cut -f1)"
log_success "Encrypted archive created: ${ENC_ARCHIVE} (${ENC_SIZE})"

# ------------------------------------------------------------------------------
# 5. Offsite S3 Storage Replication (Cloudflare R2 / Backblaze B2 / MinIO)
# ------------------------------------------------------------------------------
S3_BUCKET="${STORAGE_S3_NAME:-${S3_BUCKET:-}}"
S3_ENDPOINT="${STORAGE_S3_ENDPOINT:-${S3_ENDPOINT:-}}"
S3_REGION="${STORAGE_S3_REGION:-us-east-1}"

if [[ -n "${S3_BUCKET}" ]]; then
  log_info "Uploading encrypted archive to S3 bucket '${S3_BUCKET}'..."

  # Option A: AWS CLI (if available)
  if command -v aws >/dev/null 2>&1; then
    AWS_ENDPOINT_FLAG=()
    if [[ -n "${S3_ENDPOINT}" ]]; then
      AWS_ENDPOINT_FLAG=("--endpoint-url" "${S3_ENDPOINT}")
    fi

    # Pass credentials directly if present
    export AWS_ACCESS_KEY_ID="${STORAGE_S3_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
    export AWS_SECRET_ACCESS_KEY="${STORAGE_S3_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
    export AWS_DEFAULT_REGION="${S3_REGION}"

    if aws s3 cp "${ENC_ARCHIVE}" "s3://${S3_BUCKET}/backups/${BACKUP_PREFIX}.tar.gz.enc" "${AWS_ENDPOINT_FLAG[@]}"; then
      log_success "Successfully uploaded to s3://${S3_BUCKET}/backups/${BACKUP_PREFIX}.tar.gz.enc via aws-cli"
    else
      log_warn "aws-cli upload returned non-zero code. Verify credentials and endpoint."
    fi

  # Option B: Rclone (if available)
  elif command -v rclone >/dev/null 2>&1; then
    if rclone copy "${ENC_ARCHIVE}" "twenty-s3:${S3_BUCKET}/backups/"; then
      log_success "Successfully uploaded to ${S3_BUCKET}/backups/ via rclone"
    else
      log_warn "rclone upload failed. Check rclone config 'twenty-s3'."
    fi

  else
    log_warn "Neither 'aws' CLI nor 'rclone' found on host. Offsite replication skipped. Backup is saved locally."
  fi
else
  log_info "No S3 bucket configured (STORAGE_S3_NAME). Skipping remote replication."
fi

# ------------------------------------------------------------------------------
# 6. Local Backup Pruning (Retain last 7 days)
# ------------------------------------------------------------------------------
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
log_info "Pruning local backup archives older than ${RETENTION_DAYS} days in ${BACKUP_DIR}..."

DELETED_COUNT=0
while IFS= read -r old_file; do
  if [[ -n "${old_file}" ]]; then
    rm -f "${old_file}"
    DELETED_COUNT=$((DELETED_COUNT + 1))
    log_info "Pruned expired backup: $(basename "${old_file}")"
  fi
done < <(find "${BACKUP_DIR}" -type f -name "twenty-backup-*.tar.gz.enc" -mtime +"${RETENTION_DAYS}")

log_success "Backup process completed! Pruned ${DELETED_COUNT} old archives."
echo -e "${CYAN}==============================================================================${NC}"
echo -e "${CYAN}Backup Archive: ${ENC_ARCHIVE}${NC}"
echo -e "${CYAN}To Decrypt:${NC}"
echo -e "  openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in ${ENC_ARCHIVE} -out backup.tar.gz -pass pass:<YOUR_PASSPHRASE>"
echo -e "  tar -xzvf backup.tar.gz"
echo -e "${CYAN}==============================================================================${NC}"
