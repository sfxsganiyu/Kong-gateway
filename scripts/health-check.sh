#!/bin/bash

set -e

KONG_ADMIN_URL="${KONG_ADMIN_URL:-http://localhost:8001}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-seamtel}"
POSTGRES_USER="${POSTGRES_USER:-seamfix}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=================================="
echo "Kong Gateway - Health Check"
echo "=================================="
echo ""

check_passed=0
check_failed=0

check_service() {
    local service_name="$1"
    local check_command="$2"
    
    echo -n "Checking $service_name... "
    
    if eval "$check_command" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Healthy${NC}"
        ((check_passed++))
        return 0
    else
        echo -e "${RED}✗ Unhealthy${NC}"
        ((check_failed++))
        return 1
    fi
}

echo "1. Kong Services"
echo "----------------"

check_service "Kong Admin API" \
    "curl -s -f $KONG_ADMIN_URL/status"

check_service "Kong Proxy" \
    "curl -s -f http://localhost:8000"

echo ""
echo "2. Infrastructure Services"
echo "--------------------------"

check_service "Redis" \
    "timeout 2 bash -c 'cat < /dev/null > /dev/tcp/$REDIS_HOST/$REDIS_PORT'"

check_service "PostgreSQL" \
    "timeout 2 bash -c 'cat < /dev/null > /dev/tcp/$POSTGRES_HOST/$POSTGRES_PORT'"

echo ""
echo "3. Backend Microservices"
echo "------------------------"

AUTH_MS_URL="${PLATFORM_AUTH_MS_URL:-http://localhost:3000}"
USER_MS_URL="${PLATFORM_USER_MS_URL:-http://localhost:3001}"

if echo "$AUTH_MS_URL" | grep -q "localhost"; then
    check_service "Auth Microservice" \
        "curl -s -f $AUTH_MS_URL/health || curl -s -f $AUTH_MS_URL/status"
else
    echo -e "${YELLOW}⚠ Skipping auth-ms check (external URL)${NC}"
fi

if echo "$USER_MS_URL" | grep -q "localhost"; then
    check_service "User Microservice" \
        "curl -s -f $USER_MS_URL/health || curl -s -f $USER_MS_URL/status"
else
    echo -e "${YELLOW}⚠ Skipping user-ms check (external URL)${NC}"
fi

echo ""
echo "4. Kong Configuration"
echo "---------------------"

KONG_STATUS=$(curl -s "$KONG_ADMIN_URL/status" 2>/dev/null)

if [ -n "$KONG_STATUS" ]; then
    echo "Database: $(echo "$KONG_STATUS" | jq -r '.database.reachable // "N/A"')"
    echo "Server: $(echo "$KONG_STATUS" | jq -r '.server.connections_accepted // "N/A"') connections accepted"
    
    PLUGIN_COUNT=$(curl -s "$KONG_ADMIN_URL/plugins" 2>/dev/null | jq '.data | length' 2>/dev/null)
    echo "Active Plugins: $PLUGIN_COUNT"
    
    ROUTE_COUNT=$(curl -s "$KONG_ADMIN_URL/routes" 2>/dev/null | jq '.data | length' 2>/dev/null)
    echo "Configured Routes: $ROUTE_COUNT"
fi

echo ""
echo "=================================="
echo "Health Check Summary"
echo "=================================="
echo -e "Healthy: ${GREEN}$check_passed${NC}"
echo -e "Unhealthy: ${RED}$check_failed${NC}"
echo ""

if [ $check_failed -eq 0 ]; then
    echo -e "${GREEN}All services are healthy!${NC}"
    exit 0
else
    echo -e "${RED}Some services are unhealthy${NC}"
    exit 1
fi

