# BANKING PLATFORM — COMPLETE EXECUTION GUIDE
# Run commands in this exact order. Read every comment.

##############################################################################
# PRE-FLIGHT: Verify your environment
##############################################################################

# Check kubectl is configured
kubectl cluster-info
# Expected: Shows your cluster's API server URL

# Check available nodes
kubectl get nodes
# Expected: At least 1 node in Ready state
# Example output:
#   NAME           STATUS   ROLES           AGE   VERSION
#   minikube       Ready    control-plane   5d    v1.29.0

##############################################################################
# STEP 0: Install prerequisites
##############################################################################

# ── NGINX Ingress Controller (required for Ingress to work) ───────────────
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml

# Wait for it to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# ── metrics-server (required for HPA) ─────────────────────────────────────
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# For local clusters (minikube/kind) — add --kubelet-insecure-tls flag
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# ── VPA (required for VPA object) ─────────────────────────────────────────
# Install VPA CRDs
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/master/vertical-pod-autoscaler/deploy/vpa-v1-crd-gen.yaml
# Install VPA RBAC
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/master/vertical-pod-autoscaler/deploy/vpa-rbac.yaml

##############################################################################
# STEP 1: Build and push Docker images
##############################################################################

# Replace YOUR_USERNAME with your Docker Hub username everywhere below

# ── Build and push the API image ──────────────────────────────────────────
cd app/banking-api
docker build -t YOUR_USERNAME/banking-api:v1.0 .
docker push YOUR_USERNAME/banking-api:v1.0
cd ../..

# ── Build and push the Dashboard image ───────────────────────────────────
cd app/banking-dashboard
docker build -t YOUR_USERNAME/banking-dashboard:v1.0 .
docker push YOUR_USERNAME/banking-dashboard:v1.0
cd ../..

# ── IMPORTANT: Update your username in YAML files ─────────────────────────
# Replace "yourdockerhubusername" in the deployment files:
sed -i 's/yourdockerhubusername/YOUR_USERNAME/g' k8s/04-api-deployment.yaml
sed -i 's/yourdockerhubusername/YOUR_USERNAME/g' k8s/05-dashboard-deployment.yaml
# On macOS, use: sed -i '' 's/...' instead

# ── Generate Docker Hub Secret properly ───────────────────────────────────
# This is the CORRECT way to create the registry secret:
kubectl create secret docker-registry dockerhub-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=YOUR_USERNAME \
  --docker-password=YOUR_PASSWORD \
  --docker-email=your@email.com \
  -n banking --dry-run=client -o yaml > /tmp/dockerhub-secret.yaml

# Review it, then apply:
cat /tmp/dockerhub-secret.yaml  # verify it looks right
kubectl apply -f /tmp/dockerhub-secret.yaml

##############################################################################
# PHASE 1: Deploy Core Infrastructure ("It Works")
##############################################################################

# 1. Create namespace
kubectl apply -f k8s/00-namespace.yaml
kubectl get namespace banking   # Should show: banking   Active

# 2. Apply ConfigMap
kubectl apply -f k8s/01-configmap.yaml
kubectl get configmap -n banking   # Should list: banking-config

# 3. Apply Secrets
kubectl apply -f k8s/02-secret.yaml
kubectl get secret -n banking
# Expected: banking-secrets, dockerhub-secret (plus default token)

# 4. Setup node (label + taint)
bash k8s/12-setup-nodes.sh
# Expected: Prints the node name, applies label type=high-memory and taint database-only=true:NoSchedule

# Verify node setup:
kubectl get nodes --show-labels | grep high-memory
kubectl describe node <NODE_NAME> | grep -A5 Taints

# 5. Deploy PostgreSQL
kubectl apply -f k8s/03-postgres-statefulset.yaml

# Watch it come up:
kubectl get pods -n banking -w
# Expected: postgres-db-0 goes: Pending → ContainerCreating → Running
# (Takes 30-90 seconds for PostgreSQL to initialize)

# Check PVC is bound:
kubectl get pvc -n banking
# Expected: postgres-data-postgres-db-0   Bound   5Gi

# 6. Deploy Banking API
kubectl apply -f k8s/04-api-deployment.yaml
kubectl rollout status deployment/banking-api -n banking
# Expected: Watches progress, then: "deployment 'banking-api' successfully rolled out"

# 7. Deploy Dashboard
kubectl apply -f k8s/05-dashboard-deployment.yaml
kubectl rollout status deployment/banking-dashboard -n banking

# 8. Apply Services
kubectl apply -f k8s/06-services.yaml
kubectl get svc -n banking
# Expected output:
#   NAME                       TYPE        CLUSTER-IP       PORT(S)
#   banking-api-service        ClusterIP   10.96.x.x        3000/TCP
#   banking-dashboard-service  ClusterIP   10.96.x.x        80/TCP
#   postgres-service           ClusterIP   10.96.x.x        5432/TCP

# ── Phase 1 Verification ──────────────────────────────────────────────────
kubectl get pods -n banking
# ALL pods should be Running with 0 restarts:
#   NAME                                  READY   STATUS    RESTARTS
#   banking-api-xxxxx-xxxxx              1/1     Running   0
#   banking-api-xxxxx-xxxxx              1/1     Running   0
#   banking-dashboard-xxxxx-xxxxx        1/1     Running   0
#   postgres-db-0                         1/1     Running   0

# Test API health endpoint (from inside cluster)
API_POD=$(kubectl get pod -n banking -l app=banking-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $API_POD -n banking -- wget -qO- http://localhost:3000/health
# Expected: {"status":"ok"} or similar 200 response

kubectl exec -it $API_POD -n banking -- wget -qO- http://localhost:3000/api/accounts
# Expected: JSON array (may be empty initially): []

##############################################################################
# PHASE 2: Security ("It Is Secure")
##############################################################################

# 1. Apply Ingress
kubectl apply -f k8s/07-ingress.yaml
kubectl get ingress -n banking
# Expected:
#   NAME              CLASS   HOSTS          ADDRESS   PORTS
#   banking-ingress   nginx   banking.local  x.x.x.x   80

# Add banking.local to your local /etc/hosts:
# Get the Ingress IP first:
kubectl get ingress banking-ingress -n banking -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# Then add to /etc/hosts:
echo "<INGRESS_IP> banking.local" | sudo tee -a /etc/hosts
# For minikube: use "minikube ip" instead of the ingress IP
# For kind: use "127.0.0.1 banking.local"

# Test Ingress routing:
curl http://banking.local/health         # Should return 200 from API
curl http://banking.local/api/accounts  # Should return JSON

# 2. Apply RBAC
kubectl apply -f k8s/09-rbac.yaml

# Verify RBAC (required demo commands):
kubectl auth can-i get pods -n banking --as developer
# Expected: yes

kubectl auth can-i delete pods -n banking --as developer
# Expected: no

kubectl auth can-i get secrets -n banking --as developer
# Expected: no

# 3. Apply NetworkPolicies
kubectl apply -f k8s/10-networkpolicy.yaml
kubectl get netpol -n banking
# Expected: 7 policies listed:
#   default-deny-all-egress
#   default-deny-all-ingress
#   allow-api-egress
#   allow-api-to-postgres
#   allow-fluentd-egress
#   allow-ingress-to-api
#   allow-ingress-to-dashboard

# Test NetworkPolicy — Dashboard CANNOT reach Database:
DASHBOARD_POD=$(kubectl get pod -n banking -l app=banking-dashboard -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $DASHBOARD_POD -n banking -- sh -c "wget -qO- postgres-service:5432 --timeout=5" 2>&1
# Expected: Connection timed out or refused (NetworkPolicy is working!)

# Test that API CAN still reach database (Readiness probe passing proves this):
kubectl get endpoints banking-api-service -n banking
# Expected: Shows pod IPs — means readiness probes are passing (DB is reachable)

##############################################################################
# PHASE 3: Scaling ("It Scales")
##############################################################################

# 1. Apply HPA and VPA
kubectl apply -f k8s/08-hpa-vpa.yaml

kubectl get hpa -n banking
# Expected (CPU% shows <unknown> until metrics-server has data — wait 2-3 minutes):
#   NAME              REFERENCE              TARGETS         MINPODS   MAXPODS   REPLICAS
#   banking-api-hpa   Deployment/banking-api  <unknown>/70%   2         10        2
# After 2-3 minutes:
#   banking-api-hpa   Deployment/banking-api  5%/70%          2         10        2

# Check VPA recommendations (will be empty initially — needs time to collect data):
kubectl describe vpa postgres-vpa -n banking

# 2. Deploy Fluentd
kubectl apply -f k8s/11-daemonset-fluentd.yaml

kubectl get daemonset -n banking
# Expected (DESIRED should equal number of nodes in your cluster):
#   NAME      DESIRED   CURRENT   READY   NODE SELECTOR   AGE
#   fluentd   1         1         1       <none>          30s

# Verify Fluentd runs on EVERY node including the tainted one:
kubectl get pods -n banking -o wide | grep fluentd
# Should see one fluentd pod per node, including the database-only node

# Verify probes on API pods:
kubectl describe pod -l app=banking-api -n banking | grep -A10 "Liveness\|Readiness\|Startup"

# Verify PostgreSQL is on tainted node:
kubectl get pod postgres-db-0 -n banking -o wide
# The NODE column should show the node you tainted

# Verify NO other app pods are on that node:
TAINTED_NODE=$(kubectl get pod postgres-db-0 -n banking -o jsonpath='{.spec.nodeName}')
kubectl get pods -n banking -o wide | grep $TAINTED_NODE
# Should ONLY show postgres-db-0 and fluentd (Fluentd tolerates all taints)

##############################################################################
# PHASE 4: Resilience ("It Survives")
##############################################################################

# ── Test 1: PostgreSQL Data Persistence ───────────────────────────────────

# First, insert some test data:
kubectl exec -it postgres-db-0 -n banking -- psql -U bankuser -d bankingdb -c "
  INSERT INTO accounts (name, balance) VALUES ('Test User', 1000.00);
"

# View current data:
kubectl exec -it postgres-db-0 -n banking -- psql -U bankuser -d bankingdb -c \
  'SELECT * FROM accounts;'
# Note down the data

# Delete the pod:
kubectl delete pod postgres-db-0 -n banking

# Watch it come back automatically (StatefulSet recreates it):
kubectl get pods -n banking -w
# Expected: postgres-db-0 goes Terminating → ContainerCreating → Running
# AND the name is EXACTLY postgres-db-0 (same name — StatefulSet behavior)

# After it's Running, verify data is STILL there:
kubectl exec -it postgres-db-0 -n banking -- psql -U bankuser -d bankingdb -c \
  'SELECT * FROM accounts;'
# Expected: Same data you inserted before — PVC preserved it!

# ── Test 2: Rolling Update with Zero Downtime ─────────────────────────────

# Build and push v1.1 image:
cd app/banking-api
docker build -t YOUR_USERNAME/banking-api:v1.1 .
docker push YOUR_USERNAME/banking-api:v1.1
cd ../..

# Show current image (before update):
kubectl describe deployment banking-api -n banking | grep Image
# Expected: Image: YOUR_USERNAME/banking-api:v1.0

# Perform rolling update:
kubectl set image deployment/banking-api \
  banking-api=YOUR_USERNAME/banking-api:v1.1 \
  -n banking

# Watch the rolling update in real-time:
kubectl rollout status deployment/banking-api -n banking
# Expected: Watches new pods come up and old ones terminate one by one
# Output: "Waiting for deployment 'banking-api' rollout to finish: 1 out of 2 new replicas have been updated..."
#         "deployment 'banking-api' successfully rolled out"

# Verify update succeeded:
kubectl describe deployment banking-api -n banking | grep Image
# Expected: Image: YOUR_USERNAME/banking-api:v1.1

# Show rollout history (required for demo):
kubectl rollout history deployment/banking-api -n banking
# Expected:
#   REVISION  CHANGE-CAUSE
#   1         <none>     ← v1.0
#   2         <none>     ← v1.1

# ── Test 3: Rollback to v1.0 ──────────────────────────────────────────────
kubectl rollout undo deployment/banking-api -n banking
# Expected: deployment.apps/banking-api rolled back

kubectl rollout status deployment/banking-api -n banking
# Expected: "successfully rolled out"

kubectl describe deployment banking-api -n banking | grep Image
# Expected: Image: YOUR_USERNAME/banking-api:v1.0   ← Back to v1.0!

##############################################################################
# COMPLETE DEMO CHECKLIST (run these at demo time)
##############################################################################

echo "=== Demo Commands ==="

# All pods running:
kubectl get pods -n banking

# PVC bound:
kubectl get pvc -n banking

# HPA with CPU%:
kubectl get hpa -n banking

# DaemonSet count matches nodes:
kubectl get daemonset -n banking

# 7 NetworkPolicies:
kubectl get netpol -n banking

# RBAC verification:
kubectl auth can-i get pods -n banking --as developer     # yes
kubectl auth can-i delete pods -n banking --as developer  # no
kubectl auth can-i get secrets -n banking --as developer  # no

echo "=== Browser: Open http://banking.local ==="
