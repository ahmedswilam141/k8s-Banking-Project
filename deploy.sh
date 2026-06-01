#!/bin/bash
# deploy.sh
# Full automated deployment script for the Banking Platform
# Run this after building and pushing your Docker images.
#
# PREREQUISITES:
#   1. kubectl configured to point at your cluster
#   2. Docker images built and pushed to Docker Hub
#   3. NGINX Ingress Controller installed
#   4. metrics-server installed (for HPA)
#
# USAGE:
#   bash deploy.sh                    # Deploy all phases
#   bash deploy.sh --phase1           # Deploy only Phase 1
#   bash deploy.sh --phase2           # Deploy Phases 1+2
#   bash deploy.sh --skip-node-setup  # Skip node label/taint step

set -e

# ── COLORS FOR OUTPUT ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}   Banking Platform — Full Deployment${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ── PARSE ARGUMENTS ───────────────────────────────────────────────────────
PHASE_LIMIT=4
SKIP_NODE_SETUP=false

for arg in "$@"; do
    case $arg in
        --phase1) PHASE_LIMIT=1 ;;
        --phase2) PHASE_LIMIT=2 ;;
        --phase3) PHASE_LIMIT=3 ;;
        --skip-node-setup) SKIP_NODE_SETUP=true ;;
    esac
done

# ── VERIFY kubectl IS CONFIGURED ─────────────────────────────────────────
if ! kubectl cluster-info &>/dev/null; then
    log_error "kubectl cannot connect to a cluster. Check your kubeconfig."
    exit 1
fi
log_success "kubectl connected to: $(kubectl config current-context)"

# ── PHASE 1: Core Infrastructure ─────────────────────────────────────────
echo ""
echo -e "${YELLOW}=== PHASE 1: It Works ===${NC}"

log_info "Creating namespace..."
kubectl apply -f k8s/00-namespace.yaml
log_success "Namespace 'banking' ready"

log_info "Applying ConfigMap..."
kubectl apply -f k8s/01-configmap.yaml
log_success "ConfigMap applied"

log_info "Applying Secrets..."
kubectl apply -f k8s/02-secret.yaml
log_success "Secrets applied"

# Node setup (must happen before StatefulSet)
if [ "$SKIP_NODE_SETUP" = false ]; then
    log_info "Setting up node labels and taints..."
    bash k8s/12-setup-nodes.sh
else
    log_warn "Skipping node setup (--skip-node-setup flag)"
fi

log_info "Deploying PostgreSQL StatefulSet..."
kubectl apply -f k8s/03-postgres-statefulset.yaml

log_info "Waiting for PostgreSQL to be ready (this can take 60-90 seconds on first run)..."
kubectl wait --for=condition=ready pod/postgres-db-0 -n banking --timeout=180s \
    || log_warn "Postgres not ready yet — it may still be initializing. Check: kubectl logs postgres-db-0 -n banking"

log_info "Deploying Banking API..."
kubectl apply -f k8s/04-api-deployment.yaml

log_info "Deploying Dashboard..."
kubectl apply -f k8s/05-dashboard-deployment.yaml

log_info "Applying Services..."
kubectl apply -f k8s/06-services.yaml

log_info "Waiting for API pods to be ready..."
kubectl rollout status deployment/banking-api -n banking --timeout=120s
log_success "Banking API is running"

kubectl rollout status deployment/banking-dashboard -n banking --timeout=120s
log_success "Dashboard is running"

echo ""
log_success "Phase 1 complete! Verifying..."
kubectl get pods -n banking
echo ""

if [ "$PHASE_LIMIT" -le 1 ]; then
    echo "Stopped at Phase 1. Run without --phase1 to continue."
    exit 0
fi

# ── PHASE 2: Security ─────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}=== PHASE 2: It Is Secure ===${NC}"

log_info "Applying Ingress..."
kubectl apply -f k8s/07-ingress.yaml
log_success "Ingress applied — banking.local should route traffic"

log_info "Applying RBAC..."
kubectl apply -f k8s/09-rbac.yaml
log_success "RBAC applied"

log_info "Applying NetworkPolicies..."
kubectl apply -f k8s/10-networkpolicy.yaml
log_success "7 NetworkPolicies applied"

echo ""
log_info "Verifying RBAC:"
echo -n "  developer can get pods:    "
kubectl auth can-i get pods -n banking --as developer
echo -n "  developer can delete pods: "
kubectl auth can-i delete pods -n banking --as developer
echo -n "  developer can get secrets: "
kubectl auth can-i get secrets -n banking --as developer

echo ""
log_info "Verifying NetworkPolicies:"
kubectl get netpol -n banking

if [ "$PHASE_LIMIT" -le 2 ]; then
    echo "Stopped at Phase 2."
    exit 0
fi

# ── PHASE 3: Scaling ──────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}=== PHASE 3: It Scales ===${NC}"

log_info "Applying HPA and VPA..."
kubectl apply -f k8s/08-hpa-vpa.yaml
log_success "HPA and VPA applied"

log_info "Deploying Fluentd DaemonSet..."
kubectl apply -f k8s/11-daemonset-fluentd.yaml
log_success "Fluentd DaemonSet applied"

echo ""
log_info "HPA status (CPU% may show <unknown> until metrics-server collects data):"
kubectl get hpa -n banking

log_info "DaemonSet status:"
kubectl get daemonset -n banking

echo ""
log_info "Verifying PostgreSQL is on the tainted node:"
kubectl get pod postgres-db-0 -n banking -o wide

if [ "$PHASE_LIMIT" -le 3 ]; then
    echo "Stopped at Phase 3."
    exit 0
fi

# ── PHASE 4: Resilience ───────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}=== PHASE 4: It Survives ===${NC}"
log_info "Phase 4 requires manual steps:"
echo "  1. Delete and verify postgres recovery:"
echo "     kubectl delete pod postgres-db-0 -n banking"
echo "     kubectl get pods -n banking -w"
echo ""
echo "  2. Rolling update (after building v1.1 image):"
echo "     kubectl set image deployment/banking-api banking-api=<your_user>/banking-api:v1.1 -n banking"
echo "     kubectl rollout status deployment/banking-api -n banking"
echo "     kubectl rollout history deployment/banking-api -n banking"
echo "     kubectl rollout undo deployment/banking-api -n banking"

# ── FINAL SUMMARY ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   Deployment Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "All pods:"
kubectl get pods -n banking -o wide
echo ""
echo "All services:"
kubectl get svc -n banking
echo ""
echo "PVCs:"
kubectl get pvc -n banking
echo ""
echo -e "Open your browser at: ${BLUE}http://banking.local${NC}"
echo "(Make sure banking.local resolves to your cluster's Ingress IP)"
echo ""
echo "Quick health check:"
INGRESS_IP=$(kubectl get ingress banking-ingress -n banking -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")
echo "  Ingress IP: $INGRESS_IP"
echo "  curl -H 'Host: banking.local' http://$INGRESS_IP/health"
