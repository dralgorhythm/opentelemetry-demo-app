# One private registry per service image, from one list — adding service #2
# to var.services is the entire infra cost of a new service. The discipline
# is in how CI tags (git SHA, never :latest) so deploys are traceable and
# rollbackable.
#
# Account-scoped on purpose: every environment deploys the SAME immutable
# SHA image, so promotion rebuilds nothing and what a future staging smokes
# is byte-for-byte what prod runs. Bonus: images survive environment
# teardown drills, so bring-up skips already-pushed SHAs.
resource "aws_ecr_repository" "svc" {
  for_each             = toset(var.services)
  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "IMMUTABLE" # a pushed tag can't be silently repointed

  # A full account reset destroys this stack with images still inside; without
  # this, `terraform destroy` fails on the non-empty repo. Prod would keep
  # false — deleting a registry full of images is data loss.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Cross-account pull — inert until var.cross_account_pull_account_ids lists a
# consumer account (the account-per-env seam).
data "aws_iam_policy_document" "cross_account_pull" {
  count = length(var.cross_account_pull_account_ids) > 0 ? 1 : 0

  statement {
    sid = "CrossAccountPull"
    principals {
      type        = "AWS"
      identifiers = [for id in var.cross_account_pull_account_ids : "arn:aws:iam::${id}:root"]
    }
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
}

resource "aws_ecr_repository_policy" "cross_account_pull" {
  for_each   = length(var.cross_account_pull_account_ids) > 0 ? aws_ecr_repository.svc : {}
  repository = each.value.name
  policy     = data.aws_iam_policy_document.cross_account_pull[0].json
}
