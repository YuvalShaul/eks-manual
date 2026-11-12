# Permissions for the IAM user GitHub Actions uses.
#
# You create that user and its access key BY HAND in the AWS console (see README, Part 2),
# and paste the key into GitHub secrets yourself. Terraform never sees the key.
# Terraform only grants the existing user two things:
#   - in AWS:        read this cluster's address (aws eks update-kubeconfig)
#   - in Kubernetes: edit the "default" namespace, and nothing else

variable "github_ci_user" {
  description = "Name of the IAM user you created by hand for GitHub Actions"
  type        = string
  default     = "github-ci"
}

# Fails right away if you haven't created the user yet.
data "aws_iam_user" "github_ci" {
  user_name = var.github_ci_user
}

# AWS permission: only "describe this one cluster".
resource "aws_iam_user_policy" "github_ci" {
  name = "describe-${var.cluster_name}"
  user = data.aws_iam_user.github_ci.user_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = module.my_eks_cluster.cluster_arn
    }]
  })
}

# Kubernetes permission: IAM says WHO the caller is; this says WHAT it may do in the cluster.
resource "aws_eks_access_entry" "github_ci" {
  cluster_name  = module.my_eks_cluster.cluster_name
  principal_arn = data.aws_iam_user.github_ci.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_ci" {
  cluster_name  = module.my_eks_cluster.cluster_name
  principal_arn = data.aws_iam_user.github_ci.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["default"]
  }

  depends_on = [aws_eks_access_entry.github_ci]
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.my_eks_cluster.cluster_name
}

output "github_ci_user_arn" {
  value = data.aws_iam_user.github_ci.arn
}
