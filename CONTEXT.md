# rentlora-helm — Implementation Context

This file is the full briefing for implementing the `rentlora-helm` repo.
Read this entirely before writing any file.

---

## Implementation Steps (do in this order)

```
Step 1 — Karpenter resources
  karpenter/ec2nodeclass.yaml
  karpenter/nodepool.yaml
  (These define what nodes Karpenter provisions for app pods)

Step 2 — Gateway resources
  gateway/gatewayclass.yaml
  gateway/gateway.yaml        ← needs ACM cert ARN placeholder
  gateway/httproute.yaml      ← routes /* and /api/* to the right services

Step 3 — Helm charts (one per service, repeat pattern 6 times)
  charts/<service>/Chart.yaml
  charts/<service>/values.yaml
  charts/<service>/templates/deployment.yaml
  charts/<service>/templates/service.yaml
  charts/<service>/templates/serviceaccount.yaml
  charts/<service>/templates/configmap.yaml   (backend services only)
  charts/<service>/templates/hpa.yaml         (backend services only)

  Order: frontend → property-service → booking-service →
         ai-service → admin-service → ai-search-service

Step 4 — Environment values
  environments/dev/values.yaml    ← IRSA ARNs, ACM cert ARN, image tags, namespace
  environments/prod/values.yaml   ← same but prod values

Step 5 — ArgoCD ApplicationSet
  argocd/app-of-apps.yaml         ← points ArgoCD at all 6 charts

Step 6 — rentlora Bucket B (in the rentlora code repo, not this repo)
  Delete: .github/workflows/deploy.yml (old EC2)
  Delete: .github/workflows/terraform.yml (old EC2 terraform)
  Delete: infra/terraform/ directory
  Write:  .github/workflows/build.yml (lint→test→Trivy→ECR push→bump helm tag here)
  Write:  .github/workflows/deploy.yml (new — kubectl rollout verify)
```

### Verification after each step

After Step 2 (gateway):
```bash
kubectl apply -f gateway/
kubectl get gatewayclass          # kgateway present
kubectl get gateway -n rentlora-dev  # address field populated (NLB DNS)
```

After Step 3+4 (charts deployed via ArgoCD):
```bash
kubectl get pods -n rentlora-dev         # all 6 services Running
kubectl get hpa -n rentlora-dev          # HPA attached
kubectl logs -n rentlora-dev <pod>       # no startup errors
curl https://dev.rentlora.in/healthz     # frontend responds
curl https://dev.rentlora.in/api/properties  # property-service responds
```

After Step 5 (ArgoCD):
```bash
kubectl get applications -n argocd       # 6 apps, all Synced + Healthy
argocd app list                          # same
```

---

## Project Summary

Rentlora is a rental marketplace (Airbnb-style) being migrated from EC2/ASG to Amazon EKS.
There are 3 repos:

| Repo | Status | Purpose |
|------|--------|---------|
| `rentlora` | ✅ Done (Bucket A) | App code — 5 FastAPI services + React frontend |
| `rentlora-infra` | ✅ Done | Terraform — VPC, EKS, RDS, SQS, ECR, IRSA, SSM, Route53, ACM |
| `rentlora-helm` | 🔜 This repo | Helm charts + ArgoCD + kgateway resources |

---

## Architecture

```
Internet (HTTPS :443)
   │
   ▼
Route53 (rentlora.in) ──► NLB (ACM cert terminates TLS here)
                               │ HTTP
                               ▼
                          kgateway (Envoy, in-cluster)
                               │
                  ┌────────────┴──────────────────┐
                  ▼                               ▼
          /* → frontend:8080          /api/* → backend services
                                      (property:8001, booking:8002,
                                       ai:8003, admin:8004, ai-search:8005)
```

- **kgateway** is the edge router (Gateway API spec, not Ingress)
- **ArgoCD** watches this repo and auto-deploys when image tags change (GitOps)
- **Karpenter** auto-provisions EC2 nodes for app pods
- **IRSA**: each service's ServiceAccount is annotated with an IAM role ARN — apps call AWS APIs directly, no K8s Secrets

---

## The 6 Services

| Service | Image | Port | Has DB | AWS Services Used |
|---------|-------|------|--------|------------------|
| frontend | `rentlora-frontend` | 8080 | No | — |
| property-service | `rentlora-property-service` | 8001 | Yes (PostgreSQL) | SQS (send), S3, Secrets Manager, SSM |
| booking-service | `rentlora-booking-service` | 8002 | Yes (PostgreSQL) | SQS (send FIFO), SES, SNS, Secrets Manager, SSM |
| ai-service | `rentlora-ai-service` | 8003 | No | Bedrock (Nova Lite + Titan), SSM |
| admin-service | `rentlora-admin-service` | 8004 | Yes (PostgreSQL) | Secrets Manager, SSM |
| ai-search-service | `rentlora-ai-search-service` | 8005 | Yes (PostgreSQL + pgvector) | SQS (receive), Bedrock (Titan), Secrets Manager, SSM |

**Health endpoints (on all backend services):**
- `GET /healthz` → `{"status":"ok"}` — liveness probe (cheap, no dependencies)
- `GET /ready` → `{"status":"ready"}` or HTTP 503 — readiness probe (DB-backed services ping DB)

**Frontend health:** nginx liveness is just TCP check on port 8080.

---

## Locked Decisions

| Decision | Choice |
|----------|--------|
| Edge router | kgateway (Gateway API `HTTPRoute`) |
| TLS | ACM on NLB — annotation on Gateway Service with ACM cert ARN |
| Node autoscaling | Karpenter NodePool (app workloads); bootstrap node group for system pods only |
| GitOps | ArgoCD ApplicationSet watching `rentlora-helm` main branch |
| Secrets | Apps fetch Secrets Manager at startup via IRSA — NO K8s Secret objects |
| K8s config | ConfigMap only: `ENV` + `AWS_DEFAULT_REGION` per service |
| Namespaces | `rentlora-dev` (dev) and `production` (prod) |
| Replicas | 2 minimum per service (HA), HPA max 6 |
| Security | `runAsNonRoot: true`, `runAsUser: 1000`, `readOnlyRootFilesystem: false` |

---

## What This Repo Must Contain

```
rentlora-helm/
├── charts/
│   ├── frontend/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── service.yaml          # ClusterIP
│   │       └── serviceaccount.yaml   # no IRSA annotation needed for frontend
│   ├── property-service/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── serviceaccount.yaml   # annotated with IRSA role ARN
│   │       ├── configmap.yaml        # ENV + AWS_DEFAULT_REGION
│   │       └── hpa.yaml
│   ├── booking-service/    (same structure as property-service)
│   ├── ai-service/         (same structure)
│   ├── admin-service/      (same structure)
│   └── ai-search-service/  (same structure)
│
├── gateway/
│   ├── gatewayclass.yaml   # kgateway GatewayClass
│   ├── gateway.yaml        # Gateway resource → triggers NLB creation
│   └── httproute.yaml      # /* → frontend, /api/* → backends
│
├── karpenter/
│   ├── nodepool.yaml       # NodePool (instance types, limits, disruption)
│   └── ec2nodeclass.yaml   # EC2NodeClass (AMI, subnet selector, SG selector)
│
├── argocd/
│   └── app-of-apps.yaml    # ArgoCD ApplicationSet for all 6 charts
│
└── environments/
    ├── dev/
    │   └── values.yaml     # dev image tags, replicas, IRSA ARNs, namespace
    └── prod/
        └── values.yaml     # prod image tags, replicas, IRSA ARNs, namespace
```

---

## Values Structure (per chart)

Each chart's `values.yaml` should have this shape:

```yaml
image:
  repository: <ecr-account>.dkr.ecr.us-east-1.amazonaws.com/rentlora-<service>
  tag: "latest"
  pullPolicy: IfNotPresent

replicaCount: 2

service:
  port: 8001   # varies per service

env:
  ENV: "dev"
  AWS_DEFAULT_REGION: "us-east-1"

irsa:
  roleArn: ""   # filled in by environment values.yaml

resources:
  requests:
    cpu: "100m"
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"

hpa:
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70
```

---

## Environment Values (`environments/dev/values.yaml`)

This file overrides chart defaults for the dev environment.
It must set the IRSA role ARNs from the `rentlora-infra` Terraform outputs.

```yaml
# environments/dev/values.yaml
global:
  namespace: rentlora-dev
  env: dev
  region: us-east-1
  imageTag: latest

# IRSA role ARNs — from: terraform output -json irsa_role_arns (stacks/dev)
irsaRoleArns:
  property-service:   "arn:aws:iam::<ACCOUNT>:role/rentlora-eks-dev-property-service"
  booking-service:    "arn:aws:iam::<ACCOUNT>:role/rentlora-eks-dev-booking-service"
  ai-service:         "arn:aws:iam::<ACCOUNT>:role/rentlora-eks-dev-ai-service"
  admin-service:      "arn:aws:iam::<ACCOUNT>:role/rentlora-eks-dev-admin-service"
  ai-search-service:  "arn:aws:iam::<ACCOUNT>:role/rentlora-eks-dev-ai-search-service"

# ACM cert ARN — from: terraform output acm_cert_arn (stacks/cluster)
acmCertArn: "arn:aws:acm:us-east-1:<ACCOUNT>:certificate/<ID>"
```

---

## Gateway Resources Detail

### `gateway/gatewayclass.yaml`
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: kgateway
spec:
  controllerName: kgateway.io/kgateway
```

### `gateway/gateway.yaml`
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: rentlora-gateway
  namespace: rentlora-dev   # or production
  annotations:
    # These annotations make the AWS LB Controller provision an NLB with HTTPS
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "<ACM_CERT_ARN>"
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
    external-dns.alpha.kubernetes.io/hostname: "rentlora.in,dev.rentlora.in"
spec:
  gatewayClassName: kgateway
  listeners:
    - name: http
      port: 80
      protocol: HTTP
```

### `gateway/httproute.yaml`
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rentlora-routes
  namespace: rentlora-dev
spec:
  parentRefs:
    - name: rentlora-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: property-service
          port: 8001
        # ... other backend services by path prefix
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend
          port: 8080
```

---

## Karpenter Resources Detail

### `karpenter/ec2nodeclass.yaml`
```yaml
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  role: "rentlora-eks-karpenter-node"   # from infra output: karpenter_node_instance_profile
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "rentlora-eks"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "rentlora-eks"
```

### `karpenter/nodepool.yaml`
```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.medium", "t3.large", "t3a.medium", "t3a.large"]
  limits:
    cpu: 16
    memory: 64Gi
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30s
```

---

## ArgoCD ApplicationSet

`argocd/app-of-apps.yaml` — one ApplicationSet that generates an Application per chart:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: rentlora
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - chart: frontend
          - chart: property-service
          - chart: booking-service
          - chart: ai-service
          - chart: admin-service
          - chart: ai-search-service
  template:
    metadata:
      name: "rentlora-{{chart}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/rentlora/rentlora-helm
        targetRevision: main
        path: charts/{{chart}}
        helm:
          valueFiles:
            - ../../environments/dev/values.yaml   # or prod
      destination:
        server: https://kubernetes.default.svc
        namespace: rentlora-dev   # or production
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

---

## Deployment Template Pattern

All 5 backend service Deployments follow this pattern:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.serviceName }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.serviceName }}
  template:
    metadata:
      labels:
        app: {{ .Values.serviceName }}
    spec:
      serviceAccountName: {{ .Values.serviceName }}
      containers:
        - name: {{ .Values.serviceName }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: {{ .Values.service.port }}
          envFrom:
            - configMapRef:
                name: {{ .Values.serviceName }}-config
          livenessProbe:
            httpGet:
              path: /healthz
              port: {{ .Values.service.port }}
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /ready
              port: {{ .Values.service.port }}
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 3
          resources: {{ .Values.resources | toYaml | nindent 12 }}
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
```

**Frontend Deployment** differs:
- Uses port 8080
- Liveness probe: TCP socket on port 8080 (nginx, no `/healthz`)
- No ConfigMap needed (no ENV/AWS vars)
- No IRSA annotation on ServiceAccount

---

## ServiceAccount Template Pattern

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.serviceName }}
  namespace: {{ .Release.Namespace }}
  annotations:
    eks.amazonaws.com/role-arn: {{ .Values.irsa.roleArn }}
```

Frontend ServiceAccount has no annotation (no AWS access needed).

---

## ConfigMap Template Pattern

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Values.serviceName }}-config
data:
  ENV: {{ .Values.env.ENV | quote }}
  AWS_DEFAULT_REGION: {{ .Values.env.AWS_DEFAULT_REGION | quote }}
```

This is the ONLY K8s config needed. Apps read all other config (DB endpoint, SQS URLs, model IDs, etc.) from SSM Parameter Store at startup using their IRSA identity.

---

## HPA Template Pattern

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .Values.serviceName }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ .Values.serviceName }}
  minReplicas: {{ .Values.hpa.minReplicas }}
  maxReplicas: {{ .Values.hpa.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.hpa.targetCPUUtilizationPercentage }}
```

---

## ECR Image URLs

After `terraform output` from `stacks/cluster`:

```
<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/rentlora-frontend
<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/rentlora-property-service
<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/rentlora-booking-service
<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/rentlora-ai-service
<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/rentlora-admin-service
<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/rentlora-ai-search-service
```

Image tags are bumped by the `build.yml` GitHub Actions workflow in the `rentlora` repo
(not this repo). The workflow commits a new `image.tag` value to `environments/dev/values.yaml`
in this repo, which triggers ArgoCD to deploy.

---

## What Comes AFTER rentlora-helm

Once this repo is complete, the final step is **`rentlora` Bucket B**:

1. **New GitHub Actions in `rentlora` repo:**
   - `build.yml`: on push to main →
     1. `ruff check` (lint)
     2. `pytest` (smoke tests)
     3. `docker build` for changed services
     4. Trivy image scan
     5. Push to ECR
     6. `git commit` to `rentlora-helm` bumping `environments/dev/values.yaml` image tags
   - `deploy.yml`: after ArgoCD sync → `kubectl rollout status` verify

2. **Delete from `rentlora` repo:**
   - `.github/workflows/deploy.yml` (old EC2/SSM deploy)
   - `.github/workflows/terraform.yml` (old EC2 terraform workflow)
   - `infra/terraform/` directory (moves to `rentlora-infra`)

---

## Infra Values To Fill In

These placeholders in the Helm values need real values from Terraform outputs:

| Placeholder | Where to get it |
|-------------|----------------|
| `<ACCOUNT_ID>` | `aws sts get-caller-identity --query Account` |
| IRSA role ARNs | `cd rentlora-infra/stacks/dev && terraform output -json irsa_role_arns` |
| ACM cert ARN | `cd rentlora-infra/stacks/cluster && terraform output acm_cert_arn` |
| Karpenter node role | `cd rentlora-infra/stacks/cluster && terraform output karpenter_node_instance_profile` |
| Cluster name | `rentlora-eks` (hardcoded in infra) |
