#!/bin/bash

# Kong Port Forward Script
# This script sets up port forwarding for all Kong services

echo "🚀 Setting up Kong port forwarding..."
echo ""

# Kill any existing port forwards
echo "📌 Cleaning up existing port forwards..."
pkill -f "port-forward.*kong" 2>/dev/null
sleep 2

# Start port forwarding for Kong services
echo "🔌 Starting port forwards..."

# Kong Proxy - Port 8000
kubectl port-forward -n kong svc/kong-proxy 8000:8000 > /dev/null 2>&1 &
PROXY_PID=$!
echo "  ✓ Kong Proxy: http://localhost:8000 (PID: $PROXY_PID)"

# Kong Admin API - Port 8001 (for route management)
kubectl port-forward -n kong svc/kong-admin 8001:8001 > /dev/null 2>&1 &
ADMIN_PID=$!
echo "  ✓ Kong Admin API: http://localhost:8001 (PID: $ADMIN_PID)"

# Kong Manager - Port 8002 (for internal communication)
kubectl port-forward -n kong svc/kong-manager 8002:8002 > /dev/null 2>&1 &
MANAGER_PID=$!
echo "  ✓ Kong Manager: http://localhost:8002 (PID: $MANAGER_PID)"

echo ""
echo "✅ All port forwards are active!"
echo ""
echo "📋 Direct Access:"
echo "   Kong Proxy:    http://localhost:8000"
echo "   Kong Admin:    http://localhost:8001"
echo "   ArgoCD:        http://localhost:8080/argocd/ (Direct - insecure mode)"
echo ""
echo "🌐 Application Access (via Kong Proxy):"
echo "   Kong Manager:  http://localhost:8000/kongui"
echo "   Kong Admin:    http://localhost:8000/kong/admin"
echo "   ArgoCD:        http://localhost:8000/argocd (via Kong)"
echo "   Jenkins:       http://localhost:8000/jenkins"
echo "   Grafana:       http://localhost:8000/grafana"
echo "   Prometheus:    http://localhost:8000/prometheus"
echo "   Alertmanager:  http://localhost:8000/alertmanager"
echo ""
echo "💡 To stop port forwarding, run:"
echo "   pkill -f 'port-forward.*(kong|argocd)'"
echo ""


