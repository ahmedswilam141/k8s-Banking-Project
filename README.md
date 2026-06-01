# 🏦 Banking Platform on Kubernetes — Complete Solution

## Project Summary
A production-style three-tier banking application deployed on Kubernetes, covering every major K8s object:
Namespace, ConfigMap, Secret, StatefulSet, Deployment, Service, Ingress, HPA, VPA, Role, RoleBinding, ServiceAccount, NetworkPolicy, DaemonSet.

## Folder Structure
```
banking-k8s/
├── README.md                   ← This file
├── COMMANDS.sh                 ← All kubectl commands ordered by phase
├── TROUBLESHOOTING.md          ← Debug guide for common issues
├── deploy.sh                   ← Full automated deployment script
│
├── app/                        ← Application code (provided, do not modify)
│   ├── banking-api/
│   │   ├── app.js
│   │   └── Dockerfile
│   └── banking-dashboard/
│       ├── index.html
│       └── Dockerfile
│
└── k8s/                        ← All Kubernetes YAML files
    ├── 00-namespace.yaml       ← Namespace isolation
    ├── 01-configmap.yaml       ← Non-sensitive config (DB host, port, etc.)
    ├── 02-secret.yaml          ← Sensitive config (DB password, JWT, Docker Hub)
    ├── 03-postgres-statefulset.yaml  ← PostgreSQL with PVC, nodeAffinity, toleration
    ├── 04-api-deployment.yaml  ← Banking API (2 replicas, all 3 probes)
    ├── 05-dashboard-deployment.yaml  ← Dashboard (nginx, 1 replica)
    ├── 06-services.yaml        ← 3 ClusterIP services
    ├── 07-ingress.yaml         ← NGINX Ingress routing
    ├── 08-hpa-vpa.yaml         ← HPA for API, VPA for PostgreSQL
    ├── 09-rbac.yaml            ← ServiceAccounts, Roles, RoleBindings
    ├── 10-networkpolicy.yaml   ← 7 NetworkPolicies (zero-trust)
    ├── 11-daemonset-fluentd.yaml  ← Fluentd log collector (1 pod per node)
    └── 12-setup-nodes.sh       ← Labels and taints the database node
```

## Quick Start
```bash
# 1. Setup prerequisites
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml

# 2. Build and push your images
docker build -t YOUR_USER/banking-api:v1.0 ./app/banking-api
docker push YOUR_USER/banking-api:v1.0
docker build -t YOUR_USER/banking-dashboard:v1.0 ./app/banking-dashboard
docker push YOUR_USER/banking-dashboard:v1.0

# 3. Update username in deployment files
sed -i 's/yourdockerhubusername/YOUR_USER/g' k8s/04-api-deployment.yaml k8s/05-dashboard-deployment.yaml

# 4. Create Docker Hub secret
kubectl apply -f k8s/00-namespace.yaml
kubectl create secret docker-registry dockerhub-secret \
  --docker-username=YOUR_USER --docker-password=YOUR_PASS \
  -n banking

# 5. Deploy everything
bash deploy.sh
```

## Architecture Summary
```
User → Ingress (banking.local)
         ├─── / ──────────────→ Dashboard (nginx, 1 replica)
         └─── /api/* ─────────→ Banking API (Node.js, 2 replicas)
                                      ↓
                               PostgreSQL 15 (StatefulSet)
                               on dedicated tainted node
                               with 5Gi PVC (data persists)

Security layers:
  - NetworkPolicy: deny-all + 7 explicit allow rules
  - RBAC: 3 roles, 2 ServiceAccounts
  - SecurityContext: all containers non-root, read-only root FS
  - Secrets: DB password + JWT stored in K8s Secrets

Observability:
  - Fluentd DaemonSet: 1 pod per node (including tainted DB node)
  - HPA: auto-scales API between 2-10 replicas on CPU > 70%
  - VPA: recommends right-sized resources for PostgreSQL
  - All 3 probes on API: Startup, Readiness, Liveness
```

## Demo Commands (15 minutes)
See COMMANDS.sh for complete ordered list.

## Common Issues
See TROUBLESHOOTING.md for fixes.
