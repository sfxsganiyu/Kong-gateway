#!/bin/bash

set -e

CONFIG_FILE="${1:-./config/kong.yaml}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=================================="
echo "Kong Configuration Validator"
echo "=================================="
echo ""

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}✗ Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

echo "Validating: $CONFIG_FILE"
echo ""

if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ Docker is not installed${NC}"
    exit 1
fi

echo "Running Kong validation..."

docker run --rm \
    -v "$(pwd)/config:/usr/local/kong/declarative" \
    kong:3.4-alpine \
    kong config parse /usr/local/kong/declarative/kong.yaml

validation_status=$?

echo ""

if [ $validation_status -eq 0 ]; then
    echo -e "${GREEN}✓ Configuration is valid!${NC}"
    echo ""
    echo "Configuration Details:"
    echo "---------------------"
    
    if command -v yq &> /dev/null; then
        echo "Services:"
        yq '.services[].name' "$CONFIG_FILE" 2>/dev/null | sed 's/^/  - /'
        echo ""
        echo "Routes:"
        yq '.services[].routes[].name' "$CONFIG_FILE" 2>/dev/null | sed 's/^/  - /'
        echo ""
        echo "Global Plugins:"
        yq '.plugins[].name' "$CONFIG_FILE" 2>/dev/null | sed 's/^/  - /'
    else
        echo -e "${YELLOW}⚠ Install 'yq' for detailed configuration breakdown${NC}"
    fi
    
    exit 0
else
    echo -e "${RED}✗ Configuration validation failed${NC}"
    echo ""
    echo "Please fix the errors above and try again."
    exit 1
fi

