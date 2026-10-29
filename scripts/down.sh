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

    # Stop GitOps first so Argo CD does not recreate what is deleted below.
    if kubectl get namespace argocd >/dev/null 2>&1; then
      log "Stopping Argo CD reconciliation..."
      kubectl delete namespace argocd --wait=true --timeout=5m || true
    fi

    log "Deleting LoadBalancer Services..."
    kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
      while read -r ns name; do
        [[ -n "$ns" ]] && kubectl delete svc -n "$ns" "$name" --wait=true --timeout=5m
      done

    # A volume cannot be released while a pod mounts it, so remove the workloads first.
    # kube-system is kept: it runs the EBS CSI driver and load balancer controller,
    # which must stay up to delete the AWS resources behind volumes and Services.
    log "Deleting application namespaces and workloads..."
    kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
      grep -vxE 'kube-system|kube-public|kube-node-lease|default' |
      xargs -r kubectl delete namespace --wait=true --timeout=10m || true
    kubectl delete statefulsets,deployments,daemonsets,jobs,pods --all -n default --wait=true --timeout=5m || true

    log "Deleting PersistentVolumeClaims and waiting for their EBS volumes to be removed..."
    kubectl delete pvc --all -A --wait=true --timeout=5m || true
    for _ in $(seq 1 30); do
      [[ $(kubectl get pv --no-headers 2>/dev/null | wc -l) -eq 0 ]] && break
      sleep 10
    done

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

  # Safety net: volumes the CSI driver could not delete (e.g. the cluster was unreachable)
  # are tagged as owned by this cluster and are now detached.
  orphans=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$cluster,Values=owned" Name=status,Values=available \
    --query 'Volumes[].VolumeId' --output text)
  for volume in $orphans; do
    log "Deleting orphaned EBS volume $volume"
    aws ec2 delete-volume --region "$REGION" --volume-id "$volume"
  done
  rm -f "$KUBECONFIG_FILE"

  log "Destroyed in $(( ($(date +%s) - started) / 60 )) minutes."
fi

"$SCRIPT_DIR/check-leftovers.sh"
