# Limitless DevOps Home Assignment

Deployment infrastructure for the [Phoenix LiveView example app](https://github.com/chrismccord/phoenix_live_view_example). Target environment: AWS GovCloud (us-gov-west-1) on EKS with Karpenter.

**On time budget:** The core submission — Dockerfile, Helm chart, Karpenter manifests, and this README — took approximately 6–7 hours, comfortably within the 9-hour ceiling. I then chose to go further: provisioning a real EKS cluster using Terraform I developed myself ([github.com/lebrick07/eks_deploy](https://github.com/lebrick07/eks_deploy)), deploying Karpenter end-to-end, and validating the full stack live at `phoenix.autometalabs.io`. That additional work is detailed in a follow-up email. The optional bonus items (load test, custom-metrics HPA, working multi-replica) were deliberately deferred in favour of getting the core right.

---

## Deploy

See [helm/QUICKSTART.md](helm/QUICKSTART.md) for step-by-step local and EKS deploy instructions.

---

## Repository layout

```
Dockerfile              Multi-stage production image build
runtime.exs             Patched runtime config (server: true, Cowboy drain)
page_live.ex            Upstream bug patch (live_dashboard_path removed)
helm/
  QUICKSTART.md         Step-by-step deploy guide (local + EKS)
  phoenix/              Phoenix LiveView app Helm chart
    Chart.yaml
    values.yaml         Production defaults (ECR image, HPA, PDB)
    values-local.yaml   Docker Desktop override
    values-eks.yaml     EKS override
    templates/
      deployment.yaml
      service.yaml
      ingress.yaml
      hpa.yaml
      pdb.yaml
      serviceaccount.yaml
      secret.yaml
  karpenter/            Karpenter NodePool + EC2NodeClass Helm chart
    Chart.yaml
    values.yaml         Default values (cluster name, region, instance types)
    values-controller.yaml  Values for the upstream Karpenter controller chart
    templates/
      nodepool.yaml
      ec2nodeclass.yaml
README.md               This file
```

---

## Assumptions

The brief left a few things open; here is how I resolved each:

- **Database**: The brief says to assume PostgreSQL is provided externally (RDS) and only wire connectivity. `values.yaml` (production defaults) has `postgresql.enabled: false` and expects `DATABASE_URL` injected via a Kubernetes Secret. The bundled `postgres:15-alpine` StatefulSet in `values-local.yaml` and `values-eks.yaml` is for local testing and the live EKS demo only — it is not the production path.
- **GovCloud target**: The brief targets `us-gov-west-1`. The design accounts for GovCloud throughout — ARN partitions, FIPS AMI notes, IMDSv2 enforcement, VPC endpoint requirements — but the live demo runs in `us-east-1` to avoid GovCloud access constraints during development. See the GovCloud section below for the full list of what changes in production.
- **Live cluster**: The brief states local kind or k3d is sufficient and Karpenter specs are evaluated as code, not by running them. I exceeded this deliberately — see the time budget note above.
- **AI tools**: The brief explicitly permits AI assistants. I used Claude Code throughout for scaffolding, debugging, and iteration. Every design decision in this README is mine and I can defend it in the walkthrough.

---

## How the production artifact is built

The `Dockerfile` is a two-stage build:

**Builder** (`hexpm/elixir:1.14.5-erlang-25.3.2-debian-bullseye-20230227-slim`)

1. Installs only `build-essential` and `git` — no runtime tools.
2. Runs `mix deps.get` (all envs, not `--only prod`) so the `esbuild` dev dependency is available for asset compilation.
3. Copies the patched `runtime.exs` over the upstream one. The patch adds `server: true` (required for OTP releases to start the HTTP listener) and the Ranch/Cowboy `transport_options` for graceful drain.
4. Runs `mix assets.deploy` → esbuild bundles and minifies JS, `phx.digest` fingerprints static files.
5. Runs `mix compile` + `mix release`, producing a self-contained OTP release under `_build/prod/rel/demo`. The release bundles ERTS (the Erlang runtime), so the runtime image needs no Elixir or Erlang installed.

**Runner** (`debian:bullseye-20230227-slim`)

Installs only the shared libraries BEAM needs at runtime: `libstdc++6`, `openssl`, `libncurses5`. No build tools, no package manager artefacts.

A non-root user (`uid=1000`) owns the release. `readOnlyRootFilesystem: true` is set; `/tmp` is mounted as an `emptyDir` for crash dumps.

The Kubernetes Deployment mirrors this at the pod level via `securityContext`: `runAsNonRoot: true`, `runAsUser: 1000`, `allowPrivilegeEscalation: false`, and `readOnlyRootFilesystem: true`. These are set at the container level so they are enforced by the kubelet regardless of what the image declares.

**What runs as PID 1**: `bin/demo start` — the OTP release entry point. The BEAM VM handles `SIGTERM` natively by calling `:init.stop()`, which triggers a supervised OTP shutdown. No `tini`/`dumb-init` is needed: the container has a single process tree and OTP manages it.

---

## How a deploy or scale-down avoids dropping open WebSocket connections

Phoenix LiveView connections are long-lived WebSockets. Abruptly killing a pod mid-session drops them without client notice. The drain strategy layers three mechanisms:

### 1. preStop hook (Deployment)

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 15"]
```

Kubernetes sends `SIGTERM` and runs the preStop hook **concurrently**. The 15-second sleep gives kube-proxy and iptables time to remove the pod from Service endpoints so no new connections arrive while the pod is draining. Only after the preStop hook completes does `SIGTERM` reach PID 1.

### 2. Cowboy / Ranch drain (runtime.exs)

```elixir
http: [
  transport_options: [shutdown_timeout: 60_000]
]
```

When the OTP endpoint supervisor terminates, Ranch waits up to 60 seconds for existing HTTP/WebSocket connections to close before forcefully terminating them.

### 3. terminationGracePeriodSeconds (Deployment)

```yaml
terminationGracePeriodSeconds: 90
```

`90 > 15 (preStop) + 60 (Cowboy drain) + 15 (margin)`. Kubelet sends `SIGKILL` only after this window — ensuring the application always gets a chance to drain rather than being hard-killed first.

### Rolling deploy strategy

```yaml
strategy:
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

A new pod must pass readiness before an old one starts its drain. Combined with the PDB (`minAvailable: 2`), no deploy can reduce available capacity below 2 pods.

### Service type and ingress

The Service is `ClusterIP` — the right choice for a LiveView application sitting behind an ingress controller. A `LoadBalancer` Service would expose the app directly through an AWS Classic ELB, which does not handle the WebSocket upgrade natively and adds an unnecessary network hop. `ClusterIP` keeps routing internal; the nginx ingress controller handles the WebSocket upgrade via:

```yaml
nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
```

`proxy-http-version: 1.1` is required — HTTP/1.0 does not support the `Upgrade` header that WebSocket handshakes depend on. The 3600-second timeouts prevent nginx from closing idle-but-connected LiveView sockets during quiet periods.

---

## HPA signal choice: why CPU is insufficient

CPU is the metric available out of the box, but it is a poor fit for LiveView:

| Scenario | CPU signal | Actual load |
|----------|-----------|-------------|
| 1000 idle-but-connected users | Low | High memory + FD pressure |
| 10 users running snake/pacman | Medium-high | Moderate |
| Traffic burst (new connections) | Spike | Actually the worst time to be scaling |

**What CPU captures**: request processing bursts and DOM diff computation. **What it misses**: accumulated open connections, which consume memory, file descriptors, and scheduler slots on the BEAM even when idle.

**Better signal**: active WebSocket connection count per pod, emitted via Phoenix Telemetry and scraped by Prometheus. The HPA template includes a commented KEDA `ScaledObject` using:

```
sum(phoenix_live_view_socket_connected_total) /
  count(kube_pod_info{pod=~"phoenix-liveview-demo.*"})
```

Target threshold: ~500 concurrent sockets per pod (tune per load test). This scales _before_ memory pressure hits and avoids over-scaling on transient CPU spikes.

For this submission: CPU (60%) + memory (70%) as a pragmatic baseline. Scale-down stabilisation is set to 5 minutes to avoid evicting pods while connections are still draining.

---

## Multi-replica considerations

The application uses `Phoenix.PubSub` with the default **local (in-process) adapter**. PubSub and `Phoenix.Presence` work across all LiveView processes **within a single pod** but are **not propagated across pods** without additional infrastructure.

Implications:

- **Presence** (`DemoWeb.Presence`): users on pod A are invisible to users on pod B. The presence index page would show different user lists depending on which pod serves the request.
- **PubSub broadcasts**: a LiveView process on pod A cannot receive a broadcast sent from pod B.

### What is needed for true multi-replica

Two approaches:

**Option A — Erlang distribution + libcluster** (preferred for Phoenix)

Add `libcluster` with the `:kubernetes_dns` strategy. Pods discover each other via headless Service DNS and form an Erlang cluster. `Phoenix.PubSub` then propagates across all nodes using the built-in PG2/PubSub.PG adapter. `Phoenix.Presence` works natively across the cluster.

Requires: headless Service (`clusterIP: None`) + RBAC for pod listing if using the `:kubernetes` strategy. No changes to PubSub config — it distributes automatically once the nodes are connected.

**Option B — External PubSub adapter** (Redis / PostgreSQL)

Replace the local adapter with `phoenix_pubsub_redis`. No Erlang clustering required. Simpler operationally but adds a Redis dependency and higher latency per broadcast.

### What is deferred in this submission

Erlang distribution is not wired up. The Deployment runs as independent pods. For a demo/showcase application this is acceptable; for production multi-user presence, Option A must be implemented before launch. The ServiceAccount template includes the commented RBAC required for `libcluster` `:kubernetes` strategy as a starting point.

---

## Instance families and capacity types

### Instance selection

| Family | vCPU | Mem | Why |
|--------|------|-----|-----|
| `c6i.large` | 2 | 4 GB | Smallest viable BEAM unit; ERTS uses 1 scheduler per logical CPU |
| `c6i.xlarge` | 4 | 8 GB | Primary size; balances per-node connection density with blast radius |
| `c6i.2xlarge` | 8 | 16 GB | HPA burst target; higher connection density per node reduces scheduling overhead |
| `m6i.large/xlarge` | 2-4 | 8-16 GB | More memory per vCPU; useful if per-socket LiveView state is large |

**Why c6i/m6i (6th gen Intel)**: broadly available in us-gov-west-1, well-supported by AL2 EKS AMIs, and offer consistent NVMe-backed networking. Graviton (arm64) is excluded — availability in GovCloud is improving but AMI validation records are thinner and some NIFs in the dependency tree (particularly OpenSSL bindings) require extra testing on musl/arm64.

### Capacity type: on-demand only

Spot instances receive a **2-minute interruption notice**. Our drain window is `preStop (15 s) + Cowboy drain (60 s) = 75 s`. In theory this fits inside 2 minutes, but:

1. The interruption notice goes to the node, not directly to the pod. Karpenter's spot interruption handler evicts the pod, triggering the drain — but the eviction-to-SIGTERM path adds latency.
2. If consolidation and a spot interruption coincide, pods may not fully drain within the window.
3. Open WebSocket connections are a user-facing degradation when dropped.

**Decision**: on-demand for all LiveView pods. Use Reserved Instances or Compute Savings Plans for cost optimisation instead. A separate spot NodePool for stateless batch/utility workloads on the same cluster is reasonable.

### Consolidation: WhenEmpty

`WhenUnderutilized` moves pods to bin-pack nodes. Pod eviction triggers the drain path — even with a PDB, a pod will eventually be evicted once the PDB budget allows, disrupting connections. `WhenEmpty` only reclaims nodes with no pods at all, making it safe for this workload. Nodes expire after 30 days (`expireAfter: 720h`) to force AMI rotation for patch compliance.

---

## GovCloud-specific considerations

| Area | Consideration |
|------|---------------|
| **ARN partition** | All IAM roles, KMS keys, and ECR repositories use `arn:aws-us-gov:...` |
| **IMDSv2** | `httpTokens: required` in EC2NodeClass; hop limit 1 prevents container metadata access |
| **FIPS** | Use AL2 FIPS AMI variant if FedRAMP High is required. Elixir/BEAM uses OpenSSL; verify FIPS-validated OpenSSL is active. `DATABASE_SSL: "true"` enforces TLS to RDS |
| **ECR** | Endpoint: `<account>.dkr.ecr.us-gov-west-1.amazonaws.com`. VPC endpoint for ECR (both `ecr.api` and `ecr.dkr`) keeps image pulls off the internet |
| **KMS** | Uncomment `kmsKeyID` in EC2NodeClass for EBS encryption with a CMK. S3 and Secrets Manager should also use CMKs in FedRAMP environments |
| **Instance availability** | Not all commercial instance types exist in GovCloud. The NodePool limits to `c6i` and `m6i` which are confirmed available in us-gov-west-1 |
| **Secrets Manager** | Prefer `external-secrets-operator` pulling from `secretsmanager.us-gov-west-1.amazonaws.com` over Helm-managed Secrets, so secrets are never in git or Helm state |
| **VPC endpoints** | Required for: ECR, S3 (layer pulls), SSM (AMI resolution), Secrets Manager, STS |

---

## What I left out intentionally and why

| Item | Reason |
|------|--------|
| Erlang distribution / libcluster | Requires deciding on headless Service strategy + testing cluster formation; deferred rather than half-implemented. ServiceAccount template includes the commented RBAC as a starting point. |
| TLS termination | ACM cert requested for `phoenix.autometalabs.io` (DNS validation pending); `ingress.tls` is configured in `values-eks.yaml` with the ARN placeholder. Not wired end-to-end within time budget. |
| Prometheus / ServiceMonitor | Operator CRDs must exist in the cluster; added Prometheus scrape annotations for auto-discovery instead. Full `ServiceMonitor` requires the Prometheus Operator to be installed. |
| Health check endpoint | The app doesn't expose `/healthz`; using `GET /` as readiness target. A dedicated `/health` route would be cleaner and decouple health from page rendering. |
| Custom-metrics HPA | KEDA `ScaledObject` using `phoenix_live_view_socket_connected_total` is sketched in `hpa.yaml` (commented). Requires Prometheus + KEDA installed; deferred rather than half-implemented. |

---

## What I would do differently with more time

1. **Ecto migration Job**: run `bin/demo eval "Demo.Release.migrate()"` as a pre-upgrade Helm hook. Ensure it's idempotent and runs before the new Deployment rolls out.
2. **libcluster**: wire up Erlang distribution using `:kubernetes_dns` strategy so Presence works correctly across pods.
3. **Custom metrics HPA**: implement the KEDA `ScaledObject` with a real Prometheus query. Requires instrumenting the endpoint to expose a `/metrics` path (Telemetry + PromEx or a custom plug).
4. **Load test**: k6 or Locust script that opens N WebSocket connections, then ramps traffic while watching HPA and PDB behaviour.
5. **ECR lifecycle policy**: automated image cleanup to avoid GovCloud storage accumulation.
6. **Pinned image digest**: replace tag references with `@sha256:...` digests in production for supply-chain integrity.

---

## Discovery log

Things I did not know coming in, roughly split between what I investigated deeply and what I took on faith.

- **Elixir OTP releases vs. `mix phx.server`**: learned that `mix release` produces a self-contained binary with bundled ERTS. The critical gap I missed initially: `server: true` must be set in the config for the release to start the HTTP listener — `mix phx.server` does this automatically, the release does not. Found this in the upstream runtime.exs comment block.
- **esbuild as a dev dependency**: `{:esbuild, ..., runtime: Mix.env() == :dev}` is not available when `mix deps.get --only prod` is run. Resolved by fetching all deps in the builder stage; the release only ships runtime deps regardless.
- **Cowboy graceful drain**: investigated how Plug.Cowboy 2.x handles shutdown. Ranch (the TCP acceptor) exposes `shutdown_timeout` via `transport_options`. This was not obvious from the Phoenix docs — found it in the Ranch source and confirmed in Plug.Cowboy's `Plug.Cowboy.child_spec/1` documentation.
- **Phoenix.PubSub local adapter**: assumed PubSub would "just work" across pods. Discovered it is process-local by default; distributed operation requires explicit Erlang clustering or an external adapter. The Presence module makes this a hard requirement for correct multi-replica behaviour.
- **GovCloud instance availability**: not all instance types from `aws ec2 describe-instance-type-offerings` in us-east-1 exist in us-gov-west-1. Restricted NodePool to `c6i`/`m6i` after checking GovCloud instance type documentation.
- **IMDSv2 hop limit**: the default hop limit of 2 allows containers to reach the instance metadata service. Setting it to 1 restricts access to the host network namespace — important in a multi-tenant cluster and required in some GovCloud security baselines.
- **FIPS in GovCloud** *(taken on faith)*: AL2 has a FIPS mode but it is not the default AMI. Whether BEAM's OpenSSL bindings are FIPS-validated depends on the OS-level OpenSSL. I noted the requirement in the EC2NodeClass and GovCloud table but did not verify the full chain — would confirm with the security team before a real FedRAMP deployment.
- **WhenEmpty vs WhenUnderutilized consolidation**: initially planned `WhenUnderutilized`, then worked through the eviction path and realised it would disrupt WebSocket connections. Switched to `WhenEmpty` once I understood that pod eviction (not just rescheduling) is what triggers the drain.
- **AL2 AMIs not available for EKS 1.36+**: the EC2NodeClass initially used `amiFamily: AL2` and `alias: al2@latest`. On a live EKS 1.36.2 cluster the controller logged `failed to discover any AMIs` and the NodeClass went Unknown. AWS stopped publishing AL2 node AMIs beyond k8s 1.32 — AL2023 is required for any cluster running 1.33 or later. Took this on faith from the Karpenter docs; confirmed by the controller log.
- **Karpenter v1 API field changes**: two breaking changes from pre-v1 manifests — `nodeClassRef` changed from an `apiVersion` field to a `group` field, and `expireAfter` moved from `spec.disruption` to `spec.template.spec`. Both failures surfaced as validation errors on install and were fixed by reading the v1 API reference.
