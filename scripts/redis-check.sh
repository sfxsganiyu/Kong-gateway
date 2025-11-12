#!/bin/bash

set -e

REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=================================="
echo "Redis Connectivity Test"
echo "=================================="
echo ""

echo "Host: $REDIS_HOST"
echo "Port: $REDIS_PORT"
echo ""

echo -n "Testing TCP connection... "
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$REDIS_HOST/$REDIS_PORT" 2>/dev/null; then
    echo -e "${GREEN}✓ Connected${NC}"
else
    echo -e "${RED}✗ Connection failed${NC}"
    exit 1
fi

echo -n "Testing Redis PING... "
if command -v redis-cli &> /dev/null; then
    if [ -n "$REDIS_PASSWORD" ]; then
        PONG=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" --no-auth-warning PING 2>/dev/null)
    else
        PONG=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" PING 2>/dev/null)
    fi
    
    if [ "$PONG" == "PONG" ]; then
        echo -e "${GREEN}✓ PONG${NC}"
    else
        echo -e "${RED}✗ No response${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠ redis-cli not installed, skipping PING test${NC}"
fi

echo ""
echo -n "Testing Redis INFO... "
if command -v redis-cli &> /dev/null; then
    if [ -n "$REDIS_PASSWORD" ]; then
        INFO=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" --no-auth-warning INFO server 2>/dev/null)
    else
        INFO=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INFO server 2>/dev/null)
    fi
    
    if [ -n "$INFO" ]; then
        echo -e "${GREEN}✓ Available${NC}"
        echo ""
        echo "Redis Server Info:"
        echo "-----------------"
        echo "$INFO" | grep "redis_version" | sed 's/^/  /'
        echo "$INFO" | grep "uptime_in_days" | sed 's/^/  /'
        echo "$INFO" | grep "connected_clients" | sed 's/^/  /'
    else
        echo -e "${RED}✗ Failed${NC}"
        exit 1
    fi
fi

echo ""
echo -n "Testing JTI key pattern... "
if command -v redis-cli &> /dev/null; then
    if [ -n "$REDIS_PASSWORD" ]; then
        KEY_COUNT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" --no-auth-warning KEYS "access:key:*" 2>/dev/null | wc -l)
    else
        KEY_COUNT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" KEYS "access:key:*" 2>/dev/null | wc -l)
    fi
    
    echo -e "${GREEN}✓ Found $KEY_COUNT access keys${NC}"
fi

echo ""
echo -e "${GREEN}Redis connectivity check passed!${NC}"
exit 0

