# shellcheck shell=bash
# Shared helpers for up.sh, down.sh and check-leftovers.sh. Sourced, not executed.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && (pwd -W 2>/dev/null || pwd))
BOOTSTRAP_DIR="$ROOT_DIR/infra/bootstrap"
CLUSTER_DIR="$ROOT_DIR/infra/cluster"
# shellcheck disable=SC2034 # used by the scripts that source this file
KUBECONFIG_FILE="$ROOT_DIR/infra/.kubeconfig"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed or not on PATH."
  done
}

# Prints a bootstrap output, or nothing if the bootstrap stack has not been applied.
# (terraform prints a warning on stdout and exits 0 when outputs are missing.)
bootstrap_output() {
  terraform -chdir="$BOOTSTRAP_DIR" output -json 2>/dev/null |
    python -c "import json,sys; print(json.load(sys.stdin).get('$1', {}).get('value', ''))" 2>/dev/null || true
}

# 32-bit Terraform cannot run some providers (fails with "Unrecognized remote plugin message").
require_64bit_terraform() {
  local platform
  platform=$(terraform version -json 2>/dev/null | python -c "import json,sys; print(json.load(sys.stdin)['platform'])" 2>/dev/null || true)
  [[ "$platform" != *_386 && "$platform" != *_arm ]] ||
    die "Terraform is a 32-bit build ($platform). Install the 64-bit (amd64/arm64) build from https://developer.hashicorp.com/terraform/install"
}

load_bootstrap_outputs() {
  require_64bit_terraform
  STATE_BUCKET=$(bootstrap_output state_bucket)
  REGION=$(bootstrap_output region)
  [[ -n "$STATE_BUCKET" && -n "$REGION" ]] ||
    die "Bootstrap stack not applied. Run: terraform -chdir=infra/bootstrap init && terraform -chdir=infra/bootstrap apply"
}

init_cluster_backend() {
  terraform -chdir="$CLUSTER_DIR" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=cluster/terraform.tfstate" \
    -backend-config="region=$REGION" \
    -backend-config="use_lockfile=true" \
    -backend-config="encrypt=true" >/dev/null
}
