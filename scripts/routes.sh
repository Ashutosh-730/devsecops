#!/bin/bash

# Apply Kong Routes from Declarative Configuration Files
# This script applies all service configurations from charts/kong/declarative-configs/

set -e

KONG_ADMIN_URL="${KONG_ADMIN_URL:-http://localhost:8001}"
CONFIG_DIR="charts/kong/declarative-configs"

echo "=========================================="
echo "Apply Kong Routes"
echo "=========================================="
echo ""
echo "Kong Admin URL: $KONG_ADMIN_URL"
echo "Config Directory: $CONFIG_DIR"
echo ""

# Check if Kong is accessible
echo "Checking Kong Admin API connectivity..."
if ! curl -s -f "$KONG_ADMIN_URL" > /dev/null 2>&1; then
    echo "❌ Cannot connect to Kong Admin API at $KONG_ADMIN_URL"
    echo ""
    echo "Please ensure:"
    echo "  1. Kong is running"
    echo "  2. Port forwarding is active: kubectl port-forward -n kong svc/kong-admin 8001:8001"
    echo "  3. Or set KONG_ADMIN_URL environment variable"
    exit 1
fi
echo "✅ Kong Admin API is accessible"
echo ""

# Function to apply a single service configuration
apply_service_config() {
    local config_file=$1
    local service_name=$(basename "$config_file" .yaml | sed 's/-service$//')
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Processing: $service_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Validate YAML
    if ! python3 -c "import yaml; yaml.safe_load(open('$config_file'))" 2>/dev/null; then
        echo "❌ Invalid YAML syntax in $config_file"
        return 1
    fi
    
    # Extract service configuration
    SERVICE_JSON=$(python3 -c "
import yaml, json
with open('$config_file') as f:
    data = yaml.safe_load(f)
    if 'services' in data and len(data['services']) > 0:
        print(json.dumps(data['services'][0]))
    else:
        print('{}')
")
    
    if [ "$SERVICE_JSON" = "{}" ]; then
        echo "❌ No service definition found"
        return 1
    fi
    
    # Extract details
    SERVICE_NAME=$(echo "$SERVICE_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('name', ''))")
    SERVICE_URL=$(echo "$SERVICE_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('url', ''))")
    
    echo "  Service: $SERVICE_NAME"
    echo "  URL: $SERVICE_URL"
    
    # Create/update service
    curl -s -X PUT "$KONG_ADMIN_URL/services/$SERVICE_NAME" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$SERVICE_NAME\",\"url\":\"$SERVICE_URL\"}" > /dev/null
    
    echo "  ✅ Service configured"
    
    # Apply routes
    echo "$SERVICE_JSON" | python3 -c "
import sys, json, subprocess
data = json.load(sys.stdin)
routes = data.get('routes', [])
for route in routes:
    route_name = route.get('name', '')
    paths = route.get('paths', [])
    strip_path = route.get('strip_path', True)
    
    if route_name and paths:
        for path in paths:
            cmd = [
                'curl', '-s', '-X', 'PUT',
                '$KONG_ADMIN_URL/services/$SERVICE_NAME/routes/' + route_name,
                '-d', 'name=' + route_name,
                '-d', 'paths[]=' + path,
                '-d', 'strip_path=' + str(strip_path).lower()
            ]
            subprocess.run(cmd, stdout=subprocess.DEVNULL)
        print(f'  ✅ Route: {route_name} -> {paths}')
"
    
    # Apply plugins
    echo "$SERVICE_JSON" | python3 -c "
import sys, json, subprocess
data = json.load(sys.stdin)
plugins = data.get('plugins', [])
for plugin in plugins:
    plugin_name = plugin.get('name', '')
    if plugin_name:
        # Check if plugin already exists
        check_cmd = ['curl', '-s', '$KONG_ADMIN_URL/services/$SERVICE_NAME/plugins']
        result = subprocess.run(check_cmd, capture_output=True, text=True)
        
        # Simple check - in production, parse JSON properly
        if plugin_name not in result.stdout:
            cmd = [
                'curl', '-s', '-X', 'POST',
                '$KONG_ADMIN_URL/services/$SERVICE_NAME/plugins',
                '-d', 'name=' + plugin_name
            ]
            subprocess.run(cmd, stdout=subprocess.DEVNULL)
            print(f'  ✅ Plugin: {plugin_name}')
"
    
    echo ""
}

# Find and process all service files
echo "Scanning for service configurations..."
SERVICE_FILES=$(find "$CONFIG_DIR" -name "*-service.yaml" -type f 2>/dev/null | sort)

if [ -z "$SERVICE_FILES" ]; then
    echo "❌ No service configuration files found in $CONFIG_DIR"
    exit 1
fi

echo "Found $(echo "$SERVICE_FILES" | wc -l) service configuration(s)"
echo ""

# Apply each configuration
SUCCESS_COUNT=0
FAIL_COUNT=0

for config_file in $SERVICE_FILES; do
    if apply_service_config "$config_file"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo "=========================================="
echo "Summary"
echo "=========================================="
echo "✅ Successful: $SUCCESS_COUNT"
echo "❌ Failed: $FAIL_COUNT"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo "Verifying configuration..."
    echo ""
    echo "Kong Services:"
    curl -s "$KONG_ADMIN_URL/services" | python3 -m json.tool 2>/dev/null | grep -E '"name"|"url"' || echo "  (configured)"
    echo ""
    echo "=========================================="
    echo "✅ All routes applied successfully!"
    echo "=========================================="
    echo ""
    echo "Access services via Kong:"
    echo "  • Kong Manager:  http://localhost:8000/kongui"
    echo "  • Kong Admin:    http://localhost:8000/kong/admin"
    echo "  • ArgoCD:        http://localhost:8000/argocd"
    echo "  • Jenkins:       http://localhost:8000/jenkins"
    echo "  • Grafana:       http://localhost:8000/grafana"
    echo "  • Prometheus:    http://localhost:8000/prometheus"
    echo "  • AlertManager:  http://localhost:8000/alertmanager"
    echo ""
    exit 0
else
    echo "⚠️  Some configurations failed"
    exit 1
fi


