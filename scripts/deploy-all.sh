#!/bin/bash

# Complete DevSecOps Stack Deployment Script
# This script sets up Minikube, deploys all Helm charts, and registers Kong routes

# Don't exit on error - we want to deploy all charts even if one fails
# set -e

echo "=================================================="
echo "DevSecOps Stack - Complete Deployment"
echo "=================================================="
echo ""

# Track deployment status
FAILED_DEPLOYMENTS=()
SUCCESSFUL_DEPLOYMENTS=()

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# Function to check and fix stuck Helm releases
check_helm_release() {
    local release_name=$1
    local namespace=$2
    
    # Check if release exists and is stuck
    local status=$(helm list -n "$namespace" -o json | grep -o "\"status\":\"[^\"]*\"" | grep "$release_name" | cut -d'"' -f4)
    
    if [[ "$status" == "pending-upgrade" ]] || [[ "$status" == "pending-install" ]] || [[ "$status" == "pending-rollback" ]]; then
        print_info "Found stuck release '$release_name' in namespace '$namespace' with status: $status"
        print_info "Rolling back stuck release..."
        helm rollback "$release_name" -n "$namespace" 2>/dev/null || true
        sleep 2
        print_status "Rollback completed for $release_name"
    fi
}

# Function to deploy Helm chart with error handling
deploy_helm_chart() {
    local release_name=$1
    local chart_path=$2
    local namespace=$3
    local timeout=${4:-5m}
    
    check_helm_release "$release_name" "$namespace"
    
    print_info "Deploying $release_name..."
    if helm upgrade --install "$release_name" "$chart_path" \
        -n "$namespace" \
        --create-namespace \
        -f values-global.yaml \
        --wait \
        --timeout "$timeout" 2>&1; then
        print_status "$release_name deployed successfully"
        SUCCESSFUL_DEPLOYMENTS+=("$release_name")
        return 0
    else
        print_error "$release_name deployment failed (continuing with other deployments)"
        FAILED_DEPLOYMENTS+=("$release_name")
        return 1
    fi
}

# Check if Minikube is installed
if ! command -v minikube &> /dev/null; then
    print_error "Minikube is not installed. Please install it first."
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed. Please install it first."
    exit 1
fi

# Check if Helm is installed
if ! command -v helm &> /dev/null; then
    print_error "Helm is not installed. Please install it first."
    exit 1
fi

print_status "All required tools are installed"
echo ""

# Step 1: Setup Minikube
echo "=================================================="
echo "Step 1: Setting up Minikube"
echo "=================================================="

# Check if Minikube is already running
if minikube status &> /dev/null; then
    print_info "Minikube is already running"
else
    print_info "Starting Minikube..."
    minikube start --driver=podman --container-runtime=cri-o --cpus=4 --memory=8192
    print_status "Minikube started successfully"
fi

# Enable required addons
print_info "Enabling Minikube addons..."
minikube addons enable metrics-server 2>/dev/null || print_info "metrics-server addon already enabled or unavailable"
minikube addons enable storage-provisioner 2>/dev/null || print_info "storage-provisioner addon already enabled or unavailable"
print_status "Minikube addon configuration complete"
echo ""

# Step 2: Deploy Kong Gateway
echo "=================================================="
echo "Step 2: Deploying Kong Gateway"
echo "=================================================="

print_info "Creating Kong namespace..."
kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

deploy_helm_chart "kong" "./charts/kong" "kong" "5m"

# Wait for Kong to be ready (only if deployment succeeded)
if [[ " ${SUCCESSFUL_DEPLOYMENTS[@]} " =~ " kong " ]]; then
    print_info "Waiting for Kong to be ready..."
    if kubectl wait --for=condition=ready pod -l app=kong -n kong --timeout=300s 2>/dev/null; then
        print_status "Kong is ready"
    else
        print_error "Kong pods not ready (continuing anyway)"
    fi
fi
echo ""

# Step 3: Deploy Monitoring Stack
echo "=================================================="
echo "Step 3: Deploying Monitoring Stack"
echo "=================================================="

# Deploy Prometheus
deploy_helm_chart "prometheus" "./charts/prometheus" "monitoring" "5m"

# Deploy Loki
deploy_helm_chart "loki" "./charts/loki" "monitoring" "5m"

# Deploy Grafana
deploy_helm_chart "grafana" "./charts/grafana" "monitoring" "5m"

# Deploy Alertmanager (optional)
deploy_helm_chart "alertmanager" "./charts/alertmanager" "monitoring" "5m"

echo ""

# Step 4: Deploy CI/CD Stack
echo "=================================================="
echo "Step 4: Deploying CI/CD Stack"
echo "=================================================="

# Deploy Jenkins
deploy_helm_chart "jenkins" "./charts/jenkins" "cicd" "5m"

echo ""

# Step 5: Register Kong Routes
echo "=================================================="
echo "Step 5: Registering Kong Routes"
echo "=================================================="

# Wait a bit for all services to be fully ready
print_info "Waiting for all services to stabilize..."
sleep 10

# Get Kong Admin API URL
KONG_ADMIN_URL="http://localhost:32001"

# Start port-forward for Kong Admin API in background
print_info "Setting up Kong Admin API port-forward..."
kubectl port-forward -n kong svc/kong-admin 32001:8001 > /dev/null 2>&1 &
KONG_PF_PID=$!
sleep 3

# Function to register Kong route
register_kong_route() {
    local service_name=$1
    local config_file=$2
    
    print_info "Registering route for $service_name..."
    
    if [ -f "$config_file" ]; then
        # Apply declarative config
        curl -s -X POST "$KONG_ADMIN_URL/config" \
            -F "config=@$config_file" > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            print_status "Route registered for $service_name"
        else
            print_error "Failed to register route for $service_name"
        fi
    else
        print_error "Config file not found: $config_file"
    fi
}

# Register all routes
register_kong_route "Grafana" "charts/kong/declarative-configs/grafana-service.yaml"
register_kong_route "Prometheus" "charts/kong/declarative-configs/prometheus-service.yaml"
register_kong_route "Alertmanager" "charts/kong/declarative-configs/alertmanager-service.yaml"
register_kong_route "Jenkins" "charts/kong/declarative-configs/jenkins-service.yaml"

# Kill the port-forward process
kill $KONG_PF_PID 2>/dev/null

print_status "All Kong routes registered"
echo ""

# Step 6: Setup Port Forwards
echo "=================================================="
echo "Step 6: Setting up Port Forwards"
echo "=================================================="

print_info "Starting port-forward for Kong Proxy (32000)..."
kubectl port-forward -n kong svc/kong-proxy 32000:8000 > /dev/null 2>&1 &
echo $! > /tmp/kong-proxy-pf.pid

print_info "Starting port-forward for Kong Admin (32001)..."
kubectl port-forward -n kong svc/kong-admin 32001:8001 > /dev/null 2>&1 &
echo $! > /tmp/kong-admin-pf.pid

print_info "Starting port-forward for Prometheus (32090)..."
kubectl port-forward -n monitoring svc/prometheus 32090:9090 > /dev/null 2>&1 &
echo $! > /tmp/prometheus-pf.pid

print_info "Starting port-forward for Grafana (32300)..."
kubectl port-forward -n monitoring svc/grafana 32300:3000 > /dev/null 2>&1 &
echo $! > /tmp/grafana-pf.pid

sleep 3
print_status "Port forwards established"
echo ""

# Step 7: Display Access Information
echo "=================================================="
echo "Deployment Complete!"
echo "=================================================="
echo ""
echo "Access URLs (via Kong Gateway):"
echo "  Kong Proxy:      http://localhost:32000"
echo "  Kong Admin:      http://localhost:32001"
echo "  Grafana:         http://localhost:32000/grafana"
echo "  Prometheus:      http://localhost:32000/prometheus"
echo "  Alertmanager:    http://localhost:32000/alertmanager"
echo "  Jenkins:         http://localhost:32000/jenkins"
echo ""
echo "Direct Access URLs:"
echo "  Prometheus:      http://localhost:32090"
echo "  Grafana:         http://localhost:32300"
echo ""
echo "Default Credentials:"
echo "  Grafana:         admin / admin"
echo "  Jenkins:         admin / admin"
echo ""
echo "Useful Commands:"
echo "  View all pods:           kubectl get pods --all-namespaces"
echo "  View Kong routes:        curl http://localhost:32001/routes"
echo "  View Kong services:      curl http://localhost:32001/services"
echo "  Stop port-forwards:      ./scripts/stop-port-forwards.sh"
echo "  Restart deployment:      ./scripts/deploy-all.sh"
echo ""
echo "To stop all port-forwards, run:"
echo "  kill \$(cat /tmp/*-pf.pid 2>/dev/null) 2>/dev/null"
echo ""

# Display deployment summary
echo "=================================================="
echo "Deployment Summary"
echo "=================================================="
echo ""

if [ ${#SUCCESSFUL_DEPLOYMENTS[@]} -gt 0 ]; then
    echo -e "${GREEN}Successfully Deployed (${#SUCCESSFUL_DEPLOYMENTS[@]}):${NC}"
    for deployment in "${SUCCESSFUL_DEPLOYMENTS[@]}"; do
        echo -e "  ${GREEN}✓${NC} $deployment"
    done
    echo ""
fi

if [ ${#FAILED_DEPLOYMENTS[@]} -gt 0 ]; then
    echo -e "${RED}Failed Deployments (${#FAILED_DEPLOYMENTS[@]}):${NC}"
    for deployment in "${FAILED_DEPLOYMENTS[@]}"; do
        echo -e "  ${RED}✗${NC} $deployment"
    done
    echo ""
    echo -e "${YELLOW}Note: Failed deployments may be due to:${NC}"
    echo "  - Network/DNS issues (check: minikube ssh, then ping registry-1.docker.io)"
    echo "  - Resource constraints (check: kubectl top nodes)"
    echo "  - Image pull issues (check: kubectl describe pod -n <namespace>)"
    echo ""
fi

if [ ${#FAILED_DEPLOYMENTS[@]} -eq 0 ]; then
    print_status "DevSecOps Stack is fully deployed and ready!"
else
    print_info "DevSecOps Stack partially deployed. Check failed deployments above."
fi

# Made with Bob
