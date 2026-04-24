#!/bin/bash
# [ignoring loop detection]

# --- Configuration ---
NAMESPACE="rentlora"
HELM_DIR="./"
# Label for the namespace (e.g., for Istio or simple tracking)
NS_LABEL="environment=dev"

SERVICES=(
  "rentlora-ai-service"
  "rentlora-booking-service"
  "rentlora-payment-service"
  "rentlora-property-service"
  "rentlora-user-service"
  "rentlora-ui"
)

echo "----------------------------------------------------"
echo "🌐 Preparing Namespace: $NAMESPACE"
echo "----------------------------------------------------"

# 1. Create and Label Namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" "$NS_LABEL" --overwrite

echo "📦 Deploying Infrastructure..."
# 2. Deploy MongoDB and Gateway
helm upgrade --install mongodb "$HELM_DIR/mongodb" -n "$NAMESPACE" --wait
helm upgrade --install kgateway "$HELM_DIR/kgateway" -n "$NAMESPACE" --wait

echo "🚀 Deploying Microservices..."
# 3. Deploy all services in a loop
for svc in "${SERVICES[@]}"; do
  echo "Installing $svc..."
  # Uses values-dev.yaml by default for EC2 testing
  helm upgrade --install "$svc" "$HELM_DIR/$svc" \
    -f "$HELM_DIR/$svc/values-dev.yaml" \
    -n "$NAMESPACE"
done

echo "----------------------------------------------------"
echo "✅ Deployment complete!"
echo "Check status: kubectl get pods -n $NAMESPACE"
echo "----------------------------------------------------"
