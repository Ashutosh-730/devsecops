#!/bin/bash

# Kong Port Forward Script
# This script sets up port forwarding for all Kong services

echo "🚀 Setting up Kong port forwarding..."
echo ""

# Kill any existing Kong port forwards
echo "📌 Cleaning up existing port forwards..."
pkill -f "port-forward.*kong" 2>/dev/null
sleep 2

# Start port forwarding for Kong services
echo "🔌 Starting port forwards..."

# Kong Admin API - Port 32001
kubectl port-forward -n kong svc/kong-admin 32001:8001 > /dev/null 2>&1 &
ADMIN_PID=$!
echo "  ✓ Kong Admin API: http://localhost:32001 (PID: $ADMIN_PID)"

# Kong Manager - Port 32002
kubectl port-forward -n kong svc/kong-manager 32002:8002 > /dev/null 2>&1 &
MANAGER_PID=$!
echo "  ✓ Kong Manager: http://localhost:32002 (PID: $MANAGER_PID)"

# Kong Proxy - Port 32000
kubectl port-forward -n kong svc/kong-proxy 32000:8000 > /dev/null 2>&1 &
PROXY_PID=$!
echo "  ✓ Kong Proxy: http://localhost:32000 (PID: $PROXY_PID)"

echo ""
echo "✅ All Kong port forwards are active!"
echo ""
echo "📋 Quick Reference:"
echo "   Admin API:    http://localhost:32001"
echo "   Kong Manager: http://localhost:32002"
echo "   Kong Proxy:   http://localhost:32000"
echo ""
echo "💡 To stop port forwarding, run:"
echo "   pkill -f 'port-forward.*kong'"
echo ""


