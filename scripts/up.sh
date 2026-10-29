#!/usr/bin/env bash
# Create or update the ephemeral AWS environment and deploy everything onto it. Rerunnable.
#
#   bash scripts/up.sh          # shows the Terraform plan and asks before applying
#   bash scripts/up.sh --yes    # applies without asking
#
# Steps: Terraform (VPC, EKS, RDS, Valkey, IAM, secrets) -> Argo CD -> restore the TLS
# certificate -> GitOps sync of deploy/ -> point DuckDNS at the load balancer -> configure
# the Keycloak realm. Tear down with scripts/down.sh at the end of each session.
#
# Requires: the bootstrap stack applied once, AWS credentials, terraform (64-bit), kubectl,
# helm, curl, python, and DUCKDNS_TOKEN in the environment.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ASSUME_YES=false
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=true

require aws terraform kubectl helm curl python
[[ -n "${DUCKDNS_TOKEN:-}" ]] || die "DUCKDNS_TOKEN is not set (see infra/README.md)."
load_bootstrap_outputs

started=$(date +%s)

# ---- 1. Infrastructure ---------------------------------------------------------------------

ip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
[[ "$ip" =~ ^[0-9.]+$ ]] || die "Could not determine this machine's public IP."
log "Operator IP $ip will be the only address allowed to reach the Kubernetes API."

init_cluster_backend
log "Planning the cluster stack..."
terraform -chdir="$CLUSTER_DIR" plan -input=false -out=cluster.tfplan \
  -var="region=$REGION" -var="admin_cidrs=[\"$ip/32\"]"

if ! $ASSUME_YES; then
  read -r -p "Apply this plan? It creates billable resources (about \$0.50/hour). [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { rm -f "$CLUSTER_DIR/cluster.tfplan"; die "Cancelled; nothing was changed."; }
fi
terraform -chdir="$CLUSTER_DIR" apply -input=false cluster.tfplan
rm -f "$CLUSTER_DIR/cluster.tfplan"

cluster=$(terraform -chdir="$CLUSTER_DIR" output -raw cluster_name)
aws eks update-kubeconfig --region "$REGION" --name "$cluster" --kubeconfig "$KUBECONFIG_FILE" --alias "$cluster" >/dev/null
export KUBECONFIG="$KUBECONFIG_FILE"
kubectl wait --for=condition=Ready nodes --all --timeout=10m >/dev/null

# ---- 2. Argo CD ----------------------------------------------------------------------------

log "Installing Argo CD..."
# Isolated Helm repository settings, so an operator's own (possibly stale) Helm repos
# cannot break the install.
HELM_REPOSITORY_CONFIG=$(mktemp)
HELM_REPOSITORY_CACHE=$(mktemp -d)
export HELM_REPOSITORY_CONFIG HELM_REPOSITORY_CACHE
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.11.6 \
  --namespace argocd --create-namespace -f "$ROOT_DIR/deploy/argocd/values.yaml" --wait --timeout 10m >/dev/null

# ---- 3. TLS certificate from the previous session ------------------------------------------

backup=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$TLS_BACKUP_SECRET" \
  --query SecretString --output text 2>/dev/null || true)
if [[ -n "$backup" && "$backup" != "None" ]]; then
  log "Restoring the TLS certificate saved by the last scripts/down.sh..."
  kubectl create namespace istio-ingress --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  printf '%s' "$backup" | kubectl apply -f - >/dev/null
else
  log "No saved TLS certificate; cert-manager will request one."
fi

# ---- 4. GitOps --------------------------------------------------------------------------------

log "Handing over to Argo CD (deploy/ on main)..."
kubectl apply -f "$ROOT_DIR/deploy/argocd/projects.yaml" -f "$ROOT_DIR/deploy/argocd/root.yaml" >/dev/null

# ---- 5. DNS ---------------------------------------------------------------------------------
# Must happen before waiting for health: the TLS certificate cannot be issued until the
# domain points at the load balancer (Let's Encrypt validates over HTTP).

log "Waiting for the platform to create the public load balancer..."
lb_host=""
for _ in $(seq 1 120); do
  lb_host=$(kubectl get gateway public -n istio-ingress -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  [[ -n "$lb_host" ]] && break
  sleep 15
done
[[ -n "$lb_host" ]] || die "The gateway has no load balancer address after 30 minutes. Inspect with: kubectl get applications -n argocd"

lb_ip=""
for _ in $(seq 1 60); do
  lb_ip=$(python -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$lb_host" 2>/dev/null || true)
  [[ -n "$lb_ip" ]] && break
  sleep 10
done
[[ -n "$lb_ip" ]] || die "Load balancer $lb_host does not resolve yet; rerun scripts/up.sh in a few minutes."

duckdns_update "ip=$lb_ip" || die "DuckDNS update failed."
log "$DOMAIN -> $lb_ip ($lb_host)"

wait_for_applications 1800

# ---- 6. Keycloak realm --------------------------------------------------------------------

log "Configuring the Keycloak realm..."
kubectl rollout status deployment/keycloak -n keycloak --timeout=10m >/dev/null
kubectl port-forward -n keycloak svc/keycloak 18080:8080 >/dev/null 2>&1 &
forward_pid=$!
trap 'kill $forward_pid 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -fsS -o /dev/null http://localhost:18080/realms/master && break
  sleep 2
done

KEYCLOAK_URL=http://localhost:18080 \
FRONTEND_URL="https://$DOMAIN" \
KEYCLOAK_SSL_REQUIRED=all \
KEYCLOAK_ADMIN_USERNAME=$(cluster_secret keycloak/admin username) \
KEYCLOAK_ADMIN_PASSWORD=$(cluster_secret keycloak/admin password) \
KEYCLOAK_PROVISIONER_SECRET=$(cluster_secret keycloak/provisioner client_secret) \
  python "$ROOT_DIR/keycloak/configure_realm.py"

# ---- 7. Demo customers (synthetic data, new passwords every session) -----------------------

log "Seeding demo customers alice and bob..."
demo_file=$(mktemp)
chmod 600 "$demo_file"
python - > "$demo_file" <<'EOF'
import json, secrets
users = [
    {"id": "alice", "full_name": "Alice Demo", "email": "alice@example.com"},
    {"id": "bob", "full_name": "Bob Demo", "email": "bob@example.com"},
]
for user in users:
    user["password"] = "Demo-" + secrets.token_urlsafe(18)
print(json.dumps(users))
EOF
demo_path=$demo_file
command -v cygpath >/dev/null 2>&1 && demo_path=$(cygpath -m "$demo_file")
# Store first, so the credentials are never lost; outside techbleat/cluster/* so the
# cluster itself cannot read them.
if aws secretsmanager describe-secret --region "$REGION" --secret-id "$DEMO_USERS_SECRET" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --region "$REGION" --secret-id "$DEMO_USERS_SECRET" \
    --secret-string "file://$demo_path" >/dev/null
else
  aws secretsmanager create-secret --region "$REGION" --name "$DEMO_USERS_SECRET" \
    --description "Demo customer credentials for the current session (synthetic data)" \
    --secret-string "file://$demo_path" >/dev/null
fi
APP_URL="https://$DOMAIN" \
KEYCLOAK_URL=http://localhost:18080 \
KEYCLOAK_ADMIN_USERNAME=$(cluster_secret keycloak/admin username) \
KEYCLOAK_ADMIN_PASSWORD=$(cluster_secret keycloak/admin password) \
DEMO_USERS=$(cat "$demo_file") \
  python "$ROOT_DIR/keycloak/seed_demo_users.py"
rm -f "$demo_file"

kill $forward_pid 2>/dev/null || true
trap - EXIT

# ---- Done ---------------------------------------------------------------------------------

log "Environment is up after $(( ($(date +%s) - started) / 60 )) minutes."
cat <<EOF

  App:        https://$DOMAIN
  Keycloak:   https://auth.$DOMAIN  (admin console: kubectl port-forward -n keycloak svc/keycloak 18080:8080)
  Demo users: alice, bob. Passwords: aws secretsmanager get-secret-value --region $REGION --secret-id $DEMO_USERS_SECRET --query SecretString --output text
  Argo CD:    kubectl port-forward -n argocd svc/argocd-server 8443:443  -> https://localhost:8443
              admin password: kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  kubectl:    export KUBECONFIG="$KUBECONFIG_FILE"

  Run scripts/down.sh when you finish.
EOF
