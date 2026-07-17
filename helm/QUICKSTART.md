# Quick Start — Local (Docker Desktop)

**Prerequisites:** Docker Desktop with Kubernetes enabled.

```bash
# 1. Install the nginx ingress controller (one-time)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml

# 2. Clone this repo
git clone https://github.com/lebrick07/limitless-devops && cd limitless-devops

# 3. Deploy
helm install phoenix-demo ./helm \
  -f helm/values-local.yaml \
  --set secretEnv.SECRET_KEY_BASE="$(openssl rand -hex 64)" \
  --set secretEnv.DATABASE_URL="ecto://user:pass@localhost/demo"

# 4. Open http://localhost
```

The image is pulled automatically from ECR Public — no credentials or local build required.

The LiveView demos (Snake, Thermostat, Clock, Pacman) work without a real database. DB-backed pages will show connection errors unless a real Postgres instance is provided via `DATABASE_URL`.
