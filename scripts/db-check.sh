#!/bin/bash

set -e

POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-seamtel}"
POSTGRES_USER="${POSTGRES_USER:-seamfix}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-k0l0}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=================================="
echo "PostgreSQL Connectivity Test"
echo "=================================="
echo ""

echo "Host: $POSTGRES_HOST"
echo "Port: $POSTGRES_PORT"
echo "Database: $POSTGRES_DB"
echo "User: $POSTGRES_USER"
echo ""

echo -n "Testing TCP connection... "
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$POSTGRES_HOST/$POSTGRES_PORT" 2>/dev/null; then
    echo -e "${GREEN}✓ Connected${NC}"
else
    echo -e "${RED}✗ Connection failed${NC}"
    exit 1
fi

if command -v psql &> /dev/null; then
    export PGPASSWORD="$POSTGRES_PASSWORD"
    
    echo -n "Testing PostgreSQL connection... "
    if psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Connected${NC}"
    else
        echo -e "${RED}✗ Connection failed${NC}"
        exit 1
    fi
    
    echo ""
    echo "Database Info:"
    echo "--------------"
    
    VERSION=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT version()" 2>/dev/null | head -n1 | xargs)
    echo "  Version: $VERSION"
    
    echo ""
    echo -n "Checking revoked_access_token table... "
    TABLE_EXISTS=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'revoked_access_token')" 2>/dev/null | xargs)
    
    if [ "$TABLE_EXISTS" == "t" ]; then
        echo -e "${GREEN}✓ Table exists${NC}"
        
        ROW_COUNT=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT COUNT(*) FROM revoked_access_token" 2>/dev/null | xargs)
        echo "  Revoked tokens: $ROW_COUNT"
    else
        echo -e "${YELLOW}⚠ Table does not exist${NC}"
        echo "  This table will be created by auth-ms migrations"
    fi
    
    unset PGPASSWORD
else
    echo -e "${YELLOW}⚠ psql not installed, skipping detailed checks${NC}"
fi

echo ""
echo -e "${GREEN}PostgreSQL connectivity check passed!${NC}"
exit 0

