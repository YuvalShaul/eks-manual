# EKS + GitHub Actions demo

A tiny Flask app, built by GitHub Actions, pushed to Docker Hub, and run on EKS.

**The image is never built on your laptop.** No `docker build`, no `docker login`, no Docker Hub
password on your machine. A GitHub Actions *runner* — a fresh virtual machine on GitHub's servers,
created for each run and thrown away after — checks out the code, builds the image, and pushes it
using credentials it gets only from the repo's secrets.

The point is to see **who is allowed to do what, and where the credentials live**:

| Action | Who does it | Credential | Where it is kept |
|---|---|---|---|
| Build image, push to Docker Hub | GitHub Actions runner (a fresh VM on GitHub's servers) | Docker Hub access token | GitHub secret `DOCKERHUB_TOKEN` |
| Talk to AWS (find the cluster) | GitHub Actions runner (a fresh VM on GitHub's servers) | IAM user `learn-eks-github-ci` access key | GitHub secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Deploy into Kubernetes | GitHub Actions runner (a fresh VM on GitHub's servers) | the same IAM user, mapped by an EKS access entry | the cluster (Terraform created the mapping) |
| Create/destroy the cluster | You | your own AWS credentials | your laptop (`aws configure`) |

```
repo/
├── app/                  Flask app + Dockerfile
├── k8s/app.yaml          Deployment + LoadBalancer Service
├── terraform/            EKS cluster (copied from the k8s course) + the CI user
└── .github/workflows/
    ├── build-push.yml    CI: build image, push to Docker Hub
    ├── deploy.yml        CD: run the image on EKS
    └── undeploy.yml      remove the app from EKS
```

You need: a GitHub repo with this code, a Docker Hub account, an AWS account,
and on your laptop `terraform` and `aws` (and optionally `gh`). No Docker, no `kubectl`:
your laptop only creates and destroys the cluster. Everything that touches the app runs in CI.

---

## Part 1 – Docker Hub from GitHub Actions

1. Docker Hub → **Account settings → Personal access tokens → Generate new token**,
   permission **Read & Write**. Copy it (it is shown once).
2. GitHub repo → **Settings → Secrets and variables → Actions**:
   - **Secrets** tab → New repository secret: `DOCKERHUB_TOKEN` = the token
   - **Variables** tab → New repository variable: `DOCKERHUB_USERNAME` = your Docker Hub user

   Or with the `gh` CLI:
   ```bash
   gh secret set DOCKERHUB_TOKEN          # paste the token when asked
   gh variable set DOCKERHUB_USERNAME --body <dockerhub-user>
   ```
3. Run it: **Actions → build-push → Run workflow**. (It also runs on every push to `main` that touches `app/`.)
   Open the run and look at *Set up job*: it shows the runner's OS image and machine — that's where the
   build happens, not on your laptop.
4. Check Docker Hub: `<dockerhub-user>/hello-flask` now has `latest` and a commit tag.

Things to notice:
- In the log, the token appears as `***`. GitHub masks secrets.
- The username is a *variable*, not a secret: it's not sensitive, and if it were a secret
  every image name in the log would be masked too.
- Try it broken: delete the `DOCKERHUB_TOKEN` secret and re-run → the login step fails.

## Part 2 – Create the cluster (by hand, from your laptop)

```bash
aws sts get-caller-identity     # make sure these are YOUR admin credentials
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply -var-file=terraform.tfvars                 # ~15-20 minutes
```

`eks_terraform_config.tf` + `vars.tf` are the cluster from the k8s course (VPC, EKS, a node group).
`github-ci-user.tf` is new: it creates the identity GitHub Actions will use:

- an IAM user `learn-eks-github-ci` with an access key
- AWS permission: only `eks:DescribeCluster` on this cluster
- Kubernetes permission (EKS access entry): `AmazonEKSEditPolicy`, **only in namespace `default`**

## Part 3 – Deploy from GitHub Actions

Put the CI user's key into GitHub secrets:

```bash
cd terraform
terraform output github_ci_access_key_id
terraform output -raw github_ci_secret_access_key
```

Settings → Secrets and variables → Actions → **Secrets**: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`.

Or straight from Terraform to GitHub, without ever seeing the key:

```bash
gh secret set AWS_ACCESS_KEY_ID     --body "$(terraform output -raw github_ci_access_key_id)"
gh secret set AWS_SECRET_ACCESS_KEY --body "$(terraform output -raw github_ci_secret_access_key)"
# only if you changed them from the defaults:
gh variable set AWS_REGION  --body us-west-2
gh variable set EKS_CLUSTER --body learn-eks
```

Run it: **Actions → deploy → Run workflow** (tag: `latest`). Read the log:
- *Who does AWS think we are?* → `user/learn-eks-github-ci`, not you
- *What may we do?* → yes in `default`, no in `kube-system`, no nodes
- the **job summary** shows the app URL. Open it (DNS may take 1-2 minutes the first time) and
  refresh a few times: `pod` changes — two replicas behind one load balancer.

Two layers of permission: **IAM** decides who the runner is and which AWS calls it may make
(only `eks:DescribeCluster`); the **EKS access entry** decides what it may do inside Kubernetes
(edit namespace `default`, nothing else).

## Part 4 – Full CI/CD

Turn on automatic deploys:

```bash
gh variable set AUTO_DEPLOY --body true      # or add it in the Variables tab
```

Now change the message in `app/app.py`, commit, push to `main`:
`build-push` runs → when it succeeds, `deploy` runs → reload the app URL, see the new `version`.

```bash
git commit -am "new message" && git push
```

---

## Clean up (important – this costs money: EKS, NAT gateway, EC2, load balancer)

1. **Actions → undeploy → Run workflow.** This deletes the app and its load balancer
   (a leftover load balancer blocks deleting the VPC).
2. Then, from your laptop:

```bash
cd terraform
terraform destroy -var-file=terraform.tfvars
```

Then delete the now-useless secrets in GitHub, and revoke the Docker Hub token.

## Notes

- **Static keys vs OIDC.** Here GitHub holds a long-lived AWS key. That's the easiest to
  understand, and it's what many teams do — but if the secret leaks, it works until someone
  revokes it. The better way is OIDC: GitHub proves who the workflow is, and AWS hands out
  1-hour credentials; nothing is stored. (See `eks/github-actions-access` in the k8s course.)
- The access key is also stored in the Terraform state file. Keep `terraform.tfstate` private.
- `AmazonEKSEditPolicy` can't create namespaces – that's why the app runs in `default`.
