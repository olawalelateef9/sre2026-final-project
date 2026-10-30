# Completion report: Techbleat Global Bank secure deployment

Prepared 2026-10-30. Repository: `olawalelateef9/sre2026-final-project` (`main`).
Environment: AWS `eu-west-2`, public URL `https://techbleatglobalbank.duckdns.org`
(identity: `https://auth.techbleatglobalbank.duckdns.org`).

The environment is **ephemeral by design**. `scripts/up.sh` builds it in about 25 minutes
and `scripts/down.sh` removes every billable resource. Live results below were recorded on
2026-10-29 and 2026-10-30 and can be reproduced by running `up.sh` again.

Key documents:
[environment architecture](environment-architecture.md) ·
[threat model](threat-model.md) ·
[runbook](runbook.md) ·
[build/operate/teardown guide](../infra/README.md) ·
[least-privilege review](security/least-privilege-review.md) ·
[supply chain](security/supply-chain.md) ·
evidence: [platform](evidence/phase3-live-verification.md),
[restore drill](evidence/restore-drill-20261030-1148.md),
[observability](evidence/phase5-observability.md)

## Acceptance criteria

| # | Criterion (short) | Status | Evidence | Result | Gaps / residual risk |
|---|---|---|---|---|---|
| A1 | HTTPS URL, valid certificate, HTTP→HTTPS | **Met** | [Edge, TLS and exposure](evidence/phase3-live-verification.md#edge-tls-and-exposure-a1-a2) | `301` to HTTPS; Let's Encrypt production cert for both hostnames, verified without `-k`; reused across sessions | DuckDNS instead of a managed DNS provider |
| A2 | Only approved routes public | **Met** | Same section; [gateway](../deploy/platform/policy/gateway.yaml), [routes](../deploy/banking) | External nmap: only 80/443 open. RDS, Valkey, Keycloak private; Keycloak admin and master realm `404`; EKS API limited to one IP; WAF blocks SQLi/XSS | Mesh egress open (`ALLOW_ANY`) |
| A3 | OIDC + PKCE login/logout; minimal redirect/origin lists | **Met** | [banking-realm.json](../keycloak/banking-realm.json) (no secrets in it); demo sign-in and sign-out | Auth Code + S256 PKCE only; implicit and password grants off; one redirect URI, one web origin and the post-logout URI, all the deployed URL; confidential client has none | No MFA or email verification |
| A4 | Bad tokens rejected | **Met** | Test suites: [user](../techbleat-global-bank-backend/user-service/tests/test_security.py), [transaction](../techbleat-global-bank-backend/transaction-service/src/test/java/com/techbleat/bank/controller/TransactionSecurityTest.java), [activity](../techbleat-global-bank-backend/activity-service/tests/test_security.py), [agent](../finance-agent/tests/test_auth.py); [live checks](evidence/phase3-live-verification.md#api-authentication-through-the-public-edge-a4) | Missing, expired, wrong-signature, `alg:none`, wrong-issuer, wrong-audience and missing-role tokens → `401`/`403` (75 automated tests in CI; live `401`s) | None |
| A5 | Cross-account access denied server-side | **Met** | Same suites (cross-account cases); [authorization-denials runbook](runbook.md#authorization-denials) | Identity taken only from the token; other users' balances, activity, transfers and deposits → `403`; directory endpoint removed (`405`) | Self-deposit enabled for the demo |
| A6 | Least privilege; no secrets in Git, images, bundle, logs | **Met** | [Least-privilege review](security/least-privilege-review.md) | Scoped Pod Identity roles; separate identity secret prefix; read-only Datadog role with external ID; per-service DB roles and Kafka ACLs; CI read-only by default. gitleaks (history and bundle) pass; Trivy secret scan: 0 in all 5 images; logs and Datadog redacted | Operator uses a long-lived admin key; provisioner can assign any realm role; old dev password in history (never used) |
| A7 | Encryption, backups, demonstrated restore | **Met** | [Restore drill](evidence/restore-drill-20261030-1148.md); [data.tf](../infra/cluster/data.tf) | RDS, Valkey, EBS, Secrets and state encrypted; TLS in transit; 7-day PITR on both databases. Drill: data identical, **RTO 12 min**, **RPO 369 s** | RPO missed the initial 5-min target (revised to 10 min with rationale); single-AZ; backups do not survive `down` (by design for the sandbox) |
| A8 | CI tests and scans pass; images traceable | **Met** | [ci.yml](../.github/workflows/ci.yml); [supply-chain.md](security/supply-chain.md) | Tests, gitleaks, Trivy (dependencies and images; fixable HIGH/CRITICAL gate), SPDX SBOM, keyless Cosign, SLSA provenance; deployment pins images by digest to a commit | Signatures not enforced at admission |
| A9 | Rollback and alert response exercised | **Met** | [Release and rollback](evidence/phase3-live-verification.md#release-and-rollback-a9); [alert exercise](evidence/phase5-observability.md#alerting-exercise-a9) | Release 27 s, rollback 17 s, 45 probes 0 errors. Authentication-failure alert fired about 90 s after the attack; Triggered and Recovered emails received with the runbook link | None |
| A10 | Useful dashboards, logs, alerts without secrets | **Met** | [Observability evidence](evidence/phase5-observability.md); [infra/datadog](../infra/datadog) | Datadog metrics, logs and traces; dashboard; 13 monitors with runbook links; 99.5% SLO with burn-rate alert; JWT arrived as `[REDACTED_JWT]` | Datadog's auto-created Kubernetes monitors also exist outside Terraform |
| A11 | FinanceAgent secured or disabled | **Met (disabled)** | [workloads.yaml](../deploy/banking/workloads.yaml) (`replicas: 0`); [agent tests](../finance-agent/tests) | Disabled: no approved model provider. Its controls are still implemented and tested (token-bound tools, re-checked by the transaction service, minimal data to the model) | Banking MCP not implemented |
| A12 | Another engineer can deploy, operate and tear down | **Met** | [infra/README.md](../infra/README.md); [runbook](runbook.md) | Prerequisites, one-time bootstrap, `up.sh`/`down.sh`, access, releases, rollback, restore, rotation, alerts and teardown documented. Every secret is generated or provided by the engineer's own accounts (AWS, DuckDNS, Datadog) | Needs a peer walk-through to confirm |

## Deliverables

| # | Deliverable | Where |
|---|---|---|
| 1 | Deployed environment with a stable URL and synthetic demo accounts | `https://techbleatglobalbank.duckdns.org`, rebuilt with `up.sh`. Demo users `alice` and `bob` are seeded; their generated passwords are in Secrets Manager (`techbleat/demo-users`) |
| 2 | Environment architecture diagram and threat model | [environment-architecture.md](environment-architecture.md) ([SVG](environment-architecture.svg)); [threat-model.md](threat-model.md) |
| 3 | Infrastructure and deployment config, no secrets or state | [infra/](../infra), [deploy/](../deploy), [scripts/](../scripts). State is in S3; tfvars are git-ignored |
| 4 | CI/CD evidence | GitHub Actions runs on `main`; GitOps reconciliation and self-heal in [platform evidence](evidence/phase3-live-verification.md#gitops-change-control) |
| 5 | Security evidence | Auth tests (A4/A5), [exposure review](evidence/phase3-live-verification.md#edge-tls-and-exposure-a1-a2), scan summaries and SBOM (CI artifacts; [supply-chain.md](security/supply-chain.md)), [least-privilege review](security/least-privilege-review.md) |
| 6 | Operations runbook | [runbook.md](runbook.md): deploy, rollback, backup/restore, rotation, alert responses, incident playbooks, teardown |
| 7 | Completion report | This document |
| 8 | Demonstration | Normal flow: sign in, deposit, transfer, activity feed. Negative test: forged token → `401`, logged as `authentication_failed` in Datadog with no token, alert raised |

## Deviations from the target architecture

Cloudflare is replaced by DuckDNS + NLB + Coraza WAF and a rate limit at the gateway. Kafka
runs in-cluster on Strimzi (hardened). Backstage and the Banking MCP are not implemented.
Data services are single-AZ, and the environment is ephemeral. Details and reasons are in
the [environment architecture](environment-architecture.md#deviations-from-the-target-architecture).

## Residual risks before real customer data

See the [threat model summary](threat-model.md#residual-risk-summary). In priority order:

1. Enable MFA and email verification.
2. Enforce image signatures at admission.
3. Narrow the provisioner's Keycloak permissions.
4. Replace the operator's long-lived key with SSO roles.
5. Move to Multi-AZ data services and replicated Kafka and Keycloak.
6. Restrict mesh egress.
7. Remove self-deposit.
8. Put a CDN/WAF edge in front.
