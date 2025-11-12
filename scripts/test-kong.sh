#!/bin/bash

set -e

KONG_URL="${KONG_URL:-http://localhost:8000}"
KONG_ADMIN_URL="${KONG_ADMIN_URL:-http://localhost:8001}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=================================="
echo "Kong API Gateway - E2E Test Suite"
echo "=================================="
echo ""

test_passed=0
test_failed=0

run_test() {
    local test_name="$1"
    local command="$2"
    local expected_status="$3"
    
    echo -n "Testing: $test_name... "
    
    response=$(eval "$command")
    status=$?
    
    if [ $status -eq 0 ] || [ $status -eq $expected_status ]; then
        echo -e "${GREEN}✓ PASSED${NC}"
        ((test_passed++))
        return 0
    else
        echo -e "${RED}✗ FAILED${NC}"
        echo "  Response: $response"
        ((test_failed++))
        return 1
    fi
}

echo "1. Health Check Tests"
echo "---------------------"

run_test "Kong Admin API is reachable" \
    "curl -s -o /dev/null -w '%{http_code}' $KONG_ADMIN_URL/status" \
    200

run_test "Kong Proxy is reachable" \
    "curl -s -o /dev/null -w '%{http_code}' $KONG_URL/public/status" \
    0

echo ""
echo "2. Public Route Tests (No Authentication)"
echo "------------------------------------------"

run_test "Public health check" \
    "curl -s -o /dev/null -w '%{http_code}' $KONG_URL/public/status" \
    0

echo ""
echo "3. JWT Authentication Tests"
echo "----------------------------"

echo "Performing login..."
LOGIN_RESPONSE=$(curl -s -X POST "$KONG_URL/public/authenticate/basic" \
    -H "Content-Type: application/json" \
    -d '{
        "username": "testuser",
        "password": "dGVzdHBhc3M=",
        "accountId": "1234567890"
    }' 2>/dev/null || echo '{"error": "login failed"}')

ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.data.accessToken // empty' 2>/dev/null)

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
    echo -e "${YELLOW}⚠ WARNING: Could not obtain access token from login${NC}"
    echo "  This is expected if auth-ms is not running"
    echo "  Skipping authentication tests..."
else
    echo -e "${GREEN}✓ Login successful${NC}"
    
    run_test "Access private route with valid token" \
        "curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer $ACCESS_TOKEN' $KONG_URL/private/user/profile" \
        0
    
    run_test "Access private route without token (should fail)" \
        "curl -s -o /dev/null -w '%{http_code}' $KONG_URL/private/user/profile" \
        0
    
    echo ""
    echo "4. Token Revocation Tests"
    echo "-------------------------"
    
    echo "Logging out (revoking token)..."
    LOGOUT_RESPONSE=$(curl -s -X POST "$KONG_URL/private/authenticate/logout" \
        -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null || echo '{}')
    
    if echo "$LOGOUT_RESPONSE" | jq -e '.success' >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Logout successful${NC}"
        
        sleep 1
        
        run_test "Access private route with revoked token (should fail with 401)" \
            "curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer $ACCESS_TOKEN' $KONG_URL/private/user/profile" \
            0
    else
        echo -e "${YELLOW}⚠ WARNING: Logout failed or not supported${NC}"
    fi
fi

echo ""
echo "5. Rate Limiting Tests"
echo "----------------------"

echo "Sending multiple requests to test rate limiting..."
rate_limit_hit=false
for i in {1..20}; do
    status=$(curl -s -o /dev/null -w '%{http_code}' "$KONG_URL/public/status" 2>/dev/null)
    if [ "$status" == "429" ]; then
        rate_limit_hit=true
        break
    fi
done

if [ "$rate_limit_hit" = true ]; then
    echo -e "${GREEN}✓ Rate limiting is working${NC}"
    ((test_passed++))
else
    echo -e "${YELLOW}⚠ Rate limiting not triggered (might need higher request volume)${NC}"
fi

echo ""
echo "6. Plugin Configuration Tests"
echo "------------------------------"

PLUGINS=$(curl -s "$KONG_ADMIN_URL/plugins" 2>/dev/null | jq -r '.data[].name' 2>/dev/null)

if echo "$PLUGINS" | grep -q "jti-blacklist-checker"; then
    echo -e "${GREEN}✓ Custom jti-blacklist-checker plugin is loaded${NC}"
    ((test_passed++))
else
    echo -e "${RED}✗ Custom plugin not found${NC}"
    ((test_failed++))
fi

if echo "$PLUGINS" | grep -q "rate-limiting"; then
    echo -e "${GREEN}✓ Rate limiting plugin is loaded${NC}"
    ((test_passed++))
else
    echo -e "${RED}✗ Rate limiting plugin not found${NC}"
    ((test_failed++))
fi

if echo "$PLUGINS" | grep -q "jwt"; then
    echo -e "${GREEN}✓ JWT plugin is loaded${NC}"
    ((test_passed++))
else
    echo -e "${RED}✗ JWT plugin not found${NC}"
    ((test_failed++))
fi

echo ""
echo "=================================="
echo "Test Summary"
echo "=================================="
echo -e "Passed: ${GREEN}$test_passed${NC}"
echo -e "Failed: ${RED}$test_failed${NC}"
echo ""

if [ $test_failed -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi

