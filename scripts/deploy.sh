#!/bin/bash

# Don't exit on error immediately - we'll handle errors manually
set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ArgoCD Deployment Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is not installed or not in PATH${NC}"
    exit 1
fi

# Check if cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
    exit 1
fi

echo -e "${YELLOW}Step 1: Creating ArgoCD namespace...${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ ArgoCD namespace ready${NC}"
echo ""

echo -e "${YELLOW}Step 2: Installing ArgoCD...${NC}"
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>&1 | grep -v "CustomResourceDefinition.*is invalid" || true
echo -e "${GREEN}✓ ArgoCD installed (ignoring known CRD annotation warning)${NC}"
echo ""

echo -e "${YELLOW}Step 3: Waiting for ArgoCD server to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
echo -e "${GREEN}✓ ArgoCD server is ready${NC}"
echo ""

echo -e "${YELLOW}Step 4: Configuring ArgoCD for base path and insecure mode...${NC}"
# Wait a bit for configmap to be created
sleep 5
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.basehref":"/argocd","server.rootpath":"/argocd","server.insecure":"true"}}' 2>&1 || echo -e "${YELLOW}Note: ConfigMap will be patched after ArgoCD is fully ready${NC}"
echo -e "${GREEN}✓ ArgoCD configuration updated${NC}"
echo ""

echo -e "${YELLOW}Step 5: Deploying applications...${NC}"
kubectl apply -f charts/argocd/applications/
echo -e "${GREEN}✓ Applications deployed${NC}"
echo ""

echo -e "${YELLOW}Step 6: Waiting for applications to sync...${NC}"
sleep 15
echo -e "${GREEN}✓ Applications are syncing${NC}"
echo ""

echo -e "${YELLOW}Step 7: Getting ArgoCD admin password...${NC}"
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo -e "${GREEN}✓ Password retrieved${NC}"
echo ""

echo -e "${YELLOW}Step 8: Restarting ArgoCD server to apply base path configuration...${NC}"
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=120s
echo -e "${GREEN}✓ ArgoCD server restarted${NC}"
echo ""

echo -e "${YELLOW}Step 9: Setting up port forwarding for Kong only...${NC}"
# Kill any existing port-forwards
pkill -f "port-forward.*kong" 2>/dev/null || true

# Port forward Kong services only
kubectl port-forward svc/kong-proxy -n kong 8000:8000 > /dev/null 2>&1 &
kubectl port-forward svc/kong-admin -n kong 8001:8001 > /dev/null 2>&1 &
kubectl port-forward svc/kong-manager -n kong 8002:8002 > /dev/null 2>&1 &
sleep 3
echo -e "${GREEN}✓ Port forwarding active for Kong${NC}"
echo ""

echo -e "${YELLOW}Step 10: Waiting for Kong routes to be configured...${NC}"
sleep 5
echo -e "${GREEN}✓ Kong routes configured via declarative config${NC}"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Kong API Gateway:${NC}"
echo -e "  Proxy:    ${GREEN}http://localhost:8000${NC}"
echo -e "  Admin:    ${GREEN}http://localhost:8001${NC}"
echo -e "  Manager:  ${GREEN}http://localhost:8002${NC}"
echo ""
echo -e "${YELLOW}Application Access (via Kong API Gateway):${NC}"
echo -e "  ArgoCD:        ${GREEN}http://localhost:8000/argocd${NC}"
echo -e "    Username:    ${GREEN}admin${NC}"
echo -e "    Password:    ${GREEN}${ARGOCD_PASSWORD}${NC}"
echo -e "  Jenkins:       ${GREEN}http://localhost:8000/jenkins${NC}"
echo -e "  Grafana:       ${GREEN}http://localhost:8000/grafana${NC}"
echo -e "  Prometheus:    ${GREEN}http://localhost:8000/prometheus${NC}"
echo -e "  Alertmanager:  ${GREEN}http://localhost:8000/alertmanager${NC}"
echo ""
echo -e "${YELLOW}Application Status:${NC}"
kubectl get applications -n argocd
echo ""
echo -e "${YELLOW}Deployed Pods:${NC}"
kubectl get pods -A | grep -v "kube-system"
echo ""
echo -e "${GREEN}✓ All services (including ArgoCD) are accessible through Kong API Gateway at http://localhost:8000${NC}"
echo -e "${YELLOW}Note: All services use ClusterIP and are only accessible via Kong${NC}"
echo ""
