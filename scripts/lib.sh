# shellcheck shell=bash
# Shared helpers for up.sh, down.sh and check-leftovers.sh. Sourced, not executed.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && (pwd -W 2>/dev/null || pwd))
BOOTSTRAP_DIR="$ROOT_DIR/infra/bootstrap"
CLUSTER_DIR="$ROOT_DIR/infra/cluster"
# shellcheck disable=SC2034 # used by the scripts that source this file
KUBECONFIG_FILE="$ROOT_DIR/infra/.kubeconfig"
DOMAIN="techbleatglobalbank.duckdns.org"
# shellcheck disable=SC2034
TLS_BACKUP_SECRET="techbleat/tls-certificate-backup"
# shellcheck disable=SC2034
DEMO_USERS_SECRET="techbleat/demo-users"

# On Windows (Git Bash) Terraform runs in a Linux container: antivirus has repeatedly
# quarantined provider plugins (terraform-provider-cloudinit) while Terraform was running.
# Plugins live in a Docker volume, outside the scanned Windows file system. Set
# TERRAFORM_DOCKER=1 to force this elsewhere, or 0 to use a local terraform binary.
TERRAFORM_IMAGE="hashicorp/terraform:1.16.6@sha256:bfffc1ded5fbf0a17beaaf22eb4793980abdb19d0761ff6a3a0efb2ab4d9b316"
if [[ "${TERRAFORM_DOCKER:-auto}" == "1" || ( "${TERRAFORM_DOCKER:-auto}" == "auto" && "$(uname -s)" == MINGW* ) ]]; then
  terraform() {
    local args=() stack=default arg relative aws_dir
    for arg in "$@"; do
      if [[ "$arg" == -chdir=* ]]; then
        relative=${arg#-chdir=}
        relative=${relative#"$ROOT_DIR"/}
        args+=("-chdir=/work/$relative")
        stack=$(basename "$relative")
      else
        args+=("$arg")
      fi
    done
    aws_dir="$HOME/.aws"
    command -v cygpath >/dev/null 2>&1 && aws_dir=$(cygpath -m "$aws_dir")
    MSYS_NO_PATHCONV=1 docker run --rm -i \
      -v "$ROOT_DIR:/work" \
      -v "$aws_dir:/root/.aws:ro" \
      -v techbleat-terraform-data:/tfdata \
      -e "TF_DATA_DIR=/tfdata/$stack" \
      -e AWS_PROFILE -e AWS_REGION -e TF_IN_AUTOMATION=1 \
      -w /work "$TERRAFORM_IMAGE" "${args[@]}"
  }
fi

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
  # Plugins must be present for this Terraform data directory (container or local).
  terraform -chdir="$BOOTSTRAP_DIR" init -input=false >/dev/null 2>&1 || true
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

# Prints one property of a techbleat/cluster/* secret without echoing it anywhere else.
cluster_secret() {
  aws secretsmanager get-secret-value --region "$REGION" --secret-id "techbleat/cluster/$1" \
    --query SecretString --output text |
    python -c "import json,sys; print(json.load(sys.stdin)['$2'])"
}

# Prints one property of a techbleat/identity/* secret (identity platform, outside EKS).
identity_secret() {
  aws secretsmanager get-secret-value --region "$REGION" --secret-id "techbleat/identity/$1" \
    --query SecretString --output text |
    python -c "import json,sys; print(json.load(sys.stdin)['$2'])"
}

# Opens an SSM port forward from localhost:18443 to the Keycloak task on ECS (audited in
# CloudTrail; no inbound network path from the operator). Sets KEYCLOAK_CA_FILE to the
# identity CA so callers verify Keycloak's certificate. Close with close_keycloak_tunnel.
open_keycloak_tunnel() {
  require session-manager-plugin
  local cluster task runtime session_log ca_file
  cluster=$(terraform -chdir="$CLUSTER_DIR" output -raw identity_cluster)

  aws ecs wait services-stable --region "$REGION" --cluster "$cluster" --services keycloak ||
    die "Keycloak service on ECS did not become stable."
  task=$(aws ecs list-tasks --region "$REGION" --cluster "$cluster" --service-name keycloak \
    --query 'taskArns[0]' --output text)
  runtime=$(aws ecs describe-tasks --region "$REGION" --cluster "$cluster" --tasks "$task" \
    --query "tasks[0].containers[?name=='keycloak'].runtimeId | [0]" --output text)

  ca_file=$(mktemp)
  terraform -chdir="$CLUSTER_DIR" output -raw identity_ca_pem > "$ca_file"
  KEYCLOAK_CA_FILE=$ca_file
  command -v cygpath >/dev/null 2>&1 && KEYCLOAK_CA_FILE=$(cygpath -m "$ca_file")
  export KEYCLOAK_CA_FILE

  session_log=$(mktemp)
  aws ssm start-session --region "$REGION" --target "ecs:${cluster}_${task##*/}_${runtime}" \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["8443"],"localPortNumber":["18443"]}' > "$session_log" 2>&1 &
  KEYCLOAK_TUNNEL_LOG=$session_log

  for _ in $(seq 1 30); do
    curl -fsS --cacert "$ca_file" -o /dev/null https://localhost:18443/realms/master 2>/dev/null && return 0
    sleep 2
  done
  cat "$session_log" >&2
  die "Could not reach Keycloak through the SSM port forward."
}

close_keycloak_tunnel() {
  local session
  session=$(grep -oE 'SessionId: [^ ]+' "${KEYCLOAK_TUNNEL_LOG:-/dev/null}" 2>/dev/null | head -1 | cut -d' ' -f2 || true)
  [[ -n "$session" ]] && aws ssm terminate-session --region "$REGION" --session-id "${session%.}" >/dev/null 2>&1 || true
  rm -f "${KEYCLOAK_TUNNEL_LOG:-}"
}

# Calls the DuckDNS update API with the given query (ip=... or clear=true). The token is
# read from DUCKDNS_TOKEN and never printed.
duckdns_update() {
  local subdomain=${DOMAIN%%.duckdns.org} response
  response=$(curl -fsS "https://www.duckdns.org/update?domains=$subdomain&token=$DUCKDNS_TOKEN&$1" || true)
  [[ "$response" == "OK" ]]
}

# Waits until every Argo CD Application is Synced and Healthy, printing progress.
wait_for_applications() {
  local timeout=$1 waited=0 status pending
  while true; do
    status=$(kubectl get applications -n argocd \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
    pending=$(printf '%s\n' "$status" | awk 'NF && !($2=="Synced" && $3=="Healthy")')
    if [[ -n "$status" && -z "$pending" ]]; then
      log "All Argo CD applications are Synced and Healthy."
      return 0
    fi
    if (( waited >= timeout )); then
      printf '%s\n' "$pending" >&2
      die "Applications not healthy after $((timeout / 60)) minutes. Inspect with: kubectl get applications -n argocd"
    fi
    printf '    waiting (%dm): %s\n' $((waited / 60)) "$(printf '%s' "$pending" | awk '{printf "%s[%s/%s] ", $1, $2, $3}')"
    sleep 30
    waited=$((waited + 30))
  done
}

init_cluster_backend() {
  terraform -chdir="$CLUSTER_DIR" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=cluster/terraform.tfstate" \
    -backend-config="region=$REGION" \
    -backend-config="use_lockfile=true" \
    -backend-config="encrypt=true" >/dev/null
}
