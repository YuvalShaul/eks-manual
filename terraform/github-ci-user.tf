# The identity GitHub Actions uses to reach the cluster.
#
# An IAM user with an access key. The key goes into GitHub secrets
# (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY). It can do two things:
#   - in AWS:        read the cluster's address (aws eks update-kubeconfig)
#   - in Kubernetes: edit the "default" namespace, and nothing else
# You (the cluster creator) stay cluster admin.

resource "aws_iam_user" "github_ci" {
  name = "${var.cluster_name}-github-ci"
}

resource "aws_iam_access_key" "github_ci" {
  user = aws_iam_user.github_ci.name
}

# AWS permission: only "describe this one cluster".
resource "aws_iam_user_policy" "github_ci" {
  name = "describe-cluster"
  user = aws_iam_user.github_ci.name
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
  principal_arn = aws_iam_user.github_ci.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_ci" {
  cluster_name  = module.my_eks_cluster.cluster_name
  principal_arn = aws_iam_user.github_ci.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["default"]
  }

  depends_on = [aws_eks_access_entry.github_ci]
}

# ---- Outputs: what you copy into GitHub ----

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.my_eks_cluster.cluster_name
}

output "github_ci_access_key_id" {
  value = aws_iam_access_key.github_ci.id
}

output "github_ci_secret_access_key" {
  value     = aws_iam_access_key.github_ci.secret
  sensitive = true # shown only with: terraform output -raw github_ci_secret_access_key
}
