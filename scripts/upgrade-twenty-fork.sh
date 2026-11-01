#!/usr/bin/env bash
# ==============================================================================
# Twenty CRM - Upstream Fork Rebase & Automated Upgrade Script
# Checklist Item 11: Day-2 Operations & Monthly Upstream Soft-Fork Upgrades
# ==============================================================================
set -euo pipefail

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [ERROR]${NC} $*" >&2; }

# Locate repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# ------------------------------------------------------------------------------
# 1. Argument Validation
# ------------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo -e "${RED}Error: Missing target release tag.${NC}"
  echo -e "Usage:"
  echo -e "  ${BOLD}$0 <target-release-tag>${NC}"
  echo -e "Example:"
  echo -e "  ${BOLD}$0 v2.10.0${NC}"
  exit 1
fi

TARGET_TAG="$1"

# Normalize tag format (prepend 'v' if omitted e.g. '2.10.0' -> 'v2.10.0')
if [[ ! "${TARGET_TAG}" =~ ^v ]]; then
  TARGET_TAG="v${TARGET_TAG}"
fi

log_info "Initiating upgrade sequence to upstream target: ${BOLD}${TARGET_TAG}${NC}"

# ------------------------------------------------------------------------------
# 2. Pre-flight Working Tree Cleanliness Check
# ------------------------------------------------------------------------------
log_info "Checking git working directory status..."
if ! git diff-index --quiet HEAD --; then
  log_error "Uncommitted local changes detected in working tree."
  git status --short
  echo -e "${YELLOW}Please commit or stash your changes before upgrading.${NC}"
  exit 1
fi
log_success "Working directory is clean."

# ------------------------------------------------------------------------------
# 3. Pre-flight Safety Backup
# ------------------------------------------------------------------------------
BACKUP_SCRIPT="${SCRIPT_DIR}/backup-twenty.sh"
if [[ -f "${BACKUP_SCRIPT}" ]]; then
  log_info "Executing pre-flight safety database & secrets backup..."
  if bash "${BACKUP_SCRIPT}"; then
    log_success "Pre-flight backup succeeded. Proceeding with upgrade."
  else
    log_error "Pre-flight backup failed! Aborting upgrade to protect production data."
    exit 1
  fi
else
  log_warn "Backup script ${BACKUP_SCRIPT} not found. Skipping automated backup step."
fi

# ------------------------------------------------------------------------------
# 4. Upstream Remote Verification & Tag Fetching
# ------------------------------------------------------------------------------
UPSTREAM_URL="https://github.com/twentyhq/twenty.git"
log_info "Verifying 'upstream' remote..."

if ! git remote get-url upstream >/dev/null 2>&1; then
  log_info "Adding upstream remote: ${UPSTREAM_URL}"
  git remote add upstream "${UPSTREAM_URL}"
else
  log_info "Upstream remote configured: $(git remote get-url upstream)"
fi

log_info "Fetching latest tags from upstream..."
git fetch upstream --tags --force

# Verify target tag exists in git repository
if ! git rev-parse -q --verify "refs/tags/${TARGET_TAG}" >/dev/null; then
  log_error "Target tag '${TARGET_TAG}' was not found in fetched upstream tags."
  echo -e "${YELLOW}Available recent tags:${NC}"
  git tag -l "v2.*" | tail -n 10
  exit 1
fi
log_success "Verified target tag '${TARGET_TAG}' exists."

# ------------------------------------------------------------------------------
# 5. Branch Checkout & Rebase
# ------------------------------------------------------------------------------
TARGET_BRANCH="agency-prod"
log_info "Ensuring branch '${TARGET_BRANCH}' is active..."
git checkout "${TARGET_BRANCH}"

# Pull latest commits from origin if tracking
if git rev-parse --verify "origin/${TARGET_BRANCH}" >/dev/null 2>&1; then
  log_info "Syncing local '${TARGET_BRANCH}' with 'origin/${TARGET_BRANCH}'..."
  git pull --ff-only origin "${TARGET_BRANCH}" || true
fi

CURRENT_BASE="$(git describe --tags --abbrev=0 2>/dev/null || echo "unknown")"
log_info "Current base tag: ${CURRENT_BASE} -> Rebasing onto: ${TARGET_TAG}"

if git rebase "${TARGET_TAG}"; then
  log_success "Rebase completed cleanly on top of ${TARGET_TAG}!"
else
  log_error "Rebase conflict detected!"
  echo -e "${YELLOW}==============================================================================${NC}"
  echo -e "${YELLOW}A conflict occurred while rebasing your agency soft-fork onto ${TARGET_TAG}.${NC}"
  echo -e "Inspect and resolve conflicts using:"
  echo -e "  1. git status"
  echo -e "  2. Edit conflicting files and stage them with: git add <file>"
  echo -e "  3. Continue rebase: git rebase --continue"
  echo -e "  4. Or abort to restore state: git rebase --abort"
  echo -e "${YELLOW}==============================================================================${NC}"
  exit 1
fi

# ------------------------------------------------------------------------------
# 6. Push Rebased Fork to GitHub (Triggering GHCR Build)
# ------------------------------------------------------------------------------
log_info "Pushing updated '${TARGET_BRANCH}' to origin with --force-with-lease..."

if git push origin "${TARGET_BRANCH}" --force-with-lease; then
  log_success "Successfully pushed rebased '${TARGET_BRANCH}' to origin!"
else
  log_error "git push failed. Check your network or GitHub credentials."
  exit 1
fi

# ------------------------------------------------------------------------------
# 7. Upgrade Summary & Day-2 Next Steps
# ------------------------------------------------------------------------------
NEW_COMMIT="$(git rev-parse --short HEAD)"
echo -e "\n${CYAN}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}Twenty CRM Soft-Fork Upgrade Succeeded!${NC}"
echo -e "${CYAN}Target Release:${NC} ${TARGET_TAG}"
echo -e "${CYAN}New Head Commit:${NC} ${NEW_COMMIT}"
echo -e "${CYAN}Branch:${NC} ${TARGET_BRANCH}"
echo -e "${CYAN}==============================================================================${NC}"
echo -e "Next Steps for Deployment:"
echo -e "  1. Monitor GitHub Actions GHCR Docker build:"
echo -e "     https://github.com/thewaqasPro/twenty/actions"
echo -e "  2. Once the image ghcr.io/thewaqaspro/twenty:latest is published, Dokploy"
echo -e "     will pull the latest image during the next compose deployment."
echo -e "  3. Trigger compose redeploy in Dokploy or run:"
echo -e "     curl -X POST https://console.kyndstudio.com/api/compose.deploy \\"
echo -e "       -H 'x-api-key: <DOKPLOY_API_KEY>' \\"
echo -e "       -H 'Content-Type: application/json' \\"
echo -e "       -d '{\"composeId\": \"C2yGJCMsac398s_cfwmEb\"}'"
echo -e "${CYAN}==============================================================================${NC}\n"
