# EKS + GitHub Actions demo

A tiny Flask app, built by GitHub Actions, pushed to Docker Hub, and run on EKS.

The point is to see **who is allowed to do what, and where the credentials live**:

| Action | Who does it | Credential | Where it is kept |
|---|---|---|---|
| Push image to Docker Hub | GitHub Actions | Docker Hub access token | GitHub secret `DOCKERHUB_TOKEN` |
| Talk to AWS (find the cluster) | GitHub Actions | IAM user `learn-eks-github-ci` access key | GitHub secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Deploy into Kubernetes | GitHub Actions | the same IAM user, mapped by an EKS access entry | the cluster (Terraform created the mapping) |
| Create/destroy the cluster | You | your own AWS credentials | your laptop (`aws configure`) |

```
repo/
├── app/                  Flask app + Dockerfile
├── k8s/app.yaml          Deployment + LoadBalancer Service
├── terraform/            EKS cluster (copied from the k8s course) + the CI user
└── .github/workflows/
    ├── build-push.yml    CI: build image, push to Docker Hub
    └── deploy.yml        CD: run the image on EKS
```

You need: a GitHub repo with this code, a Docker Hub account, an AWS account,
and on your laptop `docker`, `terraform`, `aws`, `kubectl` (and optionally `gh`).

---

## Part 1 – The app, by hand

```bash
cd app
docker build -t hello-flask .
docker run --rm -p 5000:5000 hello-flask
curl localhost:5000        # {"message": "Hello from EKS!", "pod": "...", "version": "dev"}
```

Push it to Docker Hub yourself, with **your** login:

```bash
docker login                                   # your Docker Hub user + password/token
docker tag hello-flask <dockerhub-user>/hello-flask:manual
docker push <dockerhub-user>/hello-flask:manual
```

That worked because *your laptop* holds your Docker Hub credentials (`~/.docker/config.json`).
GitHub's runners don't have them — so we hand them over as secrets.

## Part 2 – Docker Hub from GitHub Actions

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
4. Check Docker Hub: `<dockerhub-user>/hello-flask` now has `latest` and a commit tag.

Things to notice:
- In the log, the token appears as `***`. GitHub masks secrets.
- The username is a *variable*, not a secret: it's not sensitive, and if it were a secret
  every image name in the log would be masked too.
- Try it broken: delete the `DOCKERHUB_TOKEN` secret and re-run → the login step fails.

## Part 3 – Create the cluster (by hand, from your laptop)

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

Check you (the creator) can use the cluster:

```bash
aws eks update-kubeconfig --name learn-eks --region us-west-2
kubectl get nodes
```

## Part 4 – Deploy by hand, as you

```bash
cd ..   # repo root
sed "s|IMAGE|<dockerhub-user>/hello-flask:latest|" k8s/app.yaml | kubectl apply -f -
kubectl get pods
kubectl get svc hello-flask     # EXTERNAL-IP is the load balancer's DNS name
curl http://<that-hostname>     # may take 1-2 minutes to resolve
```

Refresh a few times: `pod` changes — two replicas behind one load balancer.

## Part 5 – Deploy by hand, as the CI user

Before giving the CI key to GitHub, *be* the CI user for a minute:

```bash
cd terraform
export AWS_ACCESS_KEY_ID=$(terraform output -raw github_ci_access_key_id)
export AWS_SECRET_ACCESS_KEY=$(terraform output -raw github_ci_secret_access_key)
aws sts get-caller-identity                       # ...:user/learn-eks-github-ci
aws eks update-kubeconfig --name learn-eks --region us-west-2 --kubeconfig /tmp/ci-kubeconfig
export KUBECONFIG=/tmp/ci-kubeconfig

kubectl auth whoami
kubectl get pods                                  # allowed (namespace default)
kubectl get pods -n kube-system                   # Forbidden
kubectl get nodes                                 # Forbidden
kubectl auth can-i --list                         # everything it may do
aws eks list-clusters                             # AccessDenied - only DescribeCluster was granted

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY KUBECONFIG   # back to being you
```

Two layers of permission: **IAM** decides who you are and what AWS API calls you may make;
the **EKS access entry** decides what you may do inside Kubernetes.

## Part 6 – Deploy from GitHub Actions

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
- *Who does AWS think we are?* → the CI user
- *What may we do?* → yes in `default`, no in `kube-system`, no nodes
- the **job summary** shows the app URL.

## Part 7 – Full CI/CD

Turn on automatic deploys:

```bash
gh variable set AUTO_DEPLOY --body true      # or add it in the Variables tab
```

Now change the message in `app/app.py`, commit, push to `main`:
`build-push` runs → when it succeeds, `deploy` runs → curl the URL, see the new `version`.

```bash
git commit -am "new message" && git push
```

---

## Clean up (important – this costs money: EKS, NAT gateway, EC2, load balancer)

Delete the Service first, so AWS removes the load balancer (otherwise it blocks deleting the VPC):

```bash
kubectl delete -f k8s/app.yaml
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
