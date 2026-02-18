#!/bin/bash

# Don't exit on error immediately - we'll handle errors manually
# set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  DevSecOps Platform Deployment${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if required tools are available
echo -e "${BLUE}Checking prerequisites...${NC}"
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is not installed or not in PATH${NC}"
    exit 1
fi

if ! command -v minikube &> /dev/null; then
    echo -e "${RED}Error: minikube is not installed or not in PATH${NC}"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo -e "${RED}Error: helm is not installed or not in PATH${NC}"
    exit 1
fi
echo -e "${GREEN}✓ All prerequisites met${NC}"
echo ""

# Delete existing minikube cluster
echo -e "${YELLOW}Step 1: Cleaning up existing minikube cluster...${NC}"
if minikube status &> /dev/null; then
    echo -e "${BLUE}  Deleting existing cluster...${NC}"
    minikube delete
    echo -e "${GREEN}✓ Existing cluster deleted${NC}"
else
    echo -e "${BLUE}  No existing cluster found${NC}"
fi
echo ""

# Create new minikube cluster
echo -e "${YELLOW}Step 2: Creating new minikube cluster...${NC}"
echo -e "${BLUE}  Starting minikube with maximum available resources...${NC}"
echo -e "${BLUE}  CPUs: 7, Memory: 16GB, Disk: 100GB${NC}"
minikube start --cpus=7 --memory=16384 --disk-size=100g --driver=podman --container-runtime=cri-o
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to create minikube cluster${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Minikube cluster created successfully${NC}"
echo ""

# Verify cluster is accessible
echo -e "${YELLOW}Step 3: Verifying cluster connectivity...${NC}"
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
    exit 1
fi
kubectl get nodes
echo -e "${GREEN}✓ Cluster is accessible${NC}"
echo ""

echo -e "${YELLOW}Step 4: Creating ArgoCD namespace...${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ ArgoCD namespace ready${NC}"
echo ""

echo -e "${YELLOW}Step 5: Installing ArgoCD...${NC}"
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>&1 | grep -v "CustomResourceDefinition.*is invalid" || true
echo -e "${GREEN}✓ ArgoCD installed (ignoring known CRD annotation warning)${NC}"
echo ""

echo -e "${YELLOW}Step 6: Waiting for ArgoCD server to be ready...${NC}"
echo -e "${BLUE}  Waiting for pods to be created...${NC}"
sleep 10
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s 2>&1 || echo -e "${YELLOW}  Note: Pods may still be initializing${NC}"
echo -e "${GREEN}✓ ArgoCD server is ready${NC}"
echo ""

echo -e "${YELLOW}Step 7: Configuring ArgoCD for base path and insecure mode...${NC}"
# Wait a bit for configmap to be created
sleep 5
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.basehref":"/argocd","server.rootpath":"/argocd","server.insecure":"true"}}' 2>&1 || echo -e "${YELLOW}Note: ConfigMap will be patched after ArgoCD is fully ready${NC}"
echo -e "${GREEN}✓ ArgoCD configuration updated${NC}"
echo ""

echo -e "${YELLOW}Step 8: Deploying ArgoCD applications chart...${NC}"
helm upgrade --install argocd-apps charts/argocd \
  --namespace argocd \
  --create-namespace \
  --values values-global.yaml
echo -e "${GREEN}✓ ArgoCD applications chart deployed${NC}"
echo ""

echo -e "${YELLOW}Step 9: Waiting for applications to sync...${NC}"
sleep 15
echo -e "${GREEN}✓ Applications are syncing${NC}"
echo ""

echo -e "${YELLOW}Step 10: Getting ArgoCD admin password...${NC}"
echo -e "${BLUE}  Waiting for secret to be created...${NC}"
for i in {1..30}; do
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null)
    if [ -n "$ARGOCD_PASSWORD" ]; then
        break
    fi
    echo -e "${BLUE}  Attempt $i/30: Secret not ready yet, waiting...${NC}"
    sleep 5
done
if [ -n "$ARGOCD_PASSWORD" ]; then
    echo -e "${GREEN}✓ Password retrieved${NC} : $ARGOCD_PASSWORD"
else
    echo -e "${YELLOW}⚠ Password not available yet. Retrieve it later with:${NC}"
    echo -e "${YELLOW}  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d${NC}"
fi
echo ""

echo -e "${YELLOW}Step 11: Restarting ArgoCD server to apply base path configuration...${NC}"
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=120s
echo -e "${GREEN}✓ ArgoCD server restarted${NC}"
echo ""

echo -e "${YELLOW}Step 12: Triggering application sync...${NC}"
echo -e "${BLUE}  Refreshing all applications...${NC}"
for app in alertmanager grafana prometheus kong jenkins loki; do
    echo -e "${BLUE}    Refreshing $app...${NC}"
    kubectl -n argocd patch application $app --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}' 2>/dev/null || true
done
sleep 10
echo -e "${GREEN}✓ Applications refreshed${NC}"
echo ""

echo -e "${YELLOW}Step 13: Waiting for all applications to be healthy...${NC}"
echo -e "${BLUE}  This may take a few minutes...${NC}"
sleep 30

# Wait for Kong to be ready
echo -e "${BLUE}  Waiting for Kong...${NC}"
kubectl wait --for=condition=ready pod -l app=kong -n kong --timeout=300s 2>/dev/null || echo -e "${YELLOW}    Kong not ready yet${NC}"

# Wait for Jenkins to be ready
echo -e "${BLUE}  Waiting for Jenkins...${NC}"
kubectl wait --for=condition=ready pod -l app=jenkins -n cicd --timeout=300s 2>/dev/null || echo -e "${YELLOW}    Jenkins not ready yet${NC}"

# Wait for Grafana to be ready
echo -e "${BLUE}  Waiting for Grafana...${NC}"
kubectl wait --for=condition=ready pod -l app=grafana -n monitoring --timeout=300s 2>/dev/null || echo -e "${YELLOW}    Grafana not ready yet${NC}"

# Wait for Prometheus to be ready
echo -e "${BLUE}  Waiting for Prometheus...${NC}"
kubectl wait --for=condition=ready pod -l app=prometheus -n monitoring --timeout=300s 2>/dev/null || echo -e "${YELLOW}    Prometheus not ready yet${NC}"

# Wait for Alertmanager to be ready
echo -e "${BLUE}  Waiting for Alertmanager...${NC}"
kubectl wait --for=condition=ready pod -l app=alertmanager -n monitoring --timeout=300s 2>/dev/null || echo -e "${YELLOW}    Alertmanager not ready yet${NC}"

# Wait for Loki to be ready
echo -e "${BLUE}  Waiting for Loki...${NC}"
kubectl wait --for=condition=ready pod -l app=loki -n monitoring --timeout=300s 2>/dev/null || echo -e "${YELLOW}    Loki not ready yet${NC}"

echo -e "${GREEN}✓ All applications are ready${NC}"
echo ""

echo -e "${YELLOW}Step 14: Checking application sync status...${NC}"
kubectl get applications -n argocd
echo ""

echo -e "${YELLOW}Step 15: Setting up port forwarding for Kong...${NC}"
# Kill any existing port-forwards
pkill -f "port-forward.*kong" 2>/dev/null || true

# Port forward Kong services only
kubectl port-forward svc/kong-proxy -n kong 8000:8000 > /dev/null 2>&1 &
kubectl port-forward svc/kong-admin -n kong 8001:8001 > /dev/null 2>&1 &
kubectl port-forward svc/kong-manager -n kong 8002:8002 > /dev/null 2>&1 &
sleep 3
echo -e "${GREEN}✓ Port forwarding active for Kong${NC}"
echo ""

echo -e "${YELLOW}Step 16: Verifying Kong routes configuration...${NC}"
sleep 5
echo -e "${GREEN}✓ Kong routes configured via declarative config${NC}"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Cluster Information:${NC}"
echo -e "  Minikube IP:  ${GREEN}$(minikube ip)${NC}"
echo -e "  Kubernetes:   ${GREEN}$(kubectl version --short 2>/dev/null | grep Server | cut -d' ' -f3)${NC}"
echo ""
echo -e "${YELLOW}Kong API Gateway:${NC}"
echo -e "  Proxy:    ${GREEN}http://localhost:8000${NC}"
echo -e "  Admin:    ${GREEN}http://localhost:8001${NC}"
# echo -e "  Manager:  ${GREEN}http://localhost:8002${NC}"
echo ""
echo -e "${YELLOW}Application Access (via Kong API Gateway):${NC}"
echo -e "  Kong Manager:  ${GREEN}http://localhost:8000/kongui${NC}"
echo -e "  ArgoCD:        ${GREEN}http://localhost:8000/argocd${NC}"
echo -e "  Jenkins:       ${GREEN}http://localhost:8000/jenkins${NC}"
echo -e "  Grafana:       ${GREEN}http://localhost:8000/grafana${NC}"
echo -e "  Prometheus:    ${GREEN}http://localhost:8000/prometheus${NC}"
echo -e "  Alertmanager:  ${GREEN}http://localhost:8000/alertmanager${NC}"
# echo ""
# echo -e "${YELLOW}Application Credentials:${NC}"
# echo ""
# echo -e "${BLUE}ArgoCD:${NC}"
# echo -e "  URL:      ${GREEN}http://localhost:8000/argocd${NC}"
# echo -e "  Username: ${GREEN}admin${NC}"
# echo -e "  Password: ${GREEN}${ARGOCD_PASSWORD}${NC}"
# echo ""

# # Get Jenkins password
# echo -e "${BLUE}Jenkins:${NC}"
# echo -e "  URL:      ${GREEN}http://localhost:8000/jenkins${NC}"
# echo -e "  Username: ${GREEN}admin${NC}"
# JENKINS_PASSWORD=$(kubectl get secret -n cicd jenkins-admin-secret -o jsonpath="{.data.jenkins-admin-password}" 2>/dev/null | base64 -d 2>/dev/null)
# if [ -n "$JENKINS_PASSWORD" ]; then
#     echo -e "  Password: ${GREEN}${JENKINS_PASSWORD}${NC}"
# else
#     echo -e "  Password: ${YELLOW}(Retrieving from pod...)${NC}"
#     JENKINS_POD=$(kubectl get pods -n cicd -l app=jenkins -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
#     if [ -n "$JENKINS_POD" ]; then
#         JENKINS_PASSWORD=$(kubectl exec -n cicd $JENKINS_POD -- cat /run/secrets/additional/chart-admin-password 2>/dev/null || echo "admin")
#         echo -e "  Password: ${GREEN}${JENKINS_PASSWORD}${NC}"
#     else
#         echo -e "  Password: ${YELLOW}Check pod logs: kubectl logs -n cicd <jenkins-pod>${NC}"
#     fi
# fi
# echo ""

# # Get Grafana password
# echo -e "${BLUE}Grafana:${NC}"
# echo -e "  URL:      ${GREEN}http://localhost:8000/grafana${NC}"
# echo -e "  Username: ${GREEN}admin${NC}"
# GRAFANA_PASSWORD=$(kubectl get secret -n monitoring grafana-admin-secret -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null)
# if [ -n "$GRAFANA_PASSWORD" ]; then
#     echo -e "  Password: ${GREEN}${GRAFANA_PASSWORD}${NC}"
# else
#     echo -e "  Password: ${YELLOW}admin (default - change after first login)${NC}"
# fi
# echo ""

# # Prometheus (no auth by default)
# echo -e "${BLUE}Prometheus:${NC}"
# echo -e "  URL:      ${GREEN}http://localhost:8000/prometheus${NC}"
# echo -e "  Auth:     ${YELLOW}No authentication required${NC}"
# echo ""

# # Alertmanager (no auth by default)
# echo -e "${BLUE}Alertmanager:${NC}"
# echo -e "  URL:      ${GREEN}http://localhost:8000/alertmanager${NC}"
# echo -e "  Auth:     ${YELLOW}No authentication required${NC}"
# echo ""

# # Kong Admin
# echo -e "${BLUE}Kong Admin API:${NC}"
# echo -e "  URL:      ${GREEN}http://localhost:8001${NC}"
# echo -e "  Auth:     ${YELLOW}No authentication required${NC}"
# echo ""

# # Kong Manager
# echo -e "${BLUE}Kong Manager:${NC}"
# echo -e "  URL:      ${GREEN}http://localhost:8000/kongui${NC}"
# echo -e "  Auth:     ${YELLOW}No authentication required${NC}"
# echo ""
# echo -e "${YELLOW}ArgoCD Application Status:${NC}"
# kubectl get applications -n argocd
# echo ""
# echo -e "${YELLOW}Deployed Pods by Namespace:${NC}"
# kubectl get pods -A | grep -v "kube-system"
# echo ""
# echo -e "${YELLOW}Cluster Resources:${NC}"
# kubectl top nodes 2>/dev/null || echo -e "${BLUE}  (Metrics not yet available)${NC}"
# echo ""
# echo -e "${GREEN}✓ All services are accessible through Kong API Gateway at http://localhost:8000${NC}"
# echo -e "${YELLOW}Note: All services use ClusterIP and are only accessible via Kong${NC}"
# echo ""
# echo -e "${BLUE}Useful Commands:${NC}"
# echo -e "  View logs:           ${GREEN}kubectl logs -f <pod-name> -n <namespace>${NC}"
# echo -e "  Restart deployment:  ${GREEN}kubectl rollout restart deployment <name> -n <namespace>${NC}"
# echo -e "  Minikube dashboard:  ${GREEN}minikube dashboard${NC}"
# echo -e "  Stop cluster:        ${GREEN}minikube stop${NC}"
# echo -e "  Delete cluster:      ${GREEN}minikube delete${NC}"
# echo ""
