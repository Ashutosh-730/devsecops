#!/bin/bash
set -e

echo "=========================================="
echo "Kong Route Registration Job"
echo "=========================================="
echo ""
echo "Parameters:"
echo "  DRY_RUN: ${DRY_RUN:-false}"
echo ""

# Configuration
KONG_ADMIN_URL="http://kong-admin.gateway.svc.cluster.local:8001"
CONFIG_DIR="charts/kong/declarative-configs"

# Check if Kong is accessible
echo "Checking Kong Admin API connectivity..."
if ! curl -s -f "$KONG_ADMIN_URL" > /dev/null 2>&1; then
    echo "❌ Cannot connect to Kong Admin API at $KONG_ADMIN_URL"
    echo "Make sure Kong is running in the gateway namespace"
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
    
    if [ ! -f "$config_file" ]; then
        echo "❌ Config file not found: $config_file"
        return 1
    fi
    
    # Validate YAML syntax
    if ! python3 -c "import yaml; yaml.safe_load(open('$config_file'))" 2>/dev/null; then
        echo "❌ Invalid YAML syntax in $config_file"
        return 1
    fi
    echo "✅ YAML syntax valid"
    
    # Extract service configuration
    SERVICE_JSON=$(python3 -c "
import yaml, json
with open('$config_file') as f:
    data = yaml.safe_load(f)
    if 'services' in data and len(data['services']) > 0:
        print(json.dumps(data['services'][0]))
    else:
        print('{}')
" 2>/dev/null)
    
    if [ "$SERVICE_JSON" = "{}" ]; then
        echo "❌ No service definition found in $config_file"
        return 1
    fi
    
    # Extract service details
    SERVICE_NAME=$(echo "$SERVICE_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('name', ''))")
    SERVICE_URL=$(echo "$SERVICE_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('url', ''))")
    
    if [ -z "$SERVICE_NAME" ] || [ -z "$SERVICE_URL" ]; then
        echo "❌ Missing service name or URL in $config_file"
        return 1
    fi
    
    echo "Service Details:"
    echo "  Name: $SERVICE_NAME"
    echo "  URL: $SERVICE_URL"
    
    if [ "${DRY_RUN}" = "true" ]; then
        echo "🔍 DRY RUN - Would create/update service: $SERVICE_NAME"
        return 0
    fi
    
    # Create or update service
    echo "Creating/updating service..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "$KONG_ADMIN_URL/services/$SERVICE_NAME" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$SERVICE_NAME\",\"url\":\"$SERVICE_URL\"}")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        echo "✅ Service created/updated successfully"
    else
        echo "❌ Failed to create/update service (HTTP $HTTP_CODE)"
        return 1
    fi
    
    echo "✅ $service_name configuration complete"
    echo ""
}

# Process all service configuration files
echo "Scanning for service configurations in $CONFIG_DIR..."
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

if [ "${DRY_RUN}" = "true" ]; then
    echo "🔍 DRY RUN completed - no changes were made"
else
    echo "Verifying Kong configuration..."
    echo ""
    echo "Current Kong services:"
    curl -s "$KONG_ADMIN_URL/services" | python3 -m json.tool 2>/dev/null | grep -E '"name"|"url"' || echo "Services configured"
fi

echo ""
echo "=========================================="
if [ $FAIL_COUNT -eq 0 ]; then
    echo "✅ Job completed successfully!"
    exit 0
else
    echo "⚠️  Job completed with $FAIL_COUNT error(s)"
    exit 1
fi


