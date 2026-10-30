# Phase 3 live verification

Results recorded against the deployed AWS environment (EKS 1.36, eu-west-2) on
2026-10-29 and 2026-10-30. Commands are reproducible with `scripts/up.sh` and the
checks below. Public domain: `techbleatglobalbank.duckdns.org`.

## Edge, TLS and exposure (A1, A2)

| Check | Result |
|---|---|
| `http://techbleatglobalbank.duckdns.org/` | `301` → `https://…` |
| Certificate | Let's Encrypt production (`YE2`), SANs `techbleatglobalbank.duckdns.org`, `auth.techbleatglobalbank.duckdns.org`, valid to 2027-01-27; verified by curl without `-k` |
| Certificate reuse | `down.sh` saved it to Secrets Manager; the next `up.sh` restored it (no new issuance) |
| External port scan of the NLB (nmap top 1000 TCP + all service ports) | **Only 80 and 443 open.** 5432, 6379, 8000–8443, 9000–9443, 10250, 15000–15090 and 22 filtered |
| RDS (banking and identity) | `PubliclyAccessible = False`; endpoints do not resolve from the internet |
| ElastiCache Valkey | Endpoint does not resolve from the internet |
| Keycloak (ECS task) | Private IP only (`assign_public_ip = false`) |
| EKS API | Public endpoint allows only the operator IP `/32`; private endpoint for the VPC |
| Keycloak admin console / master realm from the internet | `404` (not routed) |
| WAF (Coraza + OWASP CRS) | SQL injection and XSS probes → `403` |
| Security headers | CSP (`script-src 'self'`, `frame-ancestors 'none'`), `X-Frame-Options: DENY`, `nosniff`, `no-referrer` |

## API authentication through the public edge (A4)

| Request | Result |
|---|---|
| `GET /user-api/users/me`, `/transaction-api/balance/alice`, `/activity-api/activities/alice` without a token | `401` |
| Transaction API with an unsigned (`alg: none`) token | `401` |
| Old customer directory `GET /user-api/users` | `405` |

Automated suites cover expired, wrong-issuer, wrong-audience, wrong-key, missing-role and
cross-account cases (75 tests; see the CI runs).

## Service mesh (Istio 1.30.7)

| Check | Result |
|---|---|
| Mesh policy | `PeerAuthentication` `STRICT` (mesh-wide) |
| Sidecars | Every banking workload runs `istio-proxy` (native sidecar) |
| Live request | `/users/me` reached user-service over mTLS (`requested_server_name: outbound_.8000_._.user-service…`) |
| Plain HTTP from a pod **without** a sidecar (NetworkPolicy allowed it) | **Connection reset**: STRICT mTLS refuses it |
| Identity- and path-based authorization (when Keycloak ran in the mesh) | transaction-service → JWKS `200`; → user-admin API `403` |
| Exceptions | Kafka (own mTLS + ACLs, no sidecar); `db-init` Job (isolated namespace, DNS + PostgreSQL egress only) |

## Identity platform outside the cluster (target architecture)

| Check | Result |
|---|---|
| Keycloak pods in EKS | `0`; runs as 1 ECS Fargate task (`RUNNING`, `HEALTHY`) |
| Identity database | Dedicated RDS instance; security group admits only Keycloak's security group |
| Identity secrets | `techbleat/identity/*`, readable only by Keycloak's task execution role (not by EKS) |
| Gateway → Keycloak | TLS, SNI `keycloak.identity.internal`, trusts only the identity CA, SAN must equal `keycloak.identity.internal` (Envoy config dump) |
| user-service → Keycloak | TLS verified with the identity CA; demo users provisioned through it |
| Public discovery | `200`, issuer `https://auth.techbleatglobalbank.duckdns.org/realms/banking` |
| Operator admin access | SSM port forwarding to the task (CloudTrail-audited), no inbound path |

## GitOps change control

| Step | Time (UTC) | Result |
|---|---|---|
| Deleted `AuthorizationPolicy/deny-by-default` and scaled `frontend` to 5 with kubectl | 11:28:27 | Unreviewed change made in the cluster |
| Argo CD automated self-heal | 11:28:30 | Policy recreated, replicas back to 2: **restored in 7 s** |

## Release and rollback (A9)

| Step | Commit | Live after | Result |
|---|---|---|---|
| Release images of `3a0fa61` (`pin-images.sh`) | `041dfa9` | 27 s | New page title served |
| **Roll back** to known-good images of `9bde8aa` | `4f507aa` | 17 s | Previous title served |
| Availability probe (1 request/s) across both | | | **45 requests, 0 non-200** |

Both changes are reviewed Git commits pinning signed, scanned images by digest.

## End-to-end customer flow

Demo customers `alice` and `bob` (synthetic, seeded by `up.sh`) signed in through
Keycloak, deposited and transferred funds; the recipient's balance and Kafka-driven
activity feed updated. Verified in Chrome on both days, including after Keycloak moved
to ECS.

## Defects found only by live testing (all fixed and committed)

1. AWS Load Balancer Controller webhook certificate drift under Argo CD (now issued by cert-manager).
2. Argo CD false `OutOfSync` on CRDs (server-side diff; ignore runtime-injected CA bundles).
3. Coraza WasmPlugin pinned by OCI digest instead of module checksum (fail-closed deny-all).
4. Gateway OOM with the OWASP rule set (per-gateway memory override).
5. Argo CD project rejected an application with no destination namespace.
6. EKS node security group lacked Istio's webhook port 15017 (pod creation timed out).
7. A manifest named `secrets.yaml` was git-ignored (renamed `external-secrets.yaml`).
8. Frontend proxy sent the public Host header, bypassing mesh routing and mTLS.
9. Per-hostname HTTPS listeners broke HTTP/2 connection coalescing in browsers.
10. ExternalName alias to the external Keycloak needed a ServiceEntry.
11. Windows tooling: 32-bit Terraform, antivirus quarantining a provider, Schannel revocation checks, stale Helm repos.
