# Bootstrap — the one local `terraform apply`

**Policy: CI owns every apply after this one.** Terraform runs locally
exactly once — the bootstrap stack (`terraform/bootstrap/`), which contains
nothing but the CI identity (GitHub OIDC provider + roles + permissions
boundaries) and the account cost guardrails. A stack that manages the
credential CI runs on can never be safely destroyed *by* CI, so it gets its
own state key and a local-only lifecycle.

What it mints:

| Role | Trust (`sub` claim) | Power |
|---|---|---|
| `otel-demo-app-dev-ci` | `environment:dev` (+ main ref) | AdministratorAccess **inside** the `otel-demo-app-dev-boundary` permissions boundary |
| `otel-demo-app-ci-plan` | any ref/PR of this repo | ReadOnlyAccess |
| `otel-demo-app-ci-shared` | main ref / `environment:dev` | ECR admin on `otel-demo-app/*` + rw on its own state key only |

State layout (one bucket, sibling keys): `otel-demo-app/bootstrap.tfstate`
(this stack), `otel-demo-app/shared.tfstate` (ECR stack),
`otel-demo-app/envs/dev.tfstate` (and future
`otel-demo-app/envs/{staging,prod}.tfstate`).

## 0 · Prerequisites

- AWS credentials for the target account in your shell
  (`aws sts get-caller-identity` shows the right account). If you use
  `aws login`/SSO: `eval "$(aws configure export-credentials --format env)"`
  so Terraform can read them.
- `gh` CLI authenticated against `dralgorhythm/opentelemetry-demo-app`.
- Terraform >= 1.10.
- Region: `us-east-1` (the default everywhere below).

## 1 · State bucket

CI and your laptop must share state; the bucket is the one resource
Terraform can't manage for itself. Create (or verify) it:

```bash
BUCKET=<unique-name>-tfstate
aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Then wire the repo to it — the bucket name is committed as the placeholder
`TFSTATE-BUCKET-TODO`; **replace every occurrence** before `init`:

```bash
grep -rl TFSTATE-BUCKET-TODO . | xargs sed -i '' "s/TFSTATE-BUCKET-TODO/$BUCKET/g"
grep -r TFSTATE-BUCKET-TODO . && echo "STILL DIRTY" || echo "clean"
```

(Both occurrences — the backend block and the `state_bucket` variable
default in `terraform/bootstrap/versions.tf` — must stay identical: the
permission boundaries deny foreign-state access by bucket+key.)

Commit the replacement on your bootstrap branch.

## 2 · Apply the bootstrap stack

```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply \
  -var alert_email=<you@example.com>   # optional: creates the monthly budgets; omit to skip
```

Budget notes (only if you passed `alert_email`): account ceiling $50/mo,
per-env $25/mo, alerts at 50%/90% actual + 100% forecast. The per-env
budgets filter on the `Environment` cost-allocation tag — activate it once
(`aws ce update-cost-allocation-tags-status --cost-allocation-tags-status
TagKey=Environment,Status=Active`) and allow ~24h; until then they
harmlessly match $0.

## 3 · Tell CI the account and the roles

Workflows assume roles by repo variable; the bootstrap outputs are the
single source of truth:

```bash
cd terraform/bootstrap
gh variable set AWS_ACCOUNT_ID     --body "$(terraform output -raw account_id)"
gh variable set AWS_REGION         --body "$(terraform output -raw region)"
gh variable set CI_ROLE_ARN        --body "$(terraform output -raw ci_role_arn)"
gh variable set CI_PLAN_ROLE_ARN   --body "$(terraform output -raw ci_plan_role_arn)"
gh variable set CI_SHARED_ROLE_ARN --body "$(terraform output -raw ci_shared_role_arn)"
gh variable set ALERT_EMAIL        --body "<you@example.com>"   # optional; workload-stack alerting, separate wire from step 2's budget email
cd -
```

## 4 · Create the GitHub environment `dev`

The dev apply role trusts `environment:dev` — the sub only exists once the
GitHub Environment does:

```bash
gh api -X PUT "repos/dralgorhythm/opentelemetry-demo-app/environments/dev"
```

(Add reviewers/branch protection rules there later; role assumption then
inherits those gates for free.)

## 5 · What happens next

Nothing else runs locally. Later PRs bring the pipeline alive:

- CI plan/apply jobs (plan-on-PR via `otel-demo-app-ci-plan`, apply via the
  env roles) arrive in their own PR.
- The shared ECR stack (`otel-demo-app/*` repositories — single service
  `app` for now) applies **via CI** using `otel-demo-app-ci-shared` once its
  PR lands.
- Opting into staging/prod later: copy
  `terraform/bootstrap/environments.tfvars.example` to
  `environments.tfvars`, re-apply this stack locally, feed the new role
  ARNs to the matching GitHub Environments.

Re-applying this stack is always local, with your own credentials — never
from CI.
