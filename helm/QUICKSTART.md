# Quick Start — Local (Docker Desktop)

**Prerequisites:** Docker Desktop with Kubernetes enabled.

```bash
# 1. Install the nginx ingress controller (one-time)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml

# 2. Install Postgres (one-time)
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install postgres bitnami/postgresql \
  --set auth.username=demo \
  --set auth.password=demo \
  --set auth.database=demo \
  --set primary.persistence.enabled=false

# 3. Clone this repo
git clone https://github.com/lebrick07/limitless-devops && cd limitless-devops

# 4. Deploy
helm install phoenix-demo ./helm \
  -f helm/values-local.yaml \
  --set secretEnv.SECRET_KEY_BASE="$(openssl rand -hex 64)"

# 5. Open http://localhost
```

The image is pulled automatically from ECR Public — no credentials or local build required.
