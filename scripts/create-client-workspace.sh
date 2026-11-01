#!/usr/bin/env bash
# ==============================================================================
# Client Workspace Provisioner for Twenty CRM
# ==============================================================================
# Provisions isolated multi-tenant client workspaces with exact subdomains
# (e.g. client1.crm.kyndstudio.com) on Dokploy with automated SSL & schema setup.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Color codes
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BOLD="\033[1m"
NC="\033[0m"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

print_help() {
  echo -e "${BOLD}Twenty CRM - Client Workspace Provisioning Tool${NC}

${BOLD}USAGE:${NC}
  ./scripts/create-client-workspace.sh --name <name> --subdomain <subdomain>
  ./scripts/create-client-workspace.sh --list
  ./scripts/create-client-workspace.sh --help

${BOLD}OPTIONS:${NC}
  -n, --name <name>            Client / Company display name (e.g. \"Acme Corp\")
  -s, --subdomain <subdomain>  Subdomain slug (e.g. \"acme\" -> https://acme.crm.kyndstudio.com)
  -l, --list                   List all existing workspaces, URLs, and available slots
  -h, --help                   Display this help message

${BOLD}EXAMPLES:${NC}
  ./scripts/create-client-workspace.sh --name \"Client 2\" --subdomain \"client2\"
  ./scripts/create-client-workspace.sh -n \"Alpha Agency\" -s \"alpha\"
  ./scripts/create-client-workspace.sh --list
"
}

# Check arguments for help flag
for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    print_help
    exit 0
  fi
done

# Check prerequisites
if ! command -v node >/dev/null 2>&1; then
  log_error "Node.js is required but not installed."
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  log_error "psql command-line client is required but not installed."
  exit 1
fi

if [[ ! -f "${ROOT_DIR}/.env.production" ]]; then
  log_error ".env.production file not found in ${ROOT_DIR}."
  exit 1
fi

if [[ ! -f "${ROOT_DIR}/.env.dokploy" ]]; then
  log_error ".env.dokploy file not found in ${ROOT_DIR}."
  exit 1
fi

# Run engine
cd "${ROOT_DIR}"
exec node "${SCRIPT_DIR}/provision-workspace.js" "$@"
