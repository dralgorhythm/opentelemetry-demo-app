# Deferred work

What we'd do next, deliberately not built for the assignment. Each item: why
it matters, and the first concrete step. Companion to
[DECISIONS.md](./DECISIONS.md) — these are the roads not yet taken, not the
forks already chosen.

## Edge & network

- **TLS + DNS at the edge.** The ALB is HTTP-only because certs need a domain
  decision first. First step: Route53 zone + ACM cert in the stack module,
  then the chart's existing `ingress.certificateARNs` knob (IngressClassParams
  carries it) plus an HTTPS listener with HTTP→HTTPS redirect.
- **Private EKS API endpoint.** Public today for laptop + hosted-runner
  convenience (`endpoint_public_access` in `terraform/modules/stack/eks.tf`).
  First step: pin `endpoint_public_access_cidrs` to known ranges; the full
  fix is a private endpoint + VPN/bastion, which also forces self-hosted or
  VPC-peered CI runners.
- **NetworkPolicies.** The chart ships a `networkpolicy.yaml` template,
  unused. First step: enable the policy controller (vpc-cni configuration)
  and set default-deny + explicit app→collector/app→DNS allows — then prove
  enforcement with a blocked request, since an unenforced policy reads
  identically to an enforced one.
- **Edge abuse controls.** Anonymous `GET /` performs a Redis write with no
  WAF, rate limit, or CDN in front — an unauthenticated cost/abuse surface.
  Accepted for the demo: the blast radius is one $9/mo cache node. First
  step: an AWS WAF rate-based rule associated with the ALB
  (`aws_wafv2_web_acl` + association), or CloudFront in front of it.
- **IngressClass ownership.** The chart renders the cluster-scoped
  `IngressClass`/`IngressClassParams` pair inside each release, so a second
  ingress-enabled service would hit a Helm cross-release ownership conflict
  on the shared objects. First step: per-service unique `className`s in
  values, or move the pair to `deploy/cluster/` where cluster-scoped things
  live — not moved now because a live move orphans and recreates the ALB.

## Multi-environment

- ~~**Promotion to staging/prod.**~~ Landed: `promote.yml` deploys the same
  immutable image SHA dev smoked, to any environment with a
  `terraform/envs/<env>` root. The remaining work is *operational*, not
  code — the bootstrap re-apply and the protected GitHub Environments are
  manual by design (see `docs/bootstrap.md` § Adding an environment).
- **A build stamp (`EXPECT_SHA`).** `promote.yml` can prove the target
  environment is healthy but not that the *promoted SHA* is the one serving
  — the app self-reports no build, so `helm --wait --atomic` is the only
  thing backing that claim. First step: a build-arg SHA surfaced in the
  greeting or a `/version` route, then `EXPECT_SHA=$SHA scripts/smoke.sh
  cloud` in both deploy gates. Tracked with `service.version`.
- **Prod posture.** `terraform/envs/prod` is configuration-identical to
  staging today. The prod-specific upgrades (per-AZ NAT via
  `single_nat_gateway = false`, tighter alarm thresholds, ACM certs +
  HTTPS, Redis HA) are each one line in that root when a real audience
  arrives — promoting to prod now gets you a *staging-grade* prod.
- **PR preview environments.** Ephemeral `pr-*` namespaces with their own
  bounded OIDC role. First step: a preview role in bootstrap plus a
  PR-triggered deploy/teardown pair keyed on the PR number.

## Data & secrets

- **Redis HA.** One variable: `redis_num_cache_clusters > 1` flips automatic
  failover + multi-AZ together. Dev runs 1 node for cost.
- **AUTH-token rotation.** The token lives in Terraform state (accepted,
  documented trade). First step: a Secrets Manager rotation Lambda owning the
  token, with Terraform ignoring the secret value — rotation stops being
  `terraform apply -replace=random_password.redis_auth` and the token leaves
  state entirely.
- **AUTH-token rotation drill.** No layer owns "config changed → pods
  restart" — nothing watches the CSI-mounted secret, so a rotation that
  stops at `terraform apply` leaves pods on the old token. The drill:
  `terraform apply -replace=random_password.redis_auth`, then
  `kubectl rollout restart deploy/app -n otel-demo`. Note
  `auth_token_update_strategy = ROTATE` keeps the old token valid until a
  later apply flips the strategy to `SET` — rotation isn't complete until
  then. First step: write this runbook down (`docs/runbook.md`) and name it
  the owner of the restart, then exercise it once.
- **TLS-protocol drift (rustls features).** The first live incident's most
  expensive lesson: a dependency's default-features drift silently compiled
  rustls down to TLS 1.3-only while ElastiCache negotiates only TLS 1.2 —
  every gate stayed green while every connection failed (`Cargo.toml`
  carries the pinned `tls12` feature and the full story). First step: an
  integration smoke in CI against a TLS-enabled Redis so protocol drift
  fails a gate, and tracking ElastiCache TLS 1.3 support so the pin can
  eventually retire.
- **Valkey.** ~20% cheaper, drop-in for this INCRBY workload; kept Redis
  because the prompt named it. First step: `engine = "valkey"` + engine
  version in the replication group.

## Supply chain & encryption

- **Image signing + provenance.** First step: cosign keyless signing in the
  deploy job after push, then an admission check; SLSA provenance via the
  build-push action's attestation support.
- **Image scanning as a gate.** ECR scan-on-push is on and Trivy scans the
  *filesystem* in CI; the built image itself isn't gated. First step: a Trivy
  `image` scan step between build and push.
- **KMS CMKs.** State bucket, log groups, ElastiCache at-rest, and Secrets
  Manager ride AWS-managed keys. First step: one project CMK + key policy in
  bootstrap, threaded through as a variable.
- **cargo-deny.** `cargo audit` gates vulnerabilities but not licenses or
  duplicate/yanked crates. First step: `deny.toml` + a CI step.

## Scale & cost

- **Spot capacity.** A custom Auto Mode NodePool (weight over
  `general-purpose`) cuts node cost ~70%; the 2-replica + PDB + spread floor
  already absorbs reclaims. First step: `deploy/cluster/spot-nodepool.yaml`
  with amd64-pinned C/M/R instance requirements.
- **HPA + load testing.** The chart has an `hpa.yaml` template; resource
  requests are folklore until measured. First step: a k6/vegeta run against
  the ALB to find the loaded steady-state, then set requests and enable the
  HPA at 70% CPU (metrics-server is already installed).

## Observability

- **JSON log formatter.** Honest gap: the saved Logs Insights queries and the
  dashboard's p95 row (`terraform/modules/stack/alerting.tf`) parse
  `log_processed.fields.*`, but the app emits human-readable text logs today
  — those queries return empty until the app switches to
  `tracing_subscriber`'s JSON formatter and logs a structured
  "HTTP request completed" event with `latency_ms`/`status_code`. The infra
  side is deliberately already correct.
- **Trace context + version stamping.** No W3C propagator is registered
  (inbound traceparent headers start new traces) and the app doesn't report
  `service.version`, so the smoke gate can't assert "this SHA is serving."
  First step: set the propagator and stamp `service.version` from build env
  in `setup_tracing()`, add the version to `/healthz`, then an `EXPECT_SHA`
  check in `scripts/smoke.sh`.

## Operations

- **Runbook.** The durable rollback is a **revert PR** (every merge to main
  re-asserts itself); `helm rollback app <rev> -n otel-demo` is the stopgap,
  and the deploy job prints the revision table in its run summary for exactly
  that. First step: write the rollback, Redis-outage, and
  ALB-not-provisioning drills down as `docs/runbook.md` with the commands
  already scattered through workflow comments.
