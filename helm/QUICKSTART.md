# Quick Start — Local (Docker Desktop)

**Prerequisites:** Docker Desktop with Kubernetes enabled.

```bash
# 1. Install the nginx ingress controller (one-time)
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
