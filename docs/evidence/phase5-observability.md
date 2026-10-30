# Phase 5 observability verification (Datadog)

Recorded 2026-10-30 against the live AWS environment. Datadog site: EU1 (`datadoghq.eu`).
Configuration as code: [`deploy/apps/60-datadog.yaml`](../../deploy/apps/60-datadog.yaml),
[`deploy/observability/`](../../deploy/observability), [`infra/datadog/`](../../infra/datadog).

## Collection

| Signal | Source | Verified |
|---|---|---|
| Infrastructure and container metrics | Datadog Agent (DaemonSet on each node) and Cluster Agent | Per-workload memory and CPU series for banking deployments |
| Service metrics | Istio integration, auto-discovered on every Envoy proxy | Gateway requests by response code |
| Logs | All container logs | Application `security.audit` events searchable |
| Traces | Istio's Datadog tracer in every proxy (mesh-wide `Telemetry`) | Spans from `public-istio`, `frontend`, `transaction-service`, `user-service` in one trace path |
| AWS managed services | Read-only AWS integration role (external ID); RDS, ElastiCache, ECS, NLB namespaces only | Integration active |
| Agent authentication | API key from Secrets Manager via External Secrets | `API Key valid` |

## No secrets in telemetry (A10)

Agent-side processing rules mask bearer tokens, JWTs and JSON `password`/`secret` fields
before logs leave the cluster.

| Test | Result |
|---|---|
| Request with a JWT in its URL (`?access_token=eyJ…`), recorded in the gateway access log | Stored in Datadog as `access_token=[REDACTED_JWT]`; raw token absent |
| 30 requests with a forged bearer token | 30 × `401`; Datadog has `authentication_failed` events with reason and client IP (`92.30.207.63`, preserved by the NLB); forged token absent |

## Alerting exercise (A9)

| Step | Time (UTC) | Result |
|---|---|---|
| 30 forged-token requests to the transaction API | 12:48:45–12:49:03 | 30 × `401` |
| Monitor `[techbleat] Spike in authentication failures` | about 90 s later | State `Alert`; notification emailed to the operator with a runbook link ([authentication-failures](../runbook.md#authentication-failures)) |

## Monitors (Terraform, `infra/datadog/monitors.tf`)

Error rate above 5%, average latency above 1 s, crash-looping containers, container memory near its
limit, node CPU, authentication failures, authorization denials, Kafka broker readiness,
RDS CPU and free storage, Valkey CPU, and Keycloak running on ECS. Each links to its
runbook section. None alert on missing data, so the routine teardown is silent.

## SLO

`[techbleat] Public availability`: 99.5% of public requests through the gateway do not
return 5xx, over 7 and 30 days, with a multi-window burn-rate alert (14.4× over 1 h,
confirmed over 5 min).

## Finding: cumulative metric used for rates (fixed)

The first deployment showed a constant `500` series (`destination_service_name:unknown`,
value 8 every interval) although the gateway logs had no 5xx for 90 minutes. Cause:
`istio.mesh.request.count` is a **cumulative gauge**. It re-reported 8 errors from earlier
that day (the pre-ServiceEntry Keycloak `cluster_not_found` responses). Rates must use
the per-interval `istio.mesh.request.count.total`. The availability monitor, latency
monitor, SLO and dashboard were corrected. Afterwards the 30-minute totals matched the test
traffic exactly: 30 × `401`, 0 × `500`.
