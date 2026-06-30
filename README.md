# rentlora-helm

> Helm charts and GitOps configuration for the Rentlora platform — all Kubernetes workloads reconciled by Argo CD.

![Helm](https://img.shields.io/badge/Helm-3-0F1689?logo=helm&logoColor=white)
![ArgoCD](https://img.shields.io/badge/Argo-CD-EF7B4D?logo=argo&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-EKS-326CE5?logo=kubernetes&logoColor=white)
![kgateway](https://img.shields.io/badge/Gateway-kgateway-6E40C9)
![Karpenter](https://img.shields.io/badge/Autoscaling-Karpenter-FF9900)

---

## Overview

`rentlora-helm` is the GitOps source of truth for all Kubernetes workloads in the Rentlora platform. Argo CD watches this repository and automatically reconciles any chart change to the cluster — pushing a new image tag here triggers a zero-touch rollout. The repo contains Helm charts for all six services, Gateway API resources (kgateway/Envoy), Karpenter node configuration, and environment-specific value overrides.

---

## Repository Layout

```
rentlora-helm/
├── charts/
│   ├── frontend/               # React + Nginx — port 8080
│   ├── property-service/       # Listing catalog — port 8001
│   ├── booking-service/        # Reservations — port 8002
│   ├── ai-service/             # Bedrock AI gateway — port 8003
│   ├── admin-service/          # Back-office — port 8004
│   ├── ai-search-service/      # Vector semantic search — port 8005
│   └── user-service/           # Auth + accounts — port 8006
│
├── gateway/
│   ├── gatewayclass.yaml       # kgateway GatewayClass (Envoy-based)
│   ├── gateway.yaml            # Gateway resource → triggers NLB provisioning
│   └── httproute.yaml          # /* → frontend, /api/* → backend services
│
├── karpenter/
│   ├── nodepool.yaml           # NodePool — instance types, limits, disruption policy
│   └── ec2nodeclass.yaml       # EC2NodeClass — AMI family, subnet/SG selectors
│
├── argocd/
│   └── app-of-apps.yaml        # ApplicationSet — generates one Argo CD Application per chart
│
└── environments/
    ├── dev/
    │   └── values.yaml         # Dev: IRSA ARNs, ACM cert ARN, image tags, namespace
    └── prod/
        └── values.yaml         # Prod: same shape, production values
```

---

## Architecture

```
Internet (HTTPS :443)
        │
        ▼
Route53 (rentlora.in)  ──▶  NLB (ACM TLS termination)
                                    │ HTTP
                                    ▼
                             kgateway (Envoy)
                                    │
                    ┌───────────────┴────────────────────┐
                    ▼                                    ▼
            /* → frontend:8080          /api/* → backend services
                                        ├── property-service:8001
                                        ├── booking-service:8002
                                        ├── ai-service:8003
                                        ├── admin-service:8004
                                        ├── ai-search-service:8005
                                        └── user-service:8006
```

---

## Services

| Chart | Image | Port | Has DB | Key AWS Services |
|---|---|---|---|---|
| `frontend` | `rentlora-frontend` | 8080 | No | — |
| `property-service` | `rentlora-property-service` | 8001 | Yes | SQS, S3, Secrets Manager, SSM |
| `booking-service` | `rentlora-booking-service` | 8002 | Yes | SQS, SES, SNS, Secrets Manager, SSM |
| `ai-service` | `rentlora-ai-service` | 8003 | No | Bedrock, SSM |
| `admin-service` | `rentlora-admin-service` | 8004 | Yes | Secrets Manager, SSM |
| `ai-search-service` | `rentlora-ai-search-service` | 8005 | Yes (pgvector) | SQS, Bedrock, Secrets Manager, SSM |
| `user-service` | `rentlora-user-service` | 8006 | Yes | SES, Secrets Manager, SSM |

---

## GitOps Delivery Model

```
Developer merges PR to rentlora repo
              │
              ▼
GitHub Actions (build.yml)
  ├── Lint, test, Trivy scan
  ├── Build + push to ECR
  └── Commit image tag bump → rentlora-helm/environments/dev/values.yaml
                    │
                    ▼
         Argo CD detects commit
                    │
                    ▼
         helm upgrade (all affected charts)
                    │
                    ▼
         kubectl rollout verified (deploy.yml)
```

No manual `kubectl` commands are needed for deployments — all cluster state flows through this repository.

---

## Key Design Decisions

| Decision | Choice |
|---|---|
| Edge router | kgateway (Gateway API `HTTPRoute`) — not classic Ingress |
| TLS | ACM certificate on the NLB — annotation on the Gateway Service |
| Node autoscaling | Karpenter NodePool (spot + on-demand); bootstrap node group for system pods only |
| GitOps | Argo CD ApplicationSet — one Application per chart, automated prune + self-heal |
| Secrets | Apps fetch AWS Secrets Manager at startup via IRSA — **no K8s Secret objects** |
| K8s config | ConfigMap only: `ENV` + `AWS_DEFAULT_REGION` per service |
| Namespaces | `rentlora-dev` (dev) and `production` (prod) |
| Replicas | 2 minimum per service (HA), HPA max 6, target 70% CPU |
| Pod security | `runAsNonRoot: true`, `runAsUser: 1000`, `allowPrivilegeEscalation: false` |

---

## Helm Chart Structure

Each backend service chart follows this layout:

```
charts/<service>/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── deployment.yaml       # Deployment with liveness/readiness probes + resource limits
    ├── service.yaml          # ClusterIP service
    ├── serviceaccount.yaml   # Annotated with IRSA role ARN
    ├── configmap.yaml        # ENV + AWS_DEFAULT_REGION only
    └── hpa.yaml              # HorizontalPodAutoscaler (min 2 / max 6)
```

The frontend chart omits `configmap.yaml` and `hpa.yaml`, and its ServiceAccount carries no IRSA annotation.

---

## Health Probes

All backend services expose two health endpoints:

| Probe | Path | Behaviour |
|---|---|---|
| Liveness | `GET /healthz` | Returns `{"status":"ok"}` — fast, no dependencies checked |
| Readiness | `GET /ready` | Checks DB connectivity; returns HTTP 503 if unavailable |

Frontend uses a TCP liveness check on port 8080.

---

## Environment Values

`environments/{env}/values.yaml` overrides chart defaults per environment. Key values to fill in after `terraform output`:

```yaml
global:
  namespace: rentlora-dev
  env: dev
  region: us-east-1
  imageTag: latest

irsaRoleArns:
  property-service:  "arn:aws:iam::<ACCOUNT>:role/rentlora-eks-dev-property-service"
  booking-service:   "arn:aws:iam::<ACCOUNT>:role/rentlora-eks-dev-booking-service"
  ai-service:        "arn:aws:iam::<ACCOUNT>:role/rentlora-eks-dev-ai-service"
  admin-service:     "arn:aws:iam::<ACCOUNT>:role/rentlora-eks-dev-admin-service"
  ai-search-service: "arn:aws:iam::<ACCOUNT>:role/rentlora-eks-dev-ai-search-service"
  user-service:      "arn:aws:iam::<ACCOUNT>:role/rentlora-eks-dev-user-service"

acmCertArn: "arn:aws:acm:us-east-1:<ACCOUNT>:certificate/<ID>"
```

Get these values from Terraform outputs:

```bash
cd rentlora-infra/stacks/dev && terraform output -json irsa_role_arns
cd rentlora-infra/stacks/cluster && terraform output acm_cert_arn
```

---

## Verification

After deploying with Argo CD:

```bash
# All pods running
kubectl get pods -n rentlora-dev

# HPAs attached
kubectl get hpa -n rentlora-dev

# All Argo CD applications synced and healthy
kubectl get applications -n argocd

# Smoke test
curl https://dev.rentlora.in/healthz
curl https://dev.rentlora.in/api/properties
```

---

## Project Context

This repository is part of the Rentlora microservices platform:

| Repository | Role |
|---|---|
| [`rentlora`](../rentlora) | Application source — all services + frontend |
| [`rentlora-infra`](../rentlora-infra) | Terraform — AWS infrastructure |
| **`rentlora-helm`** (this repo) | Helm charts + Argo CD GitOps |
