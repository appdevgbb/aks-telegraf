#!/bin/bash
# Script to label nodes for co-scheduling test workloads

NODE_NAME=${1:-""}

if [ -z "$NODE_NAME" ]; then
    echo "❌ Usage: $0 <node-name>"
    echo ""
    echo "Available nodes:"
    kubectl get nodes --no-headers | awk '{print "  - " $1}'
    echo ""
    echo "Example: $0 aks-armnp-38629262-vmss000000"
    exit 1
fi

echo "🏷️ Labeling node '$NODE_NAME' for web-arm workloads..."

# Add the dedicated label for web-arm workloads
kubectl label node $NODE_NAME dedicated=web-arm

if [ $? -eq 0 ]; then
    echo "✅ Successfully labeled node '$NODE_NAME'"
    echo ""
    echo "📋 Node labels:"
    kubectl get node $NODE_NAME --show-labels | grep test-node
    echo ""
    echo "🚀 You can now deploy test workloads that will be co-scheduled on this node:"
    echo "   kubectl apply -f blob-upload-test.yaml"
    echo "   kubectl apply -f pod-web.yaml"
else
    echo "❌ Failed to label node '$NODE_NAME'"
    exit 1
fi
