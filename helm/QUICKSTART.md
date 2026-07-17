# Quick Start

## Local — Docker Desktop

**Prerequisites:** Docker Desktop with Kubernetes enabled.

```bash
# 1. Install nginx ingress controller (one-time)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml

# 2. Clone this repo
git clone https://github.com/lebrick07/limitless-devops && cd limitless-devops

# 3. Deploy (Postgres is bundled — no separate install needed)
helm install phoenix-demo ./helm \
  -f helm/values-local.yaml \
  --set secretEnv.SECRET_KEY_BASE="$(openssl rand -hex 64)"

# 4. Open http://localhost
```

The image is pulled automatically from ECR Public — no credentials or local build required.  
The database is created, migrated, and seeded with 1 000 users automatically on first deploy.

---

## EKS — End-to-End Steps (run in AWS CloudShell)

> **Note:** CloudShell runs on linux/amd64 — required to avoid a platform mismatch with EKS x86_64 nodes when building on Apple Silicon.

### 1. Provision the EKS cluster (Terraform)

```bash
cd ~/github/eks_deploy/infra_deploy/dev

terraform init
terraform plan
terraform apply
```

> To tear down: `terraform destroy`

### 2. Pull latest app code

```bash
cd ~/github/limitless-devops && git pull
```

### 3. Build the image

> If disk space runs out: `docker system prune -af`

```bash
aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws

docker build \
  -f ../limitless-devops/Dockerfile \
  -t public.ecr.aws/m8k1g5q8/phoenix-liveview-demo:v1.0.0 \
  -t public.ecr.aws/m8k1g5q8/phoenix-liveview-demo:latest \
  .
```

### 4. Push to ECR Public

```bash
docker push public.ecr.aws/m8k1g5q8/phoenix-liveview-demo:v1.0.0
docker push public.ecr.aws/m8k1g5q8/phoenix-liveview-demo:latest
```

### 5. Deploy with Helm

```bash
# Fresh install
helm install phoenix-demo ./helm \
  -f helm/values-eks.yaml \
  --set secretEnv.SECRET_KEY_BASE="$(openssl rand -hex 64)"

# Upgrade (after image rebuild or config change)
helm upgrade phoenix-demo ./helm \
  -f helm/values-eks.yaml \
  --set secretEnv.SECRET_KEY_BASE="$(openssl rand -hex 64)"

# Uninstall
helm uninstall phoenix-demo
```

### 6. Watch it come up

```bash
kubectl rollout status deployment/phoenix-demo-phoenix-liveview-demo
kubectl get pods -w
```

---

### One-time setup (new cluster)

**nginx ingress controller:**

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

**DNS:** Get the ELB hostname and add a CNAME in Route53:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Install Helm in CloudShell (if missing):**

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```
