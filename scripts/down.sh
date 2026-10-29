#!/usr/bin/env bash
# Destroy the ephemeral AWS environment and verify nothing billable is left.
#
#   bash scripts/down.sh          # asks for confirmation
#   bash scripts/down.sh --yes    # no prompt
#
# The bootstrap stack (state bucket, budget, TLS backup secret) is kept.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ASSUME_YES=false
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=true

require aws terraform kubectl
load_bootstrap_outputs
init_cluster_backend

cluster=$(terraform -chdir="$CLUSTER_DIR" output -raw cluster_name 2>/dev/null || true)
vpc_id=$(terraform -chdir="$CLUSTER_DIR" output -raw vpc_id 2>/dev/null || true)

if [[ -z "$cluster" ]]; then
  log "No cluster in Terraform state; checking for leftovers only."
else
  if ! $ASSUME_YES; then
    read -r -p "Destroy cluster '$cluster' and everything in it? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || die "Cancelled; nothing was changed."
  fi
  started=$(date +%s)

  # Kubernetes controllers create AWS resources that Terraform does not track:
  # load balancers (Services of type LoadBalancer) and EBS volumes (PersistentVolumeClaims).
  # Delete them while the controllers are still running, or they outlive the cluster.
  if aws eks update-kubeconfig --region "$REGION" --name "$cluster" --kubeconfig "$KUBECONFIG_FILE" --alias "$cluster" >/dev/null 2>&1 \
     && KUBECONFIG="$KUBECONFIG_FILE" kubectl get nodes >/dev/null 2>&1; then
    export KUBECONFIG="$KUBECONFIG_FILE"

    log "Deleting LoadBalancer Services..."
    kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
      while read -r ns name; do
        [[ -n "$ns" ]] && kubectl delete svc -n "$ns" "$name" --wait=true --timeout=5m
      done

    log "Deleting PersistentVolumeClaims..."
    kubectl delete pvc --all -A --wait=true --timeout=5m || true

    if [[ -n "$vpc_id" ]]; then
      log "Waiting for load balancers in $vpc_id to be deleted..."
      for _ in $(seq 1 60); do
        remaining=$(aws elbv2 describe-load-balancers --region "$REGION" \
          --query "length(LoadBalancers[?VpcId=='$vpc_id'])" --output text)
        [[ "$remaining" == "0" ]] && break
        sleep 10
      done
    fi
  else
    log "Cluster API not reachable (already deleted, or this IP is not allowed); skipping in-cluster cleanup."
  fi

  log "Destroying the cluster stack..."
  terraform -chdir="$CLUSTER_DIR" destroy -input=false -auto-approve \
    -var="region=$REGION" -var='admin_cidrs=["127.0.0.1/32"]'

  # EKS can recreate its control-plane log group while the cluster is being deleted,
  # which would make the next `up` fail with "already exists".
  aws logs delete-log-group --region "$REGION" --log-group-name "/aws/eks/$cluster/cluster" >/dev/null 2>&1 || true
  rm -f "$KUBECONFIG_FILE"

  log "Destroyed in $(( ($(date +%s) - started) / 60 )) minutes."
fi

"$SCRIPT_DIR/check-leftovers.sh"
