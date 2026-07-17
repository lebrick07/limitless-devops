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

## EKS

**Prerequisites:** EKS cluster with `kubectl` configured, nginx ingress controller installed.

> **Note:** If building on Apple Silicon (arm64 Mac), build the image in AWS CloudShell (native linux/amd64) to avoid a platform mismatch on EKS x86_64 nodes.

### 1. Build and push the image (run in AWS CloudShell)

```bash
git clone https://github.com/chrismccord/phoenix_live_view_example
git clone https://github.com/lebrick07/limitless-devops
cp limitless-devops/runtime.exs phoenix_live_view_example/
cp limitless-devops/page_live.ex phoenix_live_view_example/page_live.ex

aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws

cd phoenix_live_view_example
docker build -f ../limitless-devops/Dockerfile \
  -t public.ecr.aws/m8k1g5q8/phoenix-liveview-demo:v1.0.0 .
docker push public.ecr.aws/m8k1g5q8/phoenix-liveview-demo:v1.0.0
```

### 2. Install nginx ingress (one-time)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

### 3. Deploy

```bash
git clone https://github.com/lebrick07/limitless-devops && cd limitless-devops

helm install phoenix-demo ./helm \
  -f helm/values-eks.yaml \
  --set secretEnv.SECRET_KEY_BASE="$(openssl rand -hex 64)"
```

### 4. Point DNS to the ELB

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Add a CNAME in Route53 (or your DNS provider): `phoenix.yourdomain.com` → ELB hostname.

### 5. Verify

```bash
kubectl get pods
kubectl logs deployment/phoenix-demo-phoenix-liveview-demo --tail=20
```

### Upgrade after image rebuild

```bash
helm upgrade phoenix-demo ./helm \
  -f helm/values-eks.yaml \
  --set secretEnv.SECRET_KEY_BASE="$(openssl rand -hex 64)"
```
