# Quick Start

## Directory layout

```
helm/
  phoenix/          Phoenix LiveView app chart
  karpenter/        Karpenter NodePool + EC2NodeClass chart
  QUICKSTART.md     This file
```

---

## Local — Docker Desktop

**Prerequisites:** Docker Desktop with Kubernetes enabled.

```bash
# 1. Install nginx ingress controller (one-time)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml

# 2. Clone this repo
git clone https://github.com/lebrick07/limitless-devops && cd limitless-devops

# 3. Deploy (Postgres is bundled — no separate install needed)
helm install phoenix-demo ./helm/phoenix \
  -f helm/phoenix/values-local.yaml \
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

docker build -t public.ecr.aws/m8k1g5q8/phoenix-liveview-demo:v1.0.0 .
```

### 4. Push to ECR Public

```bash
docker push public.ecr.aws/m8k1g5q8/phoenix-liveview-demo:v1.0.0
```

### 5. Install Karpenter controller (one-time)

```bash
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "1.3.3" \
  --namespace karpenter --create-namespace \
  -f helm/karpenter/values-controller.yaml \
  --wait
```

### 6. Deploy Karpenter NodePool + EC2NodeClass

```bash
helm upgrade --install karpenter-config ./helm/karpenter \
  --namespace karpenter
```

### 7. Deploy the Phoenix app

```bash
# Fresh install
helm install phoenix-demo ./helm/phoenix \
  -f helm/phoenix/values-eks.yaml \
  --set secretEnv.SECRET_KEY_BASE="$(openssl rand -hex 64)"

# Upgrade (after image rebuild or config change)
helm upgrade phoenix-demo ./helm/phoenix \
  -f helm/phoenix/values-eks.yaml \
  --set secretEnv.SECRET_KEY_BASE="$(openssl rand -hex 64)"

# Uninstall
helm uninstall phoenix-demo
```

### 8. Watch it come up

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

---

## Karpenter design decisions

| Decision | Choice | Why |
|---|---|---|
| Capacity type | On-demand only | Spot gives 2-min notice — not enough to drain open WebSocket connections |
| Instance families | c6i, m6i | Balanced CPU+memory for the BEAM; m6i for high connection counts |
| Consolidation | `WhenEmpty` | `WhenUnderutilized` evicts pods and drops active connections |
| Node expiry | 30 days | Forces AMI/kernel rotation without manual drain cycles |

The NodePool taints nodes with `workload=phoenix-liveview:NoSchedule`. The matching toleration is already set in `helm/phoenix/values-eks.yaml` so Phoenix pods schedule onto Karpenter nodes automatically.
