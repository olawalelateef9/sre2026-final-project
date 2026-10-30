#!/usr/bin/env bash
# Plan and apply the Datadog configuration (infra/datadog): AWS integration, monitors,
# availability SLO with burn-rate alert, and the service-health dashboard.
#
#   bash scripts/datadog.sh          # shows the plan and asks before applying
#   bash scripts/datadog.sh --yes
#
# Persistent and free while the environment is down; rerun after changing infra/datadog.
# Needs DD_API_KEY, DD_APP_KEY and DD_SITE in the environment, and
# infra/datadog/terraform.tfvars (copy terraform.tfvars.example).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ASSUME_YES=false
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=true

require terraform
[[ -n "${DD_API_KEY:-}" && -n "${DD_APP_KEY:-}" ]] || die "Set DD_API_KEY and DD_APP_KEY (Datadog Organization Settings)."
DD_SITE=${DD_SITE:-datadoghq.eu}
[[ -f "$ROOT_DIR/infra/datadog/terraform.tfvars" ]] ||
  die "Create infra/datadog/terraform.tfvars from terraform.tfvars.example (alert email)."
load_bootstrap_outputs

DATADOG_DIR="$ROOT_DIR/infra/datadog"
terraform -chdir="$DATADOG_DIR" init -input=false -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=datadog/terraform.tfstate" \
  -backend-config="region=$REGION" \
  -backend-config="use_lockfile=true" \
  -backend-config="encrypt=true" >/dev/null

terraform -chdir="$DATADOG_DIR" plan -input=false -out=datadog.tfplan \
  -var="datadog_site=$DD_SITE" -var="region=$REGION"

if ! $ASSUME_YES; then
  read -r -p "Apply this Datadog plan? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { rm -f "$DATADOG_DIR/datadog.tfplan"; die "Cancelled; nothing was changed."; }
fi
terraform -chdir="$DATADOG_DIR" apply -input=false datadog.tfplan
rm -f "$DATADOG_DIR/datadog.tfplan"

log "Dashboard: $(terraform -chdir="$DATADOG_DIR" output -raw dashboard_url)"
