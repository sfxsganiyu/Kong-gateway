# Kong API Gateway - Platform Microservices

Kong API Gateway providing unified access to platform microservices with JWT authentication, custom JTI-based token revocation checking, and global rate limiting.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Testing](#testing)
- [Deployment](#deployment)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)

## Overview

This Kong Gateway setup provides:

- **JWT Verification**: Validates access token signatures and expiration using Kong's built-in JWT plugin
- **Token Revocation**: Custom Lua plugin checks JTI blacklist via Redis with PostgreSQL fallback
- **Rate Limiting**: Global request throttling (1000/minute, 10000/hour)
- **Service Routing**: Unified entry point with `/public` and `/private` route patterns
- **Observability**: Request correlation, structured logging, and Prometheus metrics

### Flow Diagram

```
Client Request
    ↓
Kong Gateway (Port 8000)
    ↓
├─ Rate Limiting (Global)
├─ JWT Plugin (private routes only)
├─ JTI Blacklist Checker (private routes only)
    ↓
Backend Microservice (auth-ms, user-ms, etc.)
```

## Architecture

### Components

1. **Kong Gateway** (DB-less, declarative config)
   - Entry point for all API requests
   - Enforces authentication and authorization
   - Routes traffic to backend services

2. **Custom Lua Plugin** (`jti-blacklist-checker`)
   - Checks token revocation status
   - Redis-first with PostgreSQL fallback
   - Configurable fail-closed/fail-open modes
   - Shadow mode for testing

3. **Shared Infrastructure**
   - **Redis**: Token cache (shared with platform-auth-ms)
   - **PostgreSQL**: Persistent storage and fallback queries
   - **Docker Network**: Service communication (`platform-network`)

### Route Pattern

**Simple and Clear:**

- **`/public/*`** → No authentication required
- **`/private/*`** → JWT + JTI verification required

**Examples:**
```
/public/authenticate/login       → No auth (login endpoint)
/public/user/register            → No auth (registration)
/private/user/profile            → JWT required
/private/authenticate/logout     → JWT required (revokes token)
```

## Features

### ✅ Built-in Kong JWT Plugin
- Signature verification (HS256)
- Expiration checking
- Claims validation

### ✅ Custom JTI Blacklist Plugin
- **Redis-first**: Fast token revocation check
- **PostgreSQL fallback**: Queries `revoked_access_token` table when Redis fails
- **Fail-closed by default**: Rejects requests on infrastructure errors
- **Shadow mode**: Test without blocking (logs only)
- **No schema changes**: Uses existing auth-ms database structure

### ✅ Global Rate Limiting
- 1000 requests/minute
- 10000 requests/hour
- Applied to ALL routes

### ✅ Request Correlation
- Automatic correlation ID generation
- Distributed tracing support

## Prerequisites

- **Docker & Docker Compose** (v3.9+)
- **Redis** instance (shared with auth-ms)
- **PostgreSQL** instance (shared with auth-ms)
- **Backend services** running (auth-ms, user-ms)
- **Network** connectivity between Kong and backend services

## Quick Start

### 1. Generate Environment Files

```bash
cd kong-api-gateway
./scripts/generate-env-files.sh
```

This creates:
- `.env.example`
- `.env.development`
- `.env.production`

### 2. Configure Environment

```bash
cp .env.development .env
```

Edit `.env` and set:
- `JWT_SIGNING_KEY` (MUST match auth-ms)
- Redis connection details
- PostgreSQL connection details
- Backend service URLs

### 3. Create Docker Network

```bash
docker network create platform-network
```

### 4. Validate Configuration

```bash
./scripts/validate-config.sh
```

### 5. Start Kong Gateway

```bash
docker-compose up --build -d
```

### 6. Verify Health

```bash
./scripts/health-check.sh
```

### 7. Run Tests

```bash
./scripts/test-kong.sh
```

## Configuration

### Environment Variables

**Kong Settings:**
```bash
KONG_DATABASE=off                    # DB-less mode
KONG_LOG_LEVEL=info                  # Log level (debug, info, warn, error)
KONG_NGINX_WORKER_PROCESSES=auto     # Worker processes
```

**Redis (Shared with auth-ms):**
```bash
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=
REDIS_DB=0
REDIS_TIMEOUT=2000
```

**PostgreSQL (Shared with auth-ms):**
```bash
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=seamtel
POSTGRES_USER=seamfix
POSTGRES_PASSWORD=k0l0
```

**JWT (MUST match auth-ms):**
```bash
JWT_SIGNING_KEY=your-secret-key
```

**Microservices:**
```bash
PLATFORM_AUTH_MS_URL=http://platform-auth-ms:3000
PLATFORM_USER_MS_URL=http://platform-user-ms:3000
```

**JTI Blacklist Plugin:**
```bash
JTI_REDIS_PREFIX=access:key
JTI_DB_FALLBACK_ENABLED=true
JTI_FAIL_CLOSED=true
JTI_SHADOW_MODE=false
```

**Rate Limiting:**
```bash
RATE_LIMIT_MINUTE=1000
RATE_LIMIT_HOUR=10000
```

### Modifying kong.yaml

The declarative configuration is in `config/kong.yaml`. After changes:

```bash
./scripts/validate-config.sh
docker-compose restart kong-gateway
```

## Testing

### Automated Test Suite

```bash
./scripts/test-kong.sh
```

Tests:
1. Kong health checks
2. Public routes (no auth)
3. JWT authentication
4. Token revocation
5. Rate limiting
6. Plugin configuration

### Individual Checks

**Redis connectivity:**
```bash
./scripts/redis-check.sh
```

**PostgreSQL connectivity:**
```bash
./scripts/db-check.sh
```

**Kong configuration validation:**
```bash
./scripts/validate-config.sh
```

### Manual Testing

**Test public route:**
```bash
curl http://localhost:8000/public/status
```

**Test login:**
```bash
TOKEN=$(curl -s -X POST http://localhost:8000/public/authenticate/login \
  -H "Content-Type: application/json" \
  -d '{
    "username": "user@example.com",
    "password": "base64-encoded-password",
    "accountId": "1234567890"
  }' | jq -r '.data.accessToken')
```

**Test protected route:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:8000/private/user/profile
```

**Test revocation:**
```bash
# Logout (revokes token)
curl -X POST http://localhost:8000/private/authenticate/logout \
  -H "Authorization: Bearer $TOKEN"

# Try revoked token (should get 401)
curl -i -H "Authorization: Bearer $TOKEN" \
  http://localhost:8000/private/user/profile
```

### Postman Collection

Import the collection and environments from `docs/postman/`:

1. **Kong-Gateway.postman_collection.json** - Full test suite
2. **Kong-Gateway-Dev.postman_environment.json** - Development environment
3. **Kong-Gateway-Prod.postman_environment.json** - Production environment

Collection includes:
- Public endpoint tests
- Private endpoint tests with auto-token management
- Token revocation flow tests
- Rate limiting tests
- Kong Admin API tests

## Deployment

### Local Development

```bash
# Use development environment
cp .env.development .env

# Start services
docker-compose up --build -d

# View logs
docker-compose logs -f kong-gateway

# Stop services
docker-compose down
```

### Production

```bash
# Use production environment
cp .env.production .env

# Edit production values
nano .env

# Start with production compose file
docker-compose -f docker-compose.prod.yml up -d

# Check status
docker-compose -f docker-compose.prod.yml ps
```

### Phase Rollout Strategy

Deploy Kong in phases to minimize risk:

#### Phase 0: Routing Only (Week 1)
- Routes configured
- JWT and JTI plugins **disabled**
- Rate limiting enabled
- **Goal**: Verify traffic routing

#### Phase 1: JWT Verification (Week 2)
- JWT plugin **enabled**
- JTI blacklist plugin **still disabled**
- **Goal**: Enforce token signature and expiration

#### Phase 2: Shadow JTI Blacklist (Week 3)
- JTI blacklist plugin enabled in **shadow mode**
- Logs revoked tokens but doesn't block
- **Goal**: Test revocation checking without impact

#### Phase 3: Enforced JTI Blacklist (Week 4+)
- JTI blacklist plugin in **enforce mode**
- Full enforcement of token revocation
- **Goal**: Complete security enforcement

## Monitoring

### Kong Admin API

Access Kong admin:
```bash
curl http://localhost:8001
```

**View status:**
```bash
curl http://localhost:8001/status
```

**View routes:**
```bash
curl http://localhost:8001/routes
```

**View plugins:**
```bash
curl http://localhost:8001/plugins
```

### Prometheus Metrics

Kong exposes metrics at:
```bash
curl http://localhost:8001/metrics
```

**Key metrics:**
- `kong_http_status` - HTTP response codes
- `kong_latency` - Request latency
- `kong_bandwidth` - Data transferred

### Logs

View Kong logs:
```bash
docker logs kong-gateway -f
```

Filter for JTI blacklist events:
```bash
docker logs kong-gateway 2>&1 | grep "JTI-BLACKLIST"
```

## Troubleshooting

### Kong Won't Start

**Check configuration:**
```bash
./scripts/validate-config.sh
```

**Check logs:**
```bash
docker logs kong-gateway
```

**Check port conflicts:**
```bash
lsof -i :8000
lsof -i :8001
```

### 401 Unauthorized on Valid Token

**Verify JWT signing key matches auth-ms:**
```bash
# In Kong .env
grep JWT_SIGNING_KEY .env

# In auth-ms .env
grep JWT_SIGNING_KEY ../src/env/.env
```

**Check Redis connectivity:**
```bash
./scripts/redis-check.sh
```

**Check if token exists in Redis:**
```bash
redis-cli GET "access:key:YOUR-JTI-HERE"
```

### All Tokens Rejected (ACCESS_TOKEN_REVOKED)

**Check Redis key prefix:**
- Kong uses: `access:key`
- Auth-ms uses: Check `environment.ts` → `accessRedisPrefix`

**Check plugin logic:**
- Active tokens HAVE Redis keys
- Revoked tokens have keys DELETED

### Rate Limiting Not Working

**Check global plugin configuration in kong.yaml:**
```yaml
plugins:
  - name: rate-limiting
    config:
      minute: 1000
      hour: 10000
      policy: local
```

**Trigger rate limit:**
```bash
for i in {1..1500}; do curl http://localhost:8000/public/status; done
```

### Database Fallback Not Working

**Test PostgreSQL connection:**
```bash
./scripts/db-check.sh
```

**Verify table exists:**
```bash
psql -h localhost -U seamfix -d seamtel \
  -c "SELECT COUNT(*) FROM revoked_access_token"
```

## Documentation

- **[Developer Guide](docs/DEVELOPER_GUIDE.md)** - Adding services, routes, and modifying plugins
- **[Admin Guide](docs/ADMIN_GUIDE.md)** - Operations, monitoring, and incident response
- **[Service Integration Guide](docs/SERVICE_INTEGRATION.md)** - How other teams integrate their microservices
- **[Swagger/OpenAPI](docs/swagger.yaml)** - Complete API documentation
- **[Postman Collection](docs/postman/)** - Comprehensive test suite

## Support

- **Kong Documentation**: https://docs.konghq.com/
- **Plugin Development**: https://docs.konghq.com/gateway/latest/plugin-development/
- **Internal Issues**: Create ticket in project management system

## Version History

- **v1.0.0** (2024-11-02)
  - Initial implementation
  - DB-less Kong setup (v3.4)
  - Custom JTI blacklist plugin with Redis/PostgreSQL fallback
  - Global rate limiting
  - `/public` and `/private` route patterns
  - Comprehensive test suite and documentation
  - Support for auth-ms and user-ms

## License

Internal use only - Seamfix Platform Team

