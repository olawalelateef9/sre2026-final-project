# Student Project: Secure Deployment of Techbleat Global Bank

## Project objective

Design, deploy, secure, and operate the Techbleat Global Bank application in a
production-style environment. The deployment must preserve the application's
service boundaries while adding the security, delivery, and operational controls
shown in the [target architecture](./techbleat-target-architecture.png).

The objective is not simply to make the website reachable. Demonstrate that
only intended traffic can reach the application, users are authenticated and
authorized by the services that handle their requests, secrets and data are
protected, releases are traceable, and operators can detect and recover from
failures.

## Reference material and current state

- [Target architecture diagram](./techbleat-target-architecture.png)
- [Architecture design and implementation notes](./architecture.md)
- [Repository README and local run instructions](../README.md)

The repository currently provides a Docker Compose application with a React
frontend, FastAPI user and activity services, a Spring Boot transaction service,
FinanceAgent, Keycloak integration, PostgreSQL, Redis, and Kafka. The Cloudflare,
Kubernetes/Istio, Backstage, GitHub Actions/OCI registry/Argo CD, managed data
services, Datadog, and Banking MCP integrations shown in the target design are
proposed target capabilities, not existing production infrastructure. Clearly
identify what you implemented, what you reused, and what remains a documented
limitation.

## Project brief

Deploy the application to a student-approved cloud or training environment.
The deployment must provide a public customer entry point and keep internal
services, data stores, administration interfaces, and deployment controls
private. Prefer managed cloud services for persistent data and secrets where
available. If a target component is unavailable or outside the project budget,
provide a secure equivalent or document the limitation, its risk, and a
mitigation.

Do not use real customer data, production credentials, or unapproved paid
services. Obtain approval before creating public DNS records, opening firewall
rules, or incurring cloud costs.

## Required outcomes

### 1. Secure architecture and threat analysis

- Produce an environment-specific architecture diagram showing public and
  private boundaries, request and identity flows, service-to-service
  communication, data stores, secrets, and deployment/observability paths.
- Document the main threats and mitigations, including account takeover,
  broken object-level authorization, privilege escalation, exposed secrets,
  supply-chain compromise, data exfiltration, denial of service, and loss of
  availability.
- Document trust boundaries and data classifications. State which components
  handle credentials, access tokens, personal information, account data, and
  transaction data.
- Record residual risks and any target-architecture components not implemented.

### 2. Edge, ingress, and transport security

- Serve the customer application over HTTPS with a valid certificate and
  redirect HTTP to HTTPS.
- Route public application and identity-provider traffic through the approved
  edge and ingress path. Apply appropriate WAF and rate-limiting controls.
- Restrict origin access so public traffic cannot bypass the edge controls.
- Expose only required public endpoints. PostgreSQL, Redis, Kafka, internal
  APIs, cluster management, CI credentials, and observability administration
  must not be directly public.
- If Kubernetes/Istio is used, configure ingress routing, TLS policy, strict
  workload mTLS where supported, and explicit service-to-service authorization
  policies. Explain any exceptions.

### 3. Identity, authentication, and authorization

- Configure Keycloak OIDC for the deployed frontend URL using Authorization
  Code with PKCE. Redirect URIs and web origins must be limited to the actual
  deployed frontend; do not use broad wildcards in the final environment.
- Keep confidential client credentials server-side and deliver them through a
  secret manager or protected deployment secret mechanism.
- Validate access-token signature, issuer, audience, expiry, and required roles
  in every protected backend API, not only in the frontend.
- Enforce user identity and account ownership in backend operations. A caller
  must not be able to read or modify another customer's account by changing a
  user ID or request parameter.
- Enforce role checks server-side for customer access, transactions, and
  privileged operations. Frontend role gating is not an authorization control.
- Apply least privilege to service accounts, client roles, Kubernetes
  identities, CI/CD identities, and cloud IAM roles.
- Ensure password, signup, lockout, email verification, and recovery policies
  are appropriate for the deployment. Document development-only exceptions.

### 4. Data protection and recovery

- Use managed PostgreSQL, Redis, and Kafka where feasible, or document and
  implement equivalent hardening for self-managed services.
- Encrypt data in transit and at rest where supported. Restrict access by
  network policy and least-privilege identities.
- Configure automated backups for persistent banking data, define retention,
  and demonstrate a restore into a non-production environment.
- Define recovery objectives (RPO/RTO) appropriate to the exercise and report
  the measured restore result.
- Avoid logging passwords, client secrets, bearer tokens, sensitive request
  bodies, or unnecessary personal/financial data.

### 5. Secure build and deployment

- Provide an automated pipeline that runs relevant tests and security checks
  before publishing or deploying an image.
- Build versioned, reproducible container images. Pin images and dependencies
  appropriately; do not deploy mutable `latest` tags.
- Scan source dependencies and container images for known vulnerabilities and
  document how findings are triaged.
- Generate an SBOM for released images. Sign images or otherwise provide a
  verifiable provenance/approval trail.
- Deploy only reviewed configuration. If using GitOps/Argo CD, demonstrate
  reconciliation from reviewed Git state and prevent unreviewed production
  changes.
- Store deployment credentials in protected CI/CD secrets or an external secret
  manager. Never put credentials in Git, image layers, build logs, or
  Backstage templates.
- Demonstrate a rollback to a known-good release.

### 6. Runtime operations and observability

- Provide health/readiness checks and resource limits for deployed services.
- Collect service and infrastructure logs, metrics, and traces without exposing
  secrets or excessive sensitive data.
- Provide dashboards and alerts for availability, latency, errors, saturation,
  authentication failures, suspicious authorization failures, and important
  data-service health.
- Define at least one user-facing SLI/SLO and demonstrate alerting against a
  measurable threshold.
- Document incident response actions for a leaked credential, suspected
  unauthorized transaction, failed deployment, and data-service outage.

### 7. FinanceAgent and AI controls

- If FinanceAgent is deployed, validate tokens and authorization at its API
  boundary, not only in the UI.
- Restrict tools to approved operations and enforce read-only behavior unless
  separately approved and secured. The agent must not be able to initiate
  transfers or bypass banking authorization.
- Scope every tool call to the authenticated user; revalidate identity and
  ownership at the backend.
- Apply prompt-injection defenses, input/output handling, rate limits, and
  privacy controls. Redact sensitive information from model prompts and logs.
- Use approved model providers and credentials. Document retention, training,
  and data-handling settings. If the AI/MCP path is out of scope, disable it in
  the deployed environment and document why.

## Deliverables

1. **Deployed environment** with a stable URL and a short-lived evaluator/demo
   account that contains synthetic data only.
2. **Environment architecture diagram** and threat model, including trust
   boundaries and data flows.
3. **Infrastructure and deployment configuration** committed to the repository
   with no secrets or state files.
4. **CI/CD evidence** showing tests, security checks, image publication, and
   the deployment or GitOps reconciliation path.
5. **Security evidence**: authentication and authorization tests, network
   exposure review, dependency/image scan summaries, and an SBOM.
6. **Operations runbook** covering deployment, rollback, backup/restore,
   alert response, and credential rotation.
7. **Completion report** mapping each criterion below to evidence, results,
   known gaps, and residual risks.
8. **Demonstration** of a normal customer flow and at least one negative
   security test that is correctly denied and logged without leaking secrets.

## Completion criteria

The project is complete only when all mandatory criteria below are demonstrated
and evidence is included in the completion report.

| ID | Acceptance criterion | Required evidence |
|---|---|---|
| A1 | Customer application is reachable at the approved HTTPS URL with a valid certificate; HTTP redirects to HTTPS. | Browser/curl result and certificate details. |
| A2 | Only approved public routes are reachable; data stores, internal APIs, and administrative endpoints cannot be reached directly from the public internet. | Ingress/firewall configuration and external exposure test. |
| A3 | OIDC login and logout work with PKCE; redirect URI and origin allowlists contain only required deployed URLs. | Login demonstration and Keycloak client configuration with secrets redacted. |
| A4 | Missing, expired, invalid-signature, wrong-issuer, wrong-audience, and insufficient-role tokens are rejected by protected backend APIs. | Automated API tests and representative responses. |
| A5 | Cross-account access and unauthorized transaction attempts are denied server-side. | Tests attempting access to another synthetic user's data and write operations. |
| A6 | Service, CI/CD, and cloud identities use least privilege; secrets are not present in Git, images, browser bundles, or logs. | IAM/role review, secret scan, image/bundle inspection, and log review. |
| A7 | Persistent data is encrypted where supported, backups are configured, and a restore has been demonstrated. | Encryption/backup settings and restore record with measured RPO/RTO. |
| A8 | CI tests and security scans pass the agreed release thresholds; deployed images are versioned and traceable to source. | Pipeline run, scan results, image digest, SBOM, and provenance/signature evidence. |
| A9 | A deployment rollback and a documented operational alert response have been exercised. | Rollback record and alert/runbook exercise. |
| A10 | Dashboards, logs, and alerts provide useful service health signals without recording credentials, tokens, or unnecessary sensitive data. | Dashboard/alert view and sampled redacted log review. |
| A11 | FinanceAgent is either secured according to the AI controls above or disabled in the deployed environment. | Authorization/tool tests, or evidence it is disabled. |
| A12 | Documentation allows another engineer to deploy, configure, operate, and safely tear down the environment without access to undocumented secrets. | Reviewed setup, operations, and teardown instructions. |

Any failure of A1-A8 is a release blocker. A criterion may be marked not
applicable only with instructor approval and a written rationale; security
controls must not be silently waived.

## Suggested evaluation rubric

| Area | Weight |
|---|---:|
| Identity, API authorization, and security testing | 25% |
| Network, edge, ingress, and transport security | 20% |
| Data protection, backup, and recovery | 15% |
| CI/CD, supply-chain security, and GitOps/change control | 15% |
| Observability, reliability, and operations | 10% |
| Architecture quality and threat analysis | 10% |
| Demonstration and documentation quality | 5% |

Security failures that expose secrets, permit cross-account access, or expose
data services publicly must be corrected before the deployment can be accepted,
regardless of the aggregate score.

## Suggested implementation sequence

1. Inventory the application, identify security gaps, and produce the threat
   model and deployment diagram.
2. Secure identity and backend authorization; add negative tests before public
   deployment.
3. Establish network boundaries, HTTPS ingress, and protected data services.
4. Build the automated test/scan/image pipeline and controlled deployment path.
5. Add backups, observability, alerts, and operational runbooks.
6. Deploy with synthetic data, execute the acceptance tests, remediate findings,
   and present the evidence.
