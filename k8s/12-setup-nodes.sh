#!/bin/bash
# 12-setup-nodes.sh
# WHY: Run this ONCE before deploying PostgreSQL.
# This script labels and taints one node so that:
#   - PostgreSQL runs exclusively on this high-memory, dedicated node
#   - No other pods accidentally land on the database node
#
# WHAT IT DOES:
#   1. Picks the first available node (or you specify one)
#   2. Adds label:  type=high-memory
#   3. Adds taint:  database-only=true:NoSchedule
#
# The PostgreSQL StatefulSet in 03-postgres-statefulset.yaml has:
#   - nodeAffinity: requires type=high-memory label
#   - toleration: allows running on database-only=true:NoSchedule tainted nodes
#
# USAGE:
#   bash k8s/12-setup-nodes.sh              # Auto-picks first node
#   bash k8s/12-setup-nodes.sh <node-name>  # Use specific node

set -e   # Exit immediately if any command fails

echo "============================================"
echo " Banking Platform — Node Setup Script"
echo "============================================"
echo ""

# ── STEP 1: Determine which node to use ──────────────────────────────────
if [ -n "$1" ]; then
    # Node name provided as argument
    TARGET_NODE="$1"
    echo "✓ Using specified node: $TARGET_NODE"
else
    # Auto-pick the first worker node (not the control-plane)
    TARGET_NODE=$(kubectl get nodes --no-headers \
        -o custom-columns="NAME:.metadata.name,ROLE:.metadata.labels.node-role\.kubernetes\.io/control-plane" \
        | grep '<none>' | head -1 | awk '{print $1}')
    
    # Fallback: if all nodes show <none> for role (common in single-node setups), just pick the first node
    if [ -z "$TARGET_NODE" ]; then
        TARGET_NODE=$(kubectl get nodes --no-headers -o custom-columns="NAME:.metadata.name" | head -1)
    fi
    
    echo "✓ Auto-selected node: $TARGET_NODE"
fi

# ── STEP 2: Verify the node exists ───────────────────────────────────────
if ! kubectl get node "$TARGET_NODE" &>/dev/null; then
    echo "❌ ERROR: Node '$TARGET_NODE' not found in cluster!"
    echo "   Available nodes:"
    kubectl get nodes --no-headers -o custom-columns="NAME:.metadata.name"
    exit 1
fi

echo ""
echo "Current node state:"
kubectl get node "$TARGET_NODE" --show-labels
echo ""

# ── STEP 3: Apply the label ───────────────────────────────────────────────
echo "📌 Labeling node with type=high-memory..."
kubectl label node "$TARGET_NODE" type=high-memory --overwrite
echo "   ✓ Label applied"

# ── STEP 4: Apply the taint ───────────────────────────────────────────────
echo ""
echo "🔒 Tainting node with database-only=true:NoSchedule..."
kubectl taint nodes "$TARGET_NODE" database-only=true:NoSchedule --overwrite
echo "   ✓ Taint applied"
echo ""
echo "   Effect: Only pods with the matching toleration can schedule here."
echo "   The PostgreSQL StatefulSet has this toleration — all other pods do NOT."

# ── STEP 5: Verify the result ─────────────────────────────────────────────
echo ""
echo "============================================"
echo " Verification"
echo "============================================"
echo ""
echo "Node labels:"
kubectl get node "$TARGET_NODE" -o jsonpath='{.metadata.labels}' | python3 -m json.tool 2>/dev/null \
    || kubectl get node "$TARGET_NODE" --show-labels | tail -1
echo ""
echo "Node taints:"
kubectl get node "$TARGET_NODE" -o jsonpath='{.spec.taints}' 2>/dev/null
echo ""
echo ""
echo "✅ Node setup complete!"
echo ""
echo "Next steps:"
echo "  1. Apply PostgreSQL: kubectl apply -f k8s/03-postgres-statefulset.yaml"
echo "  2. Verify placement: kubectl get pod postgres-db-0 -n banking -o wide"
echo "  3. Confirm no other pods on this node:"
echo "     kubectl get pods -n banking -o wide | grep $TARGET_NODE"
