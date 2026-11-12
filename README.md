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
| Talk to AWS (find the cluster) | GitHub Actions runner (a fresh VM on GitHub's servers) | access key of IAM user `github-ci` (you create it by hand) | GitHub secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Deploy into Kubernetes | GitHub Actions runner (a fresh VM on GitHub's servers) | the same IAM user, mapped by an EKS access entry | the cluster (Terraform grants it) |
| Create/destroy the cluster | You | your own AWS credentials | your laptop (`aws configure`) |

```
repo/
├── app/                  Flask app + Dockerfile
├── k8s/app.yaml          Deployment + LoadBalancer Service
├── terraform/            EKS cluster (copied from the k8s course) + the CI user's permissions
└── .github/workflows/
    ├── build-push.yml    build image, push to Docker Hub
    ├── deploy.yml        run the image on EKS
    └── undeploy.yml      remove the app from EKS
```

You need: a GitHub repo with this code, a Docker Hub account, an AWS account,
and on your laptop `terraform` and `aws`. No Docker, no `kubectl`:
your laptop only creates and destroys the cluster. Everything that touches the app runs on a
GitHub runner, started by you with the **Run workflow** button. Nothing runs automatically.

---

## Part 1 – Docker Hub from GitHub Actions

1. Docker Hub → **Account settings → Personal access tokens → Generate new token**,
   permission **Read & Write**. Copy it (it is shown once).
2. GitHub repo → **Settings → Secrets and variables → Actions**:
   - **Secrets** tab → New repository secret: `DOCKERHUB_TOKEN` = the token
   - **Variables** tab → New repository variable: `DOCKERHUB_USERNAME` = your Docker Hub user
3. Run it: **Actions → build-push → Run workflow**.
   Open the run and look at *Set up job*: it shows the runner's OS image and machine — that's where the
   build happens, not on your laptop.
4. Check Docker Hub: `<dockerhub-user>/hello-flask` now has `latest` and a commit tag.

Things to notice:
- In the log, the token appears as `***`. GitHub masks secrets.
- The username is a *variable*, not a secret: it's not sensitive, and if it were a secret
  every image name in the log would be masked too.
- Try it broken: delete the `DOCKERHUB_TOKEN` secret and re-run → the login step fails.

## Part 2 – An AWS user for GitHub Actions (by hand, in the AWS console)

GitHub's runner needs its own AWS identity. Not yours: a user made just for this, that can do
very little.

1. AWS console → **IAM → Users → Create user**
   - User name: `github-ci`
   - Do **not** give it console access (it's for a program, not a person)
   - Permissions: attach **nothing** for now → **Create user**
2. Open the user → **Security credentials → Create access key**
   - Use case: **Application running outside AWS** → Next → **Create access key**
   - You now see the **Access key ID** and the **Secret access key**. The secret is shown
     **once**. Keep this page open for the next step.
3. GitHub repo → **Settings → Secrets and variables → Actions → Secrets**:
   - `AWS_ACCESS_KEY_ID` = the access key ID
   - `AWS_SECRET_ACCESS_KEY` = the secret access key
4. Close the AWS page. The secret now lives in exactly one place: GitHub secrets.
   Anyone who can run workflows in this repo can *use* it; nobody can *read* it back. Not even you.

Right now `github-ci` exists, but it is allowed to do nothing. The next part grants it permissions.

## Part 3 – Create the cluster (by hand, from your laptop)

```bash
aws sts get-caller-identity     # make sure these are YOUR admin credentials, not github-ci's
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply -var-file=terraform.tfvars                 # ~15-20 minutes
```

`eks_terraform_config.tf` + `vars.tf` are the cluster from the k8s course (VPC, EKS, a node group).
`github-ci-user.tf` is new. It does **not** create the user or any key; it only gives your
hand-made `github-ci` user two permissions:

- **AWS (IAM):** only `eks:DescribeCluster` on this cluster
- **Kubernetes (EKS access entry):** `AmazonEKSEditPolicy`, **only in namespace `default`**

Look at the user in the IAM console again: it now has an inline policy `describe-learn-eks`.
And under **EKS → learn-eks → Access**, you'll find `github-ci` with its access policy.

If you changed the region or the cluster name, tell GitHub too
(**Settings → Secrets and variables → Actions → Variables**): `AWS_REGION`, `EKS_CLUSTER`.

## Part 4 – Deploy from GitHub Actions

Run it: **Actions → deploy → Run workflow** (tag: `latest`). Read the log:
- *Who does AWS think we are?* → `user/github-ci`, not you
- *What may we do?* → yes in `default`, no in `kube-system`, no nodes
- the **job summary** shows the app URL. Open it (DNS may take 1-2 minutes the first time) and
  refresh a few times: `pod` changes — two replicas behind one load balancer.

Two layers of permission: **IAM** decides who the runner is and which AWS calls it may make
(only `eks:DescribeCluster`); the **EKS access entry** decides what it may do inside Kubernetes
(edit namespace `default`, nothing else).

Try it broken: in IAM, **deactivate** the `github-ci` access key and re-run deploy → the very
first AWS call fails. Activate it again and it works.

---

## Clean up (important – this costs money: EKS, NAT gateway, EC2, load balancer)

1. **Actions → undeploy → Run workflow.** This deletes the app and its load balancer
   (a leftover load balancer blocks deleting the VPC).
2. From your laptop:

   ```bash
   cd terraform
   terraform destroy -var-file=terraform.tfvars
   ```
3. By hand, what you created by hand:
   - AWS console → IAM → Users → delete `github-ci` (this kills its access key too)
   - Docker Hub → delete the access token
   - GitHub → delete the secrets

## Notes

- **Static keys vs OIDC.** Here GitHub holds a long-lived AWS key and a Docker Hub token.
  That's the easiest to understand, and it's what many teams do. But if a secret leaks, it
  works until someone revokes it. The other way is OIDC: GitHub proves which workflow is
  running, and AWS hands out 1-hour credentials; nothing is stored. That's a separate lab.
- `AmazonEKSEditPolicy` can't create namespaces – that's why the app runs in `default`.
