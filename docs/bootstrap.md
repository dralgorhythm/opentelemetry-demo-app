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

Then wire the repo to it. The tree commits the **real** bucket name,
`latent-rustinterview-tfstate` — six occurrences: the five backend blocks
(`terraform/bootstrap/versions.tf`, `terraform/shared/versions.tf`,
`terraform/envs/{dev,staging,prod}/main.tf`) plus the `state_bucket`
variable default in `terraform/bootstrap/versions.tf`. On a fork or a new
account, **replace every occurrence** with your bucket before `init`:

```bash
OLD=latent-rustinterview-tfstate
grep -rl "$OLD" terraform | xargs sed -i '' "s/$OLD/$BUCKET/g"
grep -rn "$OLD" terraform && echo "STILL DIRTY" || echo "clean"
```

(The backend block and the `state_bucket` variable default in
`terraform/bootstrap/versions.tf` must stay identical: the permission
boundaries deny foreign-state access by bucket+key.)

Commit the replacement on your bootstrap branch.

## 2 · Apply the bootstrap stack

```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply \
  -var alert_email=<you@example.com>   # optional: creates the monthly budgets; omit to skip
```

Budget notes (only if you passed `alert_email`): account ceiling $200/mo
(the `monthly_budget_usd` variable), per-env default $150/mo (override
per env via `budget_usd` in the `environments` map), alerts at 50%/90%
actual + 100% forecast. The per-env
budgets filter on the `Environment` cost-allocation tag — activate it once
(`aws ce update-cost-allocation-tags-status --cost-allocation-tags-status
TagKey=Environment,Status=Active`) and allow ~24h; until then they
harmlessly match $0.

**Re-applies:** any later change under `terraform/bootstrap/` requires the
same local re-apply (`terraform -chdir=terraform/bootstrap apply`) — CI
never touches this stack.

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
gh variable set ADMIN_PRINCIPAL_ARN --body "<your-iam-principal-arn>"   # optional but recommended; see below
cd -
```

`ADMIN_PRINCIPAL_ARN` is your **human** principal's IAM ARN. The
creator-admin EKS access entry goes to the *applier* of the Terraform —
which is the CI role, not you — so leaving this empty means no human
access entry: your own `kubectl` will be Unauthorized. Identity Center
caveat: use the underlying role ARN **with its path**, e.g.
`arn:aws:iam::<acct>:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_...`
— **not** the `sts` assumed-role ARN — and note the suffix changes if the
permission set is ever reprovisioned. The infra job in
`.github/workflows/ci.yml` carries the same caveats as a comment where the
variable is consumed.

Fork gotcha: `gh variable set` may not honor `gh repo set-default <fork>`
(observed with gh 2.97.0 resolving to the fork parent) — pass an explicit
`-R <owner>/<repo>` on each command above.

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
- Opting into staging/prod (or any further environment): the runbook below.

Re-applying this stack is always local, with your own credentials — never
from CI.

## 6 · Adding an environment

Dev is continuously deployed from `main` by `ci.yml`. Every *other*
environment is deployed by `promote.yml` — build once, promote many: it
never builds, it deploys an image SHA the dev pipeline already smoked, and
it applies that env's Terraform on the way in (so the same button is the
cold bring-up).

`promote.yml` and `destroy.yml` take the environment as a **plain string**
and validate it against the repo, so nothing below is a workflow edit.
Adding `staging` and `prod` — or a fourth environment — is these four steps.

**a. Repo: the env root and its values file.** Already present for
`staging` and `prod`. For a new one, copy an existing root and change three
things — the backend `key`, the `environment` default in `variables.tf`,
and the `vpc_cidr` (dev `10.0`, staging `10.1`, prod `10.2` → take the next
free `/16`; overlapping CIDRs are the one mistake this layout can't catch
for you):

```bash
cp -r terraform/envs/staging terraform/envs/<env>   # then edit those three
cp deploy/envs/staging.yaml  deploy/envs/<env>.yaml # then edit the secret name
```

The values file must name `otel-demo-app-<env>/app/config` — matching
`local.name` in the stack module. The `gates` job in `ci.yml` renders every
`deploy/envs/*.yaml` and asserts exactly that, so a typo here fails at PR
time rather than during an approval window.

**b. AWS: the bounded role.** Add the env to the map and re-apply *locally*
— this is the only stack that ever applies from a laptop:

```bash
cp terraform/bootstrap/environments.tfvars.example terraform/bootstrap/environments.tfvars
# edit the map: keep dev's trust_main_ref = true, leave gated envs without it
terraform -chdir=terraform/bootstrap apply -var-file=environments.tfvars
```

Adding an env is **additive** — the roles are already `for_each`'d over this
map, so there are no renames or replaces. One in-place change is expected
and intended: each existing env's boundary policy gains the new env's
sibling denies (state keys, `otel-demo-app-<new>/*` secrets, log groups,
dashboards). Dev's credential gets *stricter*, which is the wall working.

**c. GitHub: the protected environment.** This is the approval gate, and it
is also what makes the OIDC sub `environment:<env>` — the only sub that env's
role trusts. One required reviewer plus a main-only branch policy:

```bash
REPO=dralgorhythm/opentelemetry-demo-app
OWNER_ID=$(gh api user -q .id)
for e in staging prod; do
  gh api -X PUT "repos/$REPO/environments/$e" --input - <<EOF
{"reviewers":[{"type":"User","id":$OWNER_ID}],
 "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
EOF
  gh api -X POST "repos/$REPO/environments/$e/deployment-branch-policies" -f name=main
  gh variable set CI_ROLE_ARN --env "$e" -R "$REPO" \
    --body "$(terraform -chdir=terraform/bootstrap output -json ci_role_arns | jq -r ".$e")"
done
```

Approving your own dispatch is the intended solo flow — leave "prevent
self-review" off. The **environment-scoped** `CI_ROLE_ARN` shadows the
repo-level one (which stays dev's), which is how one `vars.CI_ROLE_ARN`
reference in a workflow resolves per environment. Forget it and the job
assumes dev's role, whose boundary denies the whole apply: noisy, but it
fails closed. `AWS_ACCOUNT_ID` / `AWS_REGION` / `ADMIN_PRINCIPAL_ARN` /
`ALERT_EMAIL` fall back to repo level, which is correct for one account in
one region.

The same fork gotcha as step 3 applies — pass `-R <owner>/<repo>` explicitly.

**d. Promote.** Actions → **promote** → environment `staging`, version
empty (= this ref's HEAD) or a `vX.Y.Z` tag or a full 40-char SHA. The
`resolve` job posts the service→digest manifest to the run summary *before*
the approval prompt, so you approve a specific artifact. First apply into a
cold environment is the long one (~15–20 min for VPC + EKS); the deploy job
then gates on `scripts/smoke.sh cloud` against that env's own ALB and
ElastiCache.

Tear down the same way: Actions → **destroy** → type `destroy`, name the
environment.

> **Cost.** Each *running* environment is its own VPC + NAT + EKS control
> plane + nodes + ALB + ElastiCache — this is not a namespace, it is a
> parallel stack. The per-env `budget_usd` is a tripwire, not a ceiling.
> Assume the ephemeral posture (promote → drill → destroy) unless you mean
> to pay for uptime.

Why things are the way they are: [DECISIONS.md](./DECISIONS.md) · what's
deliberately not built yet: [DEFERRED.md](./DEFERRED.md).
