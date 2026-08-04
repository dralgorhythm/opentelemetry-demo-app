# Demo cheat sheet

Copy-pasteable commands for exercising and analyzing the live system, in
demo order. Concrete names throughout: cluster `otel-demo-app-dev`,
namespace `otel-demo`, release `app`, account `928338452041`, region
`us-east-1`.

Time-window flags below use the macOS `date -v-10M` form; on Linux
substitute `date -d '10 minutes ago' +%s` (as `scripts/smoke.sh` does).

## 0. One-time setup per terminal

```bash
export AWS_REGION=us-east-1
export CLUSTER=otel-demo-app-dev
aws sts get-caller-identity                     # confirm account 928338452041
aws eks update-kubeconfig --name $CLUSTER --region $AWS_REGION

# The serving hostname — everything else uses $HOST
export HOST=$(kubectl -n otel-demo get ingress app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$HOST"
```

## 1. Exercise the app (curl)

```bash
curl -s http://$HOST/healthz                    # "ok" — dependency-free liveness
curl -s http://$HOST/                           # "Hello, World! You are visitor number N" — full Redis round trip
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://$HOST/

# Prove ElastiCache TLS+AUTH end to end: counter must be strictly increasing
curl -s http://$HOST/; echo; curl -s http://$HOST/

# Generate trace/load volume for the observability demo
for i in $(seq 1 50); do curl -s -o /dev/null http://$HOST/; done

# Or just run the CI deploy gate — five checks: healthz + greeting through the
# ALB + counter monotonicity (ElastiCache TLS+AUTH) + this run's own marker
# trace indexed in X-Ray within ~90s (app→ADOT→X-Ray) + the served-build
# assert when EXPECT_SHA is set
scripts/smoke.sh cloud
```

## 2. Kubernetes (the workload)

```bash
kubectl -n otel-demo get deploy,pods,svc,ingress,pdb,networkpolicy -o wide
kubectl -n otel-demo logs deploy/app -f                      # JSON tracing logs; Redis errors surface here with causes
kubectl -n otel-demo logs deploy/app | grep -i redis         # preflight + pool error-sink lines
kubectl -n otel-demo describe pod -l app.kubernetes.io/name=app
kubectl -n otel-demo exec deploy/app -- cat /mnt/secrets-store/config.yml   # ⚠ prints the rediss:// AUTH token — CSI mount proof
kubectl -n otel-demo get events --sort-by=.lastTimestamp | tail -20
kubectl -n otel-demo rollout history deploy/app
kubectl -n otel-demo rollout restart deploy/app && kubectl -n otel-demo rollout status deploy/app

# The ADOT collector (lives in default, not otel-demo)
kubectl get deploy,svc -l app=otel-collector
kubectl logs deploy/otel-collector -f                        # exporter errors / X-Ray puts show here
kubectl get nodes -o wide                                    # EKS Auto Mode nodes (amd64 pin matters)
kubectl get pods -A                                          # add-ons: CSI driver, CloudWatch agent, etc.
```

## 3. Helm (how it's deployed)

```bash
helm -n otel-demo list
helm -n otel-demo history app
helm -n otel-demo get values app                # shows the service+env values + CI --set image bits
helm template app charts/app -f deploy/services/app.yaml -f deploy/envs/dev.yaml   # render locally
scripts/roster.sh                               # the roster's one parser (service list)
```

## 4. AWS CLI — the infrastructure

EKS / ALB:

```bash
aws eks describe-cluster --name $CLUSTER --query 'cluster.{status:status,version:version,endpoint:endpoint}'
aws eks list-pod-identity-associations --cluster-name $CLUSTER    # app + collector identities, no IRSA
aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(DNSName, `k8s`)].{dns:DNSName,state:State.Code}'
aws elbv2 describe-target-health --target-group-arn $(aws elbv2 describe-target-groups --query 'TargetGroups[0].TargetGroupArn' --output text)
```

ElastiCache Redis:

```bash
aws elasticache describe-replication-groups --replication-group-id ${CLUSTER}-redis \
  --query 'ReplicationGroups[0].{status:Status,tls:TransitEncryptionEnabled,auth:AuthTokenEnabled,endpoint:NodeGroups[0].PrimaryEndpoint}'
```

Secrets Manager (the whole config.yml as one secret):

```bash
aws secretsmanager describe-secret --secret-id ${CLUSTER}/app/config
aws secretsmanager get-secret-value --secret-id ${CLUSTER}/app/config --query SecretString --output text  # ⚠ prints AUTH token
```

ECR (shared, immutable tags):

```bash
aws ecr describe-images --repository-name otel-demo-app/app \
  --query 'sort_by(imageDetails,&imagePushedAt)[-5:].{tag:imageTags[0],pushed:imagePushedAt}' --output table
```

## 5. Observability (the "analyze" half)

X-Ray traces:

```bash
aws xray get-trace-summaries --start-time $(date -v-10M +%s) --end-time $(date +%s) \
  --query 'TraceSummaries[].{id:Id,ms:Duration,url:Http.HttpURL,status:Http.HttpStatus}' --output table
# Then fetch one full trace (shows the INCRBY visit_counter Redis subsegment):
aws xray batch-get-traces --trace-ids <id> --query 'Traces[0].Segments[].Document' --output text | python3 -m json.tool
```

CloudWatch logs (Container Insights groups):

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/$CLUSTER --query 'logGroups[].logGroupName'
aws logs tail /aws/containerinsights/$CLUSTER/application --follow --filter-pattern '"otel-demo"'
aws logs tail /aws/containerinsights/$CLUSTER/application --since 15m --filter-pattern ERROR
```

Logs Insights — saved queries exist in the console:
`otel-demo-app-dev/p95-by-service`, `otel-demo-app-dev/errors-recent`,
`otel-demo-app-dev/volume-by-service`; ad hoc:

```bash
qid=$(aws logs start-query --log-group-name /aws/containerinsights/$CLUSTER/application \
  --start-time $(date -v-1H +%s) --end-time $(date +%s) \
  --query-string 'filter kubernetes.namespace_name="otel-demo" | fields @timestamp, log | sort @timestamp desc | limit 20' \
  --query queryId --output text)
sleep 3 && aws logs get-query-results --query-id $qid
```

Dashboard + alarms:

```bash
aws cloudwatch get-dashboard --dashboard-name ${CLUSTER}-alb --query DashboardBody --output text | python3 -m json.tool | head -40
aws cloudwatch describe-alarms --alarm-name-prefix ${CLUSTER}-alb --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' --output table
# Demo an alarm firing without breaking anything:
aws cloudwatch set-alarm-state --alarm-name ${CLUSTER}-alb-target-5xx --state-value ALARM --state-reason "demo"
```

Console shortcuts: X-Ray trace map, CloudWatch dashboard
`otel-demo-app-dev-alb`, both in us-east-1.

## 6. CI/CD (GitHub Actions owns all applies)

```bash
gh repo set-default dralgorhythm/opentelemetry-demo-app   # fork gotcha: gh otherwise targets upstream
gh run list --workflow ci.yml --limit 5
gh run watch                                              # live-follow the current run
gh workflow run ci.yml                                    # full pipeline: gates → infra → deploy → smoke

# Promotion (gated envs — never dev): version empty = this ref's HEAD,
# or a vX.Y.Z tag, or a full 40-char SHA
gh workflow run promote.yml -f environment=staging -f version=v1.2.3
gh workflow run promote.yml -f environment=staging      # promote HEAD
# The resolve job posts the service→digest manifest to the run summary
# BEFORE the approval prompt — approve a specific artifact, not a hope

# Teardown is Actions → destroy (type "destroy") — Helm uninstall waits for the ALB before terraform destroy
```

## 7. Terraform (read-only demo — CI applies, don't apply locally)

```bash
cd terraform/envs/dev
terraform init && terraform plan                          # should be a clean no-op ⇒ no drift
terraform output                                          # cluster_name, redis primary endpoint, secret ARN
terraform state list | head -30
```

## 8. Local development (no AWS needed)

```bash
docker compose up -d                # Redis + Jaeger (UI: http://localhost:16686)
cargo run -- -f config.yml          # serves http://127.0.0.1:8080
curl -s http://127.0.0.1:8080/      # then look at the trace in Jaeger
cargo fmt --all --check && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked   # the CI gates, locally
docker build --platform linux/amd64 .                     # the musl-static chainguard image
```

## 9. Good failure-mode demos

- **Redis blip is honest, not fatal:** `/healthz` stays 200 while `/`
  returns 500 with the real cause in pod logs — deliberately decoupled so a
  Redis outage never evicts pods. The wiring: `src/routes.rs` (bb8 error
  sink + preflight) and `src/handlers.rs` (dependency-free healthz).
- **PDB in action:** `kubectl drain <node> --ignore-daemonsets
  --delete-emptydir-data` respects `maxUnavailable: 1` (drain is
  cluster-scoped, not namespaced; get node names via `kubectl get nodes`).
- **Secret rotation model:** rotate the Secrets Manager value, then
  `rollout restart` — config is read once at boot, so restart *is* the
  rotation mechanism.
