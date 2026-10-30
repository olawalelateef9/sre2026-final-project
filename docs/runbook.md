# Operations runbook: Techbleat Global Bank

For the people operating the AWS environment. Every Datadog alert links to a section here.
Setup, access and teardown are in [`infra/README.md`](../infra/README.md).

**Conventions.** Commands run from the repository root in Git Bash.
`export KUBECONFIG=infra/.kubeconfig` before any `kubectl`. Record what you did, and
when, in the incident notes. Never paste tokens, passwords or keys into tickets or chat.

---

## Routine operations

### Deploy a release
1. Merge the change to `main`. CI runs tests, scans, then builds, signs and publishes the
   images (`sha-<commit>` in GHCR).
2. `bash scripts/pin-images.sh <full-commit-sha>`, review the diff in
   `deploy/banking/workloads.yaml`, then commit and push.
3. Argo CD rolls it out (rolling update, no downtime). Watch it with
   `kubectl rollout status deploy/<name> -n banking`.
4. Verify the image signature if required:
   `cosign verify ghcr.io/olawalelateef9/techbleat-<service>@<digest> --certificate-identity-regexp '^https://github.com/olawalelateef9/sre2026-final-project/' --certificate-oidc-issuer https://token.actions.githubusercontent.com`

### Roll back
`bash scripts/pin-images.sh <last-known-good-sha>`, then commit and push. Argo CD reverts
within a minute. Demonstrated: rollback live in 17 s with zero failed requests
([evidence](evidence/phase3-live-verification.md#release-and-rollback-a9)). Never roll
back by editing the cluster: Argo CD reverts manual changes (self-heal).

### Back up and restore
- Automated: RDS keeps 7 days of point-in-time-recoverable, encrypted backups.
- Rehearse with `bash scripts/restore-drill.sh`. It restores the latest recovery point
  into a separate private instance, verifies the data, records RPO/RTO in
  `docs/evidence/`, and deletes the copy. Targets: RPO <= 10 min, RTO <= 30 min (measured
  12 min).
- **Real recovery:** run the same restore (`aws rds restore-db-instance-to-point-in-time`),
  then point the application at it. Update the `host` in the
  `techbleat/cluster/db/*` secrets, or rename the instances so the endpoint is reused,
  then restart the banking deployments. Record the restore point you chose.

### Rotate credentials

| Credential | How |
|---|---|
| Database role passwords, Valkey token, provisioner secret, Keycloak admin | Regenerated on every `up`. To rotate mid-session, `terraform -chdir=infra/cluster apply -replace=random_password.<name>`; External Secrets syncs within the hour, or immediately with `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite`. Then restart the consumers. For the provisioner, re-run `configure_realm.py` (up.sh does). |
| Datadog API key | Create a new key in Datadog, update `DD_API_KEY`, re-run `up.sh` (it rewrites the secret), revoke the old key. |
| DuckDNS token | Regenerate it on duckdns.org and update the `DUCKDNS_TOKEN` environment variable. |
| AWS access key (operator) | IAM → Users → Security credentials: create a new key, update `~/.aws/credentials`, deactivate and then delete the old one. |
| Image signing | Nothing to rotate: keyless (GitHub OIDC). |

---

## Alert responses

### high-error-rate
More than 5% of public requests return 5xx.
1. Dashboard *Gateway requests by status*: find which destination service fails.
2. `kubectl get applications -n argocd` and `kubectl get pods -n banking`: is something
   unhealthy or mid-rollout?
3. Logs for that service (Datadog Logs, `service:<name>`) or
   `kubectl logs deploy/<name> -n banking -c <name>`.
4. If a recent release caused it: **roll back** (above). Otherwise treat it as a
   data-service outage or an identity outage if those monitors are also firing.

### high-latency
1. Compare *p95 span duration by service* to see which hop is slow (APM traces show the
   full request path through the mesh).
2. Check saturation (CPU/memory) and data-service CPU. A slow database shows as slow
   transaction-service spans.
3. Scale the affected deployment if saturated (commit a `replicas` change; do not use
   `kubectl scale`, which Argo CD reverts).

### pod-crash-looping
`kubectl describe pod <pod> -n <ns>` and `kubectl logs <pod> -n <ns> --previous`.
Common causes: a missing or wrong secret (check the ExternalSecret status), a dependency
unreachable (database, Kafka, Keycloak), OOM (raise the limit in Git). A bad release:
roll back.

### saturation
Memory near its limit or node CPU high. Confirm the trend on the dashboard. Raise the
limits or replicas in Git. Persistent node pressure: increase `node_count` in
`infra/cluster/variables.tf`.

### authentication-failures
A spike in rejected tokens (`authentication_failed`, logged without the token).
1. Datadog Logs: `authentication_failed`. Group by `reason` and `remote`.
2. Many `invalid signature`/`issuer` failures from a few sources suggest forged tokens:
   check the WAF and rate limits, and block the source at the edge if it is abusive.
3. `Jwt expired` across all users suggests clock skew or a frontend refresh bug.
4. If tokens might have been issued illegitimately, see
   [leaked-credential](#leaked-credential).

### authorization-denials
Authenticated callers denied access, including attempts at another customer's account.
1. Datadog Logs: `authorization_denied`, grouped by `user` and `path`.
2. One user probing many accounts is a **suspected account takeover or insider**: follow
   [suspected-unauthorized-transaction](#suspected-unauthorized-transaction).
3. A burst after a deploy suggests a policy regression: compare with the previous release
   and roll back if needed.

### data-service-outage
Kafka not ready, RDS CPU or storage, or Valkey.
- **Kafka:** `kubectl get kafka,pods -n banking`; the Strimzi operator logs are in the
  `strimzi` namespace. Transactions still commit to the database, but they fail if events
  cannot be published (the API returns 503, safely). Restart the broker pod if it is stuck.
- **RDS:** the AWS console → RDS → `techbleat-postgres` → Monitoring / Logs. Storage
  low: increase `allocated_storage` in Git. Unavailable: follow *Back up and restore*.
- **Valkey:** a cache; balances fall back to the database. Check ElastiCache events.

### identity-outage
No Keycloak task on ECS, so customers cannot sign in.
1. `aws ecs describe-services --cluster techbleat-identity --services keycloak` and the
   latest service events.
2. Logs: CloudWatch `/ecs/techbleat-identity/keycloak`.
3. Common causes: the identity database is unreachable, or the task's secrets cannot be
   read. ECS restarts failed tasks automatically; force a new deployment with
   `aws ecs update-service --cluster techbleat-identity --service keycloak --force-new-deployment`.

### slo-burn
The availability error budget is being spent at more than 14.4 times the sustainable
rate. Treat it as [high-error-rate](#high-error-rate). If the budget is exhausted, freeze
non-urgent releases until it recovers.

---

## Incident playbooks

### leaked-credential
A secret was exposed (committed, logged or pasted).
1. **Contain:** rotate it immediately (see *Rotate credentials*). For an AWS key,
   deactivate it first.
2. **Assess:** CloudTrail for the AWS key's use; Datadog Logs and Keycloak admin events
   (`bash scripts/keycloak-admin.sh` → banking realm → Events) for identity credentials.
3. If it was in Git: rotation is the fix. Rewriting history alone is not enough, because
   forks and caches keep it. gitleaks in CI should have caught it, so add a rule if it did not.
4. Record the timeline, the blast radius and the actions taken.

### suspected-unauthorized-transaction
A customer reports a transfer they did not make, or authorization-denial alerts suggest
probing.
1. **Contain:** disable the user in Keycloak (admin console → Users → *Enabled* off) and
   sign them out of all sessions (*Sessions → Sign out*).
2. **Investigate:** the `transactions` table (via `scripts/restore-drill.sh`-style query
   pods, read only), Keycloak login events for that user (IP, time), and
   `authorization_denied` logs.
3. The APIs enforce ownership on every request, so a transfer *from* an account needs
   that account's valid session: suspect stolen credentials or a stolen session.
4. Reset the password, re-enable after verification, and record the findings.

### failed-deployment
Argo CD shows an application Degraded or Progressing for more than 10 minutes, or the
error-rate alert fires after a release.
1. `kubectl get applications -n argocd`, then describe the failing resource.
2. The rolling update keeps the old pods serving while the new ones fail readiness.
   **Roll back** with `pin-images.sh <previous sha>` and push.
3. Fix forward only once the cause is understood.

### data-service-outage
See [data-service-outage](#data-service-outage) above. If a database must be recovered,
follow *Back up and restore* and record the RPO you actually achieved.

---

## Teardown
`bash scripts/down.sh`, then `bash scripts/check-leftovers.sh`, which must report zero
billable resources. Datadog monitors are configured not to alert on missing data, so
teardown is silent.
