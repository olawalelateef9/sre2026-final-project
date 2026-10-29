#!/usr/bin/env bash
# Create or update the ephemeral AWS environment. Safe to rerun.
#
#   bash scripts/up.sh          # shows the Terraform plan and asks before applying
#   bash scripts/up.sh --yes    # applies without asking
#
# Requires: the bootstrap stack applied once (infra/bootstrap), AWS credentials,
# terraform, kubectl, curl. Tear down with scripts/down.sh at the end of each session.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ASSUME_YES=false
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=true

require aws terraform kubectl curl
load_bootstrap_outputs

ip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
[[ "$ip" =~ ^[0-9.]+$ ]] || die "Could not determine this machine's public IP."
log "Operator IP $ip will be the only address allowed to reach the Kubernetes API."

init_cluster_backend

log "Planning the cluster stack..."
terraform -chdir="$CLUSTER_DIR" plan -input=false -out=cluster.tfplan \
  -var="region=$REGION" -var="admin_cidrs=[\"$ip/32\"]"

if ! $ASSUME_YES; then
  read -r -p "Apply this plan? It creates billable resources (about \$0.35-0.50/hour). [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { rm -f "$CLUSTER_DIR/cluster.tfplan"; die "Cancelled; nothing was changed."; }
fi

started=$(date +%s)
terraform -chdir="$CLUSTER_DIR" apply -input=false cluster.tfplan
rm -f "$CLUSTER_DIR/cluster.tfplan"

cluster=$(terraform -chdir="$CLUSTER_DIR" output -raw cluster_name)
aws eks update-kubeconfig --region "$REGION" --name "$cluster" --kubeconfig "$KUBECONFIG_FILE" --alias "$cluster" >/dev/null
export KUBECONFIG="$KUBECONFIG_FILE"

log "Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get nodes -o wide

log "Environment is up after $(( ($(date +%s) - started) / 60 )) minutes."
log "Use it with:  export KUBECONFIG=\"$KUBECONFIG_FILE\""
log "Ingress IP:   $(terraform -chdir="$CLUSTER_DIR" output -raw ingress_public_ip)"
log "Remember to run scripts/down.sh when you finish."
