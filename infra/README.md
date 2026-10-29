# AWS environment: build, operate, tear down

The deployed environment is **ephemeral**: you create it at the start of a working
session and destroy it at the end, so you pay only for the hours it runs
(roughly $0.50/hour). Everything is defined in this repository. Nothing needs to be
created by hand, and no secret lives in Git.

| Piece | Lifetime | Defined in |
|---|---|---|
| Terraform state bucket, budget alert, TLS certificate backup | Permanent (pennies per month) | [`bootstrap/`](./bootstrap) |
| VPC, EKS, RDS PostgreSQL, ElastiCache Valkey, IAM roles, Secrets Manager entries | Per session | [`cluster/`](./cluster) |
| Everything inside the cluster | Per session, reconciled by Argo CD from `main` | [`../deploy/`](../deploy) |

## Prerequisites

- AWS credentials for the target account in `~/.aws` (region `eu-west-2`)
- Terraform **64-bit** ≥ 1.10, kubectl, Helm, Python 3, curl, and Git Bash on Windows
- `DUCKDNS_TOKEN` environment variable set to the DuckDNS account token. Never put
  it in a file in this repository. On Windows:
  `[Environment]::SetEnvironmentVariable("DUCKDNS_TOKEN", "<token>", "User")`, then
  restart the terminal or VS Code.

## One-time bootstrap

```sh
cp infra/bootstrap/terraform.tfvars.example infra/bootstrap/terraform.tfvars   # set alert_email
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap plan -out=bootstrap.tfplan
terraform -chdir=infra/bootstrap apply bootstrap.tfplan
```

The bootstrap state is local to the operator's machine and git-ignored. Keep it safe.

## Each session

```sh
bash scripts/up.sh       # ~30-40 min; shows the Terraform plan and asks first
...
bash scripts/down.sh     # ~15 min; asks first, then proves nothing billable is left
```

`up.sh` does the following:
1. Applies `infra/cluster`. The Kubernetes API accepts only your current public IP.
2. Installs Argo CD.
3. Restores the TLS certificate saved by the previous `down.sh`.
4. Hands over to Git.
5. Points `techbleatglobalbank.duckdns.org` at the load balancer.
6. Waits for every application to be healthy.
7. Applies the Keycloak realm configuration through a port-forward.

`down.sh` does the following:
1. Saves a production certificate.
2. Stops Argo CD.
3. Removes load balancers and volumes that Kubernetes created, which Terraform does not track.
4. Destroys the stack and sweeps for orphaned disks.
5. **Clears the DuckDNS record**, so a recycled AWS IP can't take over the domain.
6. Runs [`scripts/check-leftovers.sh`](../scripts/check-leftovers.sh).

You can run that check at any time.

## Access

| What | How |
|---|---|
| Banking app | https://techbleatglobalbank.duckdns.org |
| Keycloak login pages | https://auth.techbleatglobalbank.duckdns.org/realms/banking/... (nothing else is routed publicly) |
| Keycloak admin console | `kubectl port-forward -n keycloak svc/keycloak 18080:8080`, then http://localhost:18080. Credentials are in Secrets Manager under `techbleat/cluster/keycloak/admin`. |
| Argo CD | `kubectl port-forward -n argocd svc/argocd-server 8443:443`, then https://localhost:8443. The password is in the `argocd-initial-admin-secret` Secret. |
| kubectl | `export KUBECONFIG=infra/.kubeconfig` (written by `up.sh`) |

Every `up.sh` seeds two demo customers, `alice` and `bob`, with synthetic data. They are
registered through the public API, given `banking-customer` and `banking-transact`, and
issued new random passwords each session. The passwords are stored in Secrets Manager,
outside the cluster's readable prefix:

```sh
aws secretsmanager get-secret-value --region eu-west-2 --secret-id techbleat/demo-users   --query SecretString --output text
```

The data is deleted with the database at `down.sh`. Other users register in the app; an
administrator then assigns roles in the Keycloak admin console.

## TLS certificate: staging, then production

Let's Encrypt allows only **5 identical certificates per week**, so:

1. Test with `letsencrypt-staging`, which is the default in
   [`deploy/platform/policy/gateway.yaml`](../deploy/platform/policy/gateway.yaml).
   Browsers warn that the certificate is untrusted, which is expected.
2. For the demo, change the Certificate's `issuerRef.name` to `letsencrypt-production`
   and push. `down.sh` then saves the certificate to Secrets Manager, and `up.sh`
   restores it, so later sessions reuse it instead of requesting a new one.

## Releases and rollback

CI publishes signed images tagged `sha-<commit>` for every push to `main`.
To deploy a commit's images:

```sh
bash scripts/pin-images.sh <full-commit-sha>   # rewrites digests in deploy/banking/workloads.yaml
git commit -am "Release <short-sha>" && git push
```

Argo CD rolls the change out. **To roll back**, run `pin-images.sh` with the last
known-good commit and push again. Every image change is a reviewed commit, and
Argo CD reverts manual edits made in the cluster (`selfHeal`).

## Costs and safety nets

- A budget email goes to the configured address at 50%, 80% and 100% of
  $20/month, and when the forecast exceeds it.
- If a session is interrupted, rerun `bash scripts/down.sh`. It works from the
  Terraform state even when the cluster is unreachable, then checks for leftovers.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Unrecognized remote plugin message` | 32-bit Terraform. Install the amd64 build. The scripts check for this. |
| `terraform` not found after installing | The terminal or VS Code started before the install. Restart VS Code completely. |
| `up.sh` waits on the load balancer | `kubectl get applications -n argocd`; check the `aws-load-balancer-controller` and `platform-policy` apps. |
| Certificate stays not ready | DNS must point at the load balancer first: `nslookup techbleatglobalbank.duckdns.org`. Then run `kubectl describe certificate -n istio-ingress bank-tls`. |
| Kubernetes API unreachable | Your public IP changed since `up.sh`. Rerun `up.sh` to update the allow-list. |

## Design notes and limitations

- **No Cloudflare.** DuckDNS subdomains cannot be delegated to Cloudflare. The edge is
  an AWS Network Load Balancer (AWS Shield Standard), with the Coraza WAF (OWASP CRS)
  and a rate limit at the Istio gateway.
- **Single NAT gateway, single-node Kafka, single-AZ RDS and Valkey.** These are
  sandbox cost choices, not production settings.
- **EKS 1.36** because Istio 1.30, the newest Istio with published Helm charts,
  supports Kubernetes up to 1.36.
- **Pods cannot reach EC2 instance metadata** (IMDSv2 with hop limit 1). Controllers
  use EKS Pod Identity instead, each bound to one service account.
