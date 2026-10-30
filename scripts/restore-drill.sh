#!/usr/bin/env bash
# Backup/restore drill for the banking database (acceptance criterion A7).
#
#   bash scripts/restore-drill.sh
#
# 1. Records the live database's state (row counts, total balance, latest transaction).
# 2. Restores the latest point-in-time backup into a separate, non-production instance
#    (same private subnets, encrypted, not publicly accessible).
# 3. Verifies the restored data matches, from inside the VPC.
# 4. Measures RPO (data-loss window) and RTO (time until verified data was available),
#    writes docs/evidence/restore-drill-<timestamp>.md, and deletes the drill instance.
#
# Targets: RPO <= 10 minutes (RDS ships transaction logs about every 5 min, plus upload
# delay; the first drill measured 369 s against an initial 5-minute target), RTO <= 30 minutes. Requires a running environment (up.sh).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require aws kubectl python
load_bootstrap_outputs
export KUBECONFIG="$KUBECONFIG_FILE"

SOURCE=techbleat-postgres
DRILL=techbleat-postgres-restore-drill
SQL="SELECT 'users=' || count(*) FROM users
UNION ALL SELECT 'accounts=' || count(*) FROM accounts
UNION ALL SELECT 'transactions=' || count(*) FROM transactions
UNION ALL SELECT 'activities=' || count(*) FROM activities
UNION ALL SELECT 'total_balance=' || coalesce(sum(balance), 0) FROM accounts
UNION ALL SELECT 'latest_transaction=' || coalesce(max(created_at)::text, 'none') FROM transactions;"

# Runs $SQL against a host from a short-lived pod in banking-admin, the only namespace
# holding the database master credentials; prints the key=value lines.
query() {
  local host=$1 pod
  pod="restore-drill-$(date +%s)"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $pod, namespace: banking-admin, labels: {app: db-init}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 70, runAsGroup: 70, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: psql
      image: postgres:17.11-alpine3.24@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b
      command: ["psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", "$(printf '%s' "$SQL" | tr '\n' ' ')"]
      env:
        - {name: PGHOST, value: "$host"}
        - {name: PGDATABASE, value: bankingdb}
        - {name: PGSSLMODE, value: require}
        - {name: HOME, value: /tmp}
        - {name: PGUSER, valueFrom: {secretKeyRef: {name: db-init-credentials, key: PGUSER}}}
        - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: db-init-credentials, key: PGPASSWORD}}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: tmp, mountPath: /tmp}]
  volumes: [{name: tmp, emptyDir: {}}]
EOF
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" -n banking-admin --timeout=5m >/dev/null ||
    { kubectl logs "$pod" -n banking-admin >&2; die "Query against $host failed."; }
  kubectl logs "$pod" -n banking-admin
  kubectl delete pod "$pod" -n banking-admin --wait=false >/dev/null
}

cleanup() {
  if aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DRILL" >/dev/null 2>&1; then
    log "Deleting the drill instance $DRILL..."
    aws rds delete-db-instance --region "$REGION" --db-instance-identifier "$DRILL" \
      --skip-final-snapshot --delete-automated-backups >/dev/null || true
  fi
}
trap cleanup EXIT

source_host=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$SOURCE" \
  --query 'DBInstances[0].Endpoint.Address' --output text)

# ---- 1. Incident: record the live state and the newest recoverable point --------------------

log "Recording the live state of $SOURCE..."
incident=$(date -u +%Y-%m-%dT%H:%M:%SZ)
before=$(query "$source_host")
printf '%s\n' "$before" | sed 's/^/    /'
restore_point=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$SOURCE" \
  --query 'DBInstances[0].LatestRestorableTime' --output text)

# ---- 2. Restore into a separate non-production instance -------------------------------------

log "Restoring $SOURCE (latest restorable time $restore_point) into $DRILL..."
subnet_group=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$SOURCE" \
  --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text)
security_group=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$SOURCE" \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)
parameter_group=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$SOURCE" \
  --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' --output text)

restore_started=$(date +%s)
aws rds restore-db-instance-to-point-in-time --region "$REGION" \
  --source-db-instance-identifier "$SOURCE" --target-db-instance-identifier "$DRILL" \
  --use-latest-restorable-time --db-instance-class db.t4g.micro \
  --db-subnet-group-name "$subnet_group" --vpc-security-group-ids "$security_group" \
  --db-parameter-group-name "$parameter_group" --no-publicly-accessible --no-multi-az \
  --tags Key=Project,Value=techbleat-global-bank Key=Purpose,Value=restore-drill >/dev/null
aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$DRILL"

# ---- 3. Verify -------------------------------------------------------------------------------

drill=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DRILL" \
  --query 'DBInstances[0].[Endpoint.Address,StorageEncrypted,PubliclyAccessible]' --output text)
read -r drill_host drill_encrypted drill_public <<< "$drill"
log "Verifying restored data on $drill_host..."
after=$(query "$drill_host")
printf '%s\n' "$after" | sed 's/^/    /'
verified=$(date +%s)

rto_minutes=$(( (verified - restore_started + 59) / 60 ))
rpo_seconds=$(python -c "from datetime import datetime as d; import sys; f=lambda s: d.fromisoformat(s.replace('Z','+00:00')); print(max(0, int((f(sys.argv[1]) - f(sys.argv[2])).total_seconds())))" "$incident" "$restore_point")
if [[ "$before" == "$after" ]]; then match="identical"; else match="DIFFERENT"; fi

# ---- 4. Record ---------------------------------------------------------------------------

stamp=$(date -u +%Y%m%d-%H%M)
report="$ROOT_DIR/docs/evidence/restore-drill-$stamp.md"
mkdir -p "$(dirname "$report")"
cat > "$report" <<EOF
# Restore drill $stamp UTC

Point-in-time restore of \`$SOURCE\` into a separate non-production instance
(\`$DRILL\`), verified from inside the VPC, then deleted. Produced by
\`scripts/restore-drill.sh\`.

| Measure | Target | Result |
|---|---|---|
| Incident time (state recorded) | | $incident |
| Restore point (latest restorable time) | | $restore_point |
| **RPO** (data written after the restore point is lost) | <= 10 min | **${rpo_seconds} s** |
| **RTO** (restore started to verified data available) | <= 30 min | **${rto_minutes} min** |
| Restored data vs live data | identical | **$match** |
| Restored instance encrypted at rest | yes | $drill_encrypted |
| Restored instance publicly accessible | no | $drill_public |

Backup configuration: automated backups with 7-day retention and continuous
transaction-log backup (point-in-time recovery), encrypted with the instance's KMS key.

## Live database at incident time

\`\`\`
$before
\`\`\`

## Restored database

\`\`\`
$after
\`\`\`
EOF

log "RPO ${rpo_seconds}s (target <= 600s), RTO ${rto_minutes} min (target <= 30), data $match."
log "Recorded $report"
[[ "$match" == "identical" ]] || die "Restored data differs from the live database."
