# TROUBLESHOOTING GUIDE — Banking Platform on Kubernetes

##############################################################################
# PROBLEM 1: Pod stuck in ImagePullBackOff
##############################################################################
# SYMPTOM: kubectl get pods shows ImagePullBackOff or ErrImagePull
# CAUSE: Wrong Docker Hub username in YAML, or Docker Hub credentials missing

# DIAGNOSIS:
kubectl describe pod <pod-name> -n banking
# Look for "Events" section at the bottom — you'll see something like:
#   Failed to pull image "yourdockerhubusername/banking-api:v1.0": 
#   repository does not exist or may require 'docker login'

# FIX 1: Update the image name in your YAML
# Edit k8s/04-api-deployment.yaml and change:
#   image: yourdockerhubusername/banking-api:v1.0
# to:
#   image: realusername/banking-api:v1.0
kubectl apply -f k8s/04-api-deployment.yaml

# FIX 2: Recreate the Docker Hub secret with real credentials
kubectl delete secret dockerhub-secret -n banking
kubectl create secret docker-registry dockerhub-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=REAL_USERNAME \
  --docker-password=REAL_PASSWORD \
  -n banking
# Then restart the deployment to pick up the new secret:
kubectl rollout restart deployment/banking-api -n banking

##############################################################################
# PROBLEM 2: Pod stuck in Pending
##############################################################################
# SYMPTOM: Pod stays in Pending indefinitely
# CAUSE: Node can't schedule the pod (wrong label, taint, insufficient resources)

# DIAGNOSIS:
kubectl describe pod postgres-db-0 -n banking
# Look for Events like:
#   0/1 nodes are available: 1 node(s) had untolerated taint {database-only: true}
#   OR: 0/1 nodes are available: 1 Insufficient memory

# FIX for node label/taint issues:
bash k8s/12-setup-nodes.sh   # Re-run node setup script

# FIX: Verify the label was applied
kubectl get nodes --show-labels | grep high-memory

# FIX: Verify the taint was applied
kubectl describe node <node-name> | grep Taints

# TEMPORARY FIX (for testing only — removes placement constraints):
kubectl patch statefulset postgres-db -n banking --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/affinity"}]'

##############################################################################
# PROBLEM 3: Pod in CrashLoopBackOff
##############################################################################
# SYMPTOM: Pod starts then immediately crashes, repeatedly
# CAUSE: App can't connect to database, or config is wrong

# DIAGNOSIS:
kubectl logs postgres-db-0 -n banking
kubectl logs -l app=banking-api -n banking --previous  # Logs from last crashed run
kubectl describe pod <api-pod> -n banking  # Check Events and probe failures

# Common sub-causes:

# Sub-cause A: DB_HOST wrong in ConfigMap
kubectl get configmap banking-config -n banking -o yaml
# Verify DB_HOST = "postgres-service.banking.svc.cluster.local"
# Fix: kubectl edit configmap banking-config -n banking

# Sub-cause B: Wrong DB password
kubectl get secret banking-secrets -n banking -o yaml
# Decode DB_PASSWORD:
kubectl get secret banking-secrets -n banking -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
# Should print: BankSecurePass2024!
# Must match POSTGRES_PASSWORD in StatefulSet

# Sub-cause C: PostgreSQL not yet initialized (takes 30-90 seconds on first boot)
kubectl logs postgres-db-0 -n banking
# Wait until you see: "database system is ready to accept connections"
# API readiness probe will retry every 10 seconds

##############################################################################
# PROBLEM 4: PVC stuck in Pending (storage not available)
##############################################################################
# DIAGNOSIS:
kubectl get pvc -n banking
kubectl describe pvc postgres-data-postgres-db-0 -n banking

# Check available StorageClasses:
kubectl get storageclass
# If this returns "No resources found", you need to install a StorageClass

# FIX for minikube:
minikube addons enable default-storageclass
minikube addons enable storage-provisioner

# FIX for kind:
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# FIX: Patch PVC to use the available StorageClass
# Edit 03-postgres-statefulset.yaml and add:
#   storageClassName: "standard"  (or "local-path" for kind)
# Then delete the stuck PVC and StatefulSet and reapply:
kubectl delete statefulset postgres-db -n banking --cascade=false
kubectl delete pvc postgres-data-postgres-db-0 -n banking
kubectl apply -f k8s/03-postgres-statefulset.yaml

##############################################################################
# PROBLEM 5: Ingress returns 404 or 503
##############################################################################
# DIAGNOSIS:
kubectl get ingress -n banking
# Check ADDRESS column — should have an IP. If empty, ingress controller isn't ready.

kubectl get pods -n ingress-nginx
# Should see: ingress-nginx-controller-xxx   1/1   Running

# FIX: Install NGINX ingress controller if missing:
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml

# Check routes are working:
kubectl describe ingress banking-ingress -n banking
# Look at "Rules" section — should show your paths

# FIX for 503: Backend pods not ready
kubectl get endpoints banking-api-service -n banking
# If ENDPOINTS shows <none>, the API pods aren't passing readiness probes
# Check: kubectl logs <api-pod> -n banking

##############################################################################
# PROBLEM 6: HPA shows <unknown> for CPU metrics
##############################################################################
# CAUSE: metrics-server not installed or not working

# Check if metrics-server is running:
kubectl get pods -n kube-system | grep metrics-server
kubectl top nodes  # If this fails, metrics-server isn't working

# FIX for local clusters:
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# Wait 2-3 minutes for metrics to be collected:
watch kubectl get hpa -n banking

##############################################################################
# PROBLEM 7: NetworkPolicy blocks all traffic (app broken after applying policies)
##############################################################################
# CAUSE: Applied policies piecemeal, or allow rules missing

# DIAGNOSIS — Check which pods can reach which:
# Test API → Database (should WORK):
API_POD=$(kubectl get pod -n banking -l app=banking-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $API_POD -n banking -- wget -qO- http://localhost:3000/ready
# Should return 200. If timeout, NetworkPolicy is blocking API→DB

# Test Dashboard → Database (should FAIL — security working!):
DASH_POD=$(kubectl get pod -n banking -l app=banking-dashboard -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $DASH_POD -n banking -- sh -c "wget -qO- postgres-service:5432 --timeout=5"
# Should timeout — this is CORRECT behavior

# FIX: Ensure ALL 7 NetworkPolicies are applied together
kubectl delete -f k8s/10-networkpolicy.yaml  # Remove existing
kubectl apply -f k8s/10-networkpolicy.yaml   # Reapply all at once

# Verify:
kubectl get netpol -n banking
# Should show exactly 7 policies

##############################################################################
# USEFUL DEBUG COMMANDS (keep these handy)
##############################################################################

# Get a shell inside any pod for debugging:
kubectl exec -it <pod-name> -n banking -- sh

# Watch pods in real-time:
kubectl get pods -n banking -w

# All recent events (sorted by time):
kubectl get events -n banking --sort-by=.lastTimestamp | tail -20

# Pod resource usage (requires metrics-server):
kubectl top pods -n banking
kubectl top nodes

# Describe everything for a pod:
kubectl describe pod <pod-name> -n banking

# Check logs across all pods with a label:
kubectl logs -l app=banking-api -n banking --all-containers

# Test DNS resolution from inside a pod:
kubectl run test-dns --image=busybox --rm -it -n banking -- nslookup postgres-service.banking.svc.cluster.local

# Port-forward for direct access (bypasses Ingress — useful for debugging):
kubectl port-forward svc/banking-api-service 3000:3000 -n banking
# Then: curl http://localhost:3000/api/accounts

kubectl port-forward svc/banking-dashboard-service 8080:80 -n banking
# Then: open http://localhost:8080 in browser
