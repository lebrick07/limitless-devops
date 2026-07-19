# Quick Start

## Directory layout

```
helm/
  phoenix/           Phoenix LiveView app chart
  karpenter/         Karpenter NodePool + EC2NodeClass chart
  nginx-ingress/     nginx ingress controller Helm values + rollback file
  QUICKSTART.md      This file
```

---

## Local — Docker Desktop

**Prerequisites:** Docker Desktop with Kubernetes enabled.

```bash
# 1. Install nginx ingress controller (one-time)
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait

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

### 2. Configure kubectl

```bash
aws eks update-kubeconfig --name dev-app-api-cl01 --region us-east-1
```

### 3. Pull latest app code

```bash
cd ~/github/limitless-devops && git pull
```

### 4. Build the image

> If disk space runs out: `docker system prune -af`

```bash
aws ecr-public get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin public.ecr.aws

docker build -t public.ecr.aws/m8k1g5q8/phoenix-liveview-demo:v1.0.0 .
```

### 5. Push to ECR Public

```bash
docker push public.ecr.aws/m8k1g5q8/phoenix-liveview-demo:v1.0.0
```

### 6. Install nginx ingress controller (with ACM TLS)

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f helm/nginx-ingress/values-eks.yaml \
  --wait
```

> **Note:** `backend-protocol: tcp` is required (not `http`). Classic ELBs strip WebSocket upgrade headers in HTTP mode. TCP mode passes the raw decrypted stream through, keeping WebSocket intact.

### 7. Install Karpenter controller

```bash
# Authenticate to ECR Public first (required for OCI Helm registry)
aws ecr-public get-login-password --region us-east-1 | \
  helm registry login --username AWS --password-stdin public.ecr.aws

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "1.3.3" \
  --namespace karpenter --create-namespace \
  -f helm/karpenter/values-controller.yaml \
  --wait
```

### 8. Deploy Karpenter NodePool + EC2NodeClass

```bash
helm upgrade --install karpenter-config ./helm/karpenter \
  --namespace karpenter
```

### 9. Deploy the Phoenix app

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

### 10. Watch it come up

```bash
kubectl rollout status deployment/phoenix-demo-phoenix-liveview-demo
kubectl get pods -w
```

---

### DNS

Get the ELB hostname and upsert the Route53 CNAME in one shot:

```bash
ELB_HOSTNAME=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

aws route53 change-resource-record-sets \
  --hosted-zone-id Z00700503JFGXII6MMCA9 \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"phoenix.autometalabs.io\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [{\"Value\": \"$ELB_HOSTNAME\"}]
      }
    }]
  }"
```

### Rollback to HTTP-only

```bash
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  -f helm/nginx-ingress/values-eks-http.yaml \
  --wait
```

The ELB hostname stays the same — no Route53 change needed.

### Install Helm in CloudShell (persists across sessions)

```bash
mkdir -p ~/bin
curl -fsSL -o /tmp/get-helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x /tmp/get-helm.sh
HELM_INSTALL_DIR=~/bin USE_SUDO=false /tmp/get-helm.sh
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
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
