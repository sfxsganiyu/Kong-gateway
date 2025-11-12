#!/bin/bash

# Script to generate environment files for Kong API Gateway

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Generating environment files for Kong API Gateway..."

# .env.example
cat > "$PROJECT_DIR/.env.example" << 'EOF'
# NPM Registry Configuration (Required for building microservices)
NPM_USERNAME=your-npm-username
NPM_PASSWORD=your-npm-password
NPM_EMAIL=your-npm-email
NPM_URL=http://npm.seamfix.com

# Kong Configuration
KONG_DATABASE=off
KONG_LOG_LEVEL=info
KONG_NGINX_WORKER_PROCESSES=auto

# Redis Configuration (shared with auth-ms)
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=
REDIS_DB=0
REDIS_TIMEOUT=2000

# PostgreSQL Configuration (shared with auth-ms)
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=seamtel
POSTGRES_USER=seamfix
POSTGRES_PASSWORD=k0l0

# JWT Configuration (MUST match auth-ms JWT_SIGNING_KEY)
JWT_SIGNING_KEY=your-secret-key-must-match-auth-ms

# Microservices URLs
PLATFORM_AUTH_MS_URL=http://platform-auth-ms:3000
PLATFORM_USER_MS_URL=http://platform-user-ms:3000

# JTI Blacklist Plugin Configuration
JTI_REDIS_PREFIX=access:key
JTI_DB_FALLBACK_ENABLED=true
JTI_FAIL_CLOSED=true
JTI_SHADOW_MODE=false

# Rate Limiting Configuration
RATE_LIMIT_MINUTE=1000
RATE_LIMIT_HOUR=10000

# PostgreSQL Revocation Table
POSTGRES_REVOCATION_TABLE=revoked_access_token
EOF

# .env.development
cat > "$PROJECT_DIR/.env.development" << 'EOF'
# NPM Registry Configuration (Required for building microservices)
NPM_USERNAME=seamfix
NPM_PASSWORD=k0l0
NPM_EMAIL=build@seamfix.com
NPM_URL=http://npm.seamfix.com

# Kong Configuration (Development)
KONG_DATABASE=off
KONG_LOG_LEVEL=debug
KONG_NGINX_WORKER_PROCESSES=2

# Redis Configuration (Local Development)
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=
REDIS_DB=0
REDIS_TIMEOUT=2000

# PostgreSQL Configuration (Local Development)
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=seamtel
POSTGRES_USER=seamfix
POSTGRES_PASSWORD=k0l0

# JWT Configuration (Development - use test key)
JWT_SIGNING_KEY=dev-secret-key-change-in-production

# Microservices URLs (Local Docker)
PLATFORM_AUTH_MS_URL=http://platform-auth-ms:3000
PLATFORM_USER_MS_URL=http://platform-user-ms:3000

# JTI Blacklist Plugin Configuration (Development)
JTI_REDIS_PREFIX=access:key
JTI_DB_FALLBACK_ENABLED=true
JTI_FAIL_CLOSED=false
JTI_SHADOW_MODE=false

# Rate Limiting Configuration (Relaxed for Development)
RATE_LIMIT_MINUTE=5000
RATE_LIMIT_HOUR=50000

# PostgreSQL Revocation Table
POSTGRES_REVOCATION_TABLE=revoked_access_token
EOF

# .env.production
cat > "$PROJECT_DIR/.env.production" << 'EOF'
# NPM Registry Configuration (Production)
NPM_USERNAME=seamfix
NPM_PASSWORD=your-production-npm-password
NPM_EMAIL=build@seamfix.com
NPM_URL=http://npm.seamfix.com

# Kong Configuration (Production)
KONG_DATABASE=off
KONG_LOG_LEVEL=warn
KONG_NGINX_WORKER_PROCESSES=auto

# Redis Configuration (Production - External)
REDIS_HOST=production-redis.example.com
REDIS_PORT=6379
REDIS_PASSWORD=your-production-redis-password
REDIS_DB=0
REDIS_TIMEOUT=2000

# PostgreSQL Configuration (Production - External)
POSTGRES_HOST=production-postgres.example.com
POSTGRES_PORT=5432
POSTGRES_DB=seamtel
POSTGRES_USER=seamfix
POSTGRES_PASSWORD=your-production-postgres-password

# JWT Configuration (Production - CRITICAL: MUST match auth-ms)
JWT_SIGNING_KEY=your-production-jwt-signing-key

# Microservices URLs (Production - Internal Network)
PLATFORM_AUTH_MS_URL=http://platform-auth-ms.internal:3000
PLATFORM_USER_MS_URL=http://platform-user-ms.internal:3000

# JTI Blacklist Plugin Configuration (Production - Strict)
JTI_REDIS_PREFIX=access:key
JTI_DB_FALLBACK_ENABLED=true
JTI_FAIL_CLOSED=true
JTI_SHADOW_MODE=false

# Rate Limiting Configuration (Strict for Production)
RATE_LIMIT_MINUTE=1000
RATE_LIMIT_HOUR=10000

# PostgreSQL Revocation Table
POSTGRES_REVOCATION_TABLE=revoked_access_token

# SSL/TLS Configuration
KONG_SSL_CERT=/etc/kong/certs/cert.pem
KONG_SSL_CERT_KEY=/etc/kong/certs/key.pem
EOF

chmod +x "$PROJECT_DIR/.env.example"
chmod +x "$PROJECT_DIR/.env.development"
chmod +x "$PROJECT_DIR/.env.production"

echo "✓ .env.example created"
echo "✓ .env.development created"
echo "✓ .env.production created"
echo ""
echo "To use development environment:"
echo "  cp .env.development .env"
echo ""
echo "To use production environment:"
echo "  cp .env.production .env"

