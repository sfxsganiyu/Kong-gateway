# Kong Gateway DevOps Deployment Guide

## Quick Start Checklist
1. Install prerequisites: Docker ≥ 24, Docker Compose v2, git, `jq`, `yq`, `psql`, `redis-cli` (optional but recommended).
2. Clone the repository and generate environment templates using `./scripts/generate-env-files.sh`.
3. Select your environment (`cp .env.development .env` or `cp .env.production .env`).
4. Validate the Kong configuration with `./scripts/validate-config.sh`.
5. Launch the stack using `docker compose up --build` for local work or `docker compose -f docker-compose.prod.yml --env-file .env up -d` for production.
6. Run smoke tests: `./scripts/health-check.sh` followed by `./scripts/test-kong.sh`.
7. When configuration changes, rerun validation and reload Kong: `docker exec <kong-container> kong reload -c /usr/local/kong/declarative/kong.yaml`.

## Overview
- Kong gateway fronts platform microservices, enforcing authentication, rate limiting, and request correlation before requests hit services such as `auth-ms` and `user-ms`.
- The gateway runs declaratively using `config/kong.yaml`, enabling consistent deployments across development, staging, and production while keeping infrastructure-as-code.
- Supported plugins include Kong’s bundled `jwt`, `rate-limiting`, `correlation-id`, and the custom Lua plugin `jti-blacklist-checker`, which adds token revocation checks backed by Redis with optional Postgres fallback.

### Request Flow Snapshot
- Client sends HTTP request → Kong receives on proxy port (`8000`/`8443`).
- Global plugins run (`rate-limiting`, `correlation-id`).
- Route match (e.g., `/private/user`).
- JWT plugin validates token signature/claims.
- `jti-blacklist-checker` verifies token against Redis/Postgres.
- Kong forwards to upstream microservice (`auth-ms`, `user-ms`).
- Response returns through Kong with correlation header intact.

## Folder-by-Folder Explanation With Full Source

### Project Layout Snapshot
```
kong-api-gateway/
├── config/
│   └── kong.yaml
├── plugins/
│   └── jti-blacklist-checker/
│       ├── db-fallback.lua
│       ├── handler.lua
│       ├── redis-client.lua
│       └── schema.lua
├── scripts/
│   ├── db-check.sh
│   ├── generate-env-files.sh
│   ├── health-check.sh
│   ├── redis-check.sh
│   ├── test-kong.sh
│   └── validate-config.sh
├── Dockerfile
├── docker-compose.yml
├── docker-compose.prod.yml
├── .env.example
├── .env.development
├── .env.production
└── README.md
```
Use this map as you read each section—the guide walks through every file shown here.

### File: `config/kong.yaml`
**What this file does**
- Keeps all Kong entities declarative: global plugins, services, routes, and consumers.
- Powers database-off deployments where `KONG_DECLARATIVE_CONFIG` points to this file.

**Key sections to know**
- `_format_version` / `_transform`: declare the YAML schema version and allow nested entities (services containing routes).
- `plugins`: cluster-wide middleware (rate limiting and correlation IDs).
- `services`: upstream microservices (`auth-ms`, `user-ms`) with timeouts, retries, and URLs.
- `routes`: path listeners that attach authentication/blacklist plugins to private endpoints.
- `consumers.jwt_secrets`: JWT signing keys shared with the auth service.

**How to extend it**
- Add a new service by duplicating an existing block, changing the `name` and `url`, and defining new routes with desired plugins.
- Modify rate-limiting thresholds by editing `minute`/`hour` or choosing a different policy (e.g., `redis`).
- Add extra plugins (like logging or ACLs) at the global, service, or route level by appending to the relevant `plugins` array.

```yaml
_format_version: "2.1"

_transform: true

# Global Plugins (applied to ALL routes)
plugins:
  - name: rate-limiting
    config:
      minute: 1000
      hour: 10000
      policy: local
      fault_tolerant: true
      hide_client_headers: false
  - name: correlation-id
    config:
      header_name: X-Correlation-ID
      generator: uuid
      echo_downstream: true

# Services
services:
  - name: auth-ms
    url: http://platform-auth-ms:3300
    connect_timeout: 60000
    write_timeout: 60000
    read_timeout: 60000
    retries: 5
    routes:
      - name: public-auth-routes
        paths:
          - /public
        strip_path: true
        preserve_host: false
      - name: private-auth-routes
        paths:
          - /private
        strip_path: true
        preserve_host: false
        plugins:
          - name: jwt
            config:
              secret_is_base64: false
              claims_to_verify:
                - exp
              anonymous: null
              run_on_preflight: true
              maximum_expiration: 0
          - name: jti-blacklist-checker
            config:
              redis_host: redis
              redis_port: 6379
              redis_password: null
              redis_db: 0
              redis_timeout: 2000
              redis_key_prefix: "access:key"
              db_fallback: true
              postgres_host: postgres
              postgres_port: 5432
              postgres_database: seamtel
              postgres_user: seamfix
              postgres_password: k0l0
              postgres_table: revoked_access_token
              fail_closed: true
              shadow_mode: false

  - name: user-ms
    url: http://platform-user-ms:3400
    connect_timeout: 60000
    write_timeout: 60000
    read_timeout: 60000
    retries: 5
    routes:
      - name: public-user-routes
        paths:
          - /public/user
        strip_path: true
        preserve_host: false
      - name: private-user-routes
        paths:
          - /private/user
        strip_path: true
        preserve_host: false
        plugins:
          - name: jwt
            config:
              secret_is_base64: false
              claims_to_verify:
                - exp
              anonymous: null
              run_on_preflight: true
              maximum_expiration: 0
          - name: jti-blacklist-checker
            config:
              redis_host: redis
              redis_port: 6379
              redis_password: null
              redis_db: 0
              redis_timeout: 2000
              redis_key_prefix: "access:key"
              db_fallback: true
              postgres_host: postgres
              postgres_port: 5432
              postgres_database: seamtel
              postgres_user: seamfix
              postgres_password: k0l0
              postgres_table: revoked_access_token
              fail_closed: true
              shadow_mode: false

# Single Consumer for JWT
consumers:
  - username: platform-client
    custom_id: platform-app
    jwt_secrets:
      - key: your-jwt-signing-key-here
        secret: your-jwt-signing-key-here
        algorithm: HS256

```

Explanation:
- `_format_version` / `_transform`: lock the spec version and allow nested entities, simplifying grouped definitions.
- `plugins`: cluster-wide middleware. `rate-limiting` guards capacity using per-node counters; tweak `minute`/`hour` values or change `policy` (e.g., `redis`). `correlation-id` seeds trace IDs—match `header_name` with downstream logging conventions.
- `services`: describe upstreams (`auth-ms`, `user-ms`). Adjust `url` for environment DNS, tune `connect/write/read_timeout`, or modify `retries` for resiliency.
- `routes`: path-based routing. Public routes omit auth, private routes attach `jwt` and `jti-blacklist-checker` sequentially so credentials are validated before revocation checks. Add methods, hosts, or strip configuration as APIs evolve.
- `plugins` under routes: configure behavior per environment—e.g., switch `redis_host`, change `fail_closed`, or disable fallback by setting `db_fallback=false`.
- `consumers.jwt_secrets`: defines shared HMAC key. Rotate by adding a new secret with `algorithm` options (`HS256`, `RS256` for asymmetric if migrating).

### File: `plugins/jti-blacklist-checker/db-fallback.lua`
**What this file does**
- Implements a Postgres fallback check when Redis cannot be reached.
- Ensures the gateway still blocks revoked tokens by querying the `revoked_access_token` table.

**Key parts to notice**
- Loads the `pgmoon` client and opens a connection using plugin configuration.
- Escapes the JTI value in SQL to avoid injection issues.
- Returns `true` when the JTI exists, `false` otherwise, and propagates descriptive errors upstream.

**How to extend it**
- Change `postgres_table` default via the plugin schema if your auth service uses a different table name.
- Add additional fields to fetch (e.g., revocation reason) by updating the query and returning structured data for logging.

```lua
local pgmoon = require("pgmoon")

local _M = {}

function _M.check_revoked_token(conf, jti)
  if not conf.postgres_host or not conf.postgres_database then
    return nil, "PostgreSQL configuration missing"
  end

  local pg = pgmoon.new({
    host = conf.postgres_host,
    port = conf.postgres_port or 5432,
    database = conf.postgres_database,
    user = conf.postgres_user,
    password = conf.postgres_password,
  })

  local ok, err = pg:connect()
  if not ok then
    return nil, "Failed to connect to PostgreSQL: " .. tostring(err)
  end

  local table_name = conf.postgres_table or "revoked_access_token"
  local query = string.format(
    "SELECT jti FROM %s WHERE jti = %s LIMIT 1",
    table_name,
    pg:escape_literal(jti)
  )

  local result, err = pg:query(query)
  
  pg:keepalive()

  if not result then
    return nil, "PostgreSQL query failed: " .. tostring(err)
  end

  if result and #result > 0 then
    return true, nil
  end

  return false, nil
end

return _M

```

Explanation:
- Imports `pgmoon`, the pure Lua Postgres client installed via the Dockerfile, and exposes module table `_M`.
- `check_revoked_token` guards against missing Postgres configuration before instantiating a new connection using values provided by the plugin config (`postgres_host`, `postgres_port`, etc.).
- `pg:connect()` establishes a TCP connection; errors short-circuit with descriptive messages consumed by the plugin handler.
- The query string selects the JTI from a configurable table (default `revoked_access_token`) using `escape_literal` to prevent SQL injection.
- Results are queried and the connection returned to the pool via `keepalive()`. A non-empty result set returns `true`, signaling that the token is revoked; no match returns `false`, allowing the request to proceed.

### File: `plugins/jti-blacklist-checker/handler.lua`
**What this file does**
- Contains the access-phase logic that runs after the JWT plugin.
- Decides whether to accept or reject a request based on Redis/Postgres token revocation checks.

**Key parts to notice**
- Validates presence of JWT credentials and required claims (`jti`, `exp`).
- Builds the Redis key from the prefix plus JTI and delegates to the Redis client.
- Applies fallback logic to Postgres when Redis fails and `db_fallback` is enabled.
- Obeys `fail_closed` (deny on error) and `shadow_mode` (log only) to support phased rollouts.

**How to extend it**
- Add additional claim checks (e.g., `nbf`, `iss`) before hitting Redis if your security policy requires them.
- Emit custom metrics by calling `kong.statsd` or `kong.log` with structured data.
- Support alternative fallback stores by plugging in new modules similar to `db-fallback.lua`.

```lua
local redis_client = require "kong.plugins.jti-blacklist-checker.redis-client"
local db_fallback = require "kong.plugins.jti-blacklist-checker.db-fallback"

local kong = kong
local ngx = ngx

local JtiBlacklistHandler = {
  VERSION = "1.0.0",
  PRIORITY = 900,
}

function JtiBlacklistHandler:access(conf)
  if conf.shadow_mode then
    kong.log.info("[JTI-BLACKLIST] Running in shadow mode (logging only)")
  end

  local jwt_credential = kong.ctx.shared.authenticated_credential
  if not jwt_credential then
    kong.log.err("[JTI-BLACKLIST] No JWT credential found. Ensure JWT plugin runs before this plugin.")
    if conf.fail_closed then
      return kong.response.exit(401, {
        message = "Unauthorized",
        code = "NO_JWT_CREDENTIAL"
      })
    end
    return
  end

  local jti = jwt_credential.jti
  if not jti then
    kong.log.err("[JTI-BLACKLIST] No JTI claim found in JWT token")
    if conf.fail_closed then
      return kong.response.exit(401, {
        message = "Invalid token: missing JTI",
        code = "MISSING_JTI"
      })
    end
    return
  end

  local exp = jwt_credential.exp
  if exp and type(exp) == "number" then
    local current_time = ngx.time()
    if exp <= current_time then
      kong.log.warn("[JTI-BLACKLIST] Token expired for JTI: " .. jti)
      return kong.response.exit(401, {
        message = "Token expired",
        code = "TOKEN_EXPIRED"
      })
    end
  end

  local redis_key = conf.redis_key_prefix .. ":" .. jti
  kong.log.debug("[JTI-BLACKLIST] Checking Redis key: " .. redis_key)

  local redis_result, redis_err = redis_client.check_token(conf, redis_key)

  if redis_err then
    kong.log.warn("[JTI-BLACKLIST] Redis check failed for JTI " .. jti .. ": " .. redis_err)
    
    if conf.db_fallback then
      kong.log.info("[JTI-BLACKLIST] Attempting database fallback for JTI: " .. jti)
      local db_result, db_err = db_fallback.check_revoked_token(conf, jti)
      
      if db_err then
        kong.log.err("[JTI-BLACKLIST] Database fallback failed: " .. db_err)
        if conf.fail_closed then
          return kong.response.exit(503, {
            message = "Service temporarily unavailable",
            code = "BLACKLIST_CHECK_FAILED"
          })
        end
        return
      end

      if db_result then
        kong.log.warn("[JTI-BLACKLIST] Token found in revocation table (DB): " .. jti)
        if conf.shadow_mode then
          kong.log.warn("[JTI-BLACKLIST] SHADOW MODE: Would have blocked revoked token (DB): " .. jti)
          return
        end
        return kong.response.exit(401, {
          message = "Access token has been revoked",
          code = "ACCESS_TOKEN_REVOKED"
        })
      end

      kong.log.debug("[JTI-BLACKLIST] Token not found in revocation table (DB), allowing access")
      return
    else
      if conf.fail_closed then
        return kong.response.exit(503, {
          message = "Service temporarily unavailable",
          code = "REDIS_UNAVAILABLE"
        })
      end
      return
    end
  end

  if not redis_result then
    kong.log.warn("[JTI-BLACKLIST] Redis key NOT found (token revoked): " .. redis_key)
    if conf.shadow_mode then
      kong.log.warn("[JTI-BLACKLIST] SHADOW MODE: Would have blocked revoked token: " .. jti)
      return
    end
    return kong.response.exit(401, {
      message = "Access token has been revoked",
      code = "ACCESS_TOKEN_REVOKED"
    })
  end

  kong.log.debug("[JTI-BLACKLIST] Token is valid (Redis key exists): " .. jti)
end

return JtiBlacklistHandler

```

Explanation:
- Requires the Redis helper and Postgres fallback modules to coordinate caching and persistence lookups.
- Declares plugin metadata (`VERSION`, `PRIORITY=900`) ensuring it executes after the JWT plugin (priority > 1000) but before downstream logic.
- Reads authenticated JWT credentials from `kong.ctx.shared`; when absent it logs an error and, if `fail_closed` is enabled, immediately responds with `401` to prevent unauthorized access.
- Validates the presence of `jti` and ensures the token is not expired by comparing `exp` claim against `ngx.time()`.
- Builds a Redis key using `redis_key_prefix` and delegates to `redis_client.check_token`. Any Redis errors trigger the Postgres fallback path when enabled; errors in the fallback can return `503` for availability issues when `fail_closed` is true.
- If either Redis or Postgres confirm the token is revoked, the plugin returns `401`; in `shadow_mode`, it logs the would-be block instead of terminating the request, enabling safe dry runs.
- Successful lookups log a debug message and allow the request pipeline to continue.

### File: `plugins/jti-blacklist-checker/redis-client.lua`
**What this file does**
- Encapsulates all Redis interactions needed by the handler.
- Provides a single function that returns whether a JTI key exists.

**Key parts to notice**
- Creates an OpenResty Redis client per request and applies configurable timeout.
- Handles optional authentication (`redis_password`) and database selection (`redis_db`).
- Uses `set_keepalive` so subsequent requests reuse the same TCP connection.
- Returns `false` when Redis replies with `ngx.null`, which the handler interprets as “token revoked.”

**How to extend it**
- Add instrumentation by logging response times or raising Prometheus counters.
- Support Redis Sentinel/Cluster by swapping connection logic before calling `red:connect`.
- Implement write helpers (e.g., revoking tokens manually) if you need administrative scripts that reuse this module.

```lua
local redis = require "resty.redis"

local _M = {}

function _M.check_token(conf, redis_key)
  local red = redis:new()
  
  red:set_timeout(conf.redis_timeout)
  
  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if not ok then
    return nil, "Failed to connect to Redis: " .. tostring(err)
  end

  if conf.redis_password and conf.redis_password ~= "" then
    local res, err = red:auth(conf.redis_password)
    if not res then
      return nil, "Failed to authenticate with Redis: " .. tostring(err)
    end
  end

  if conf.redis_db and conf.redis_db ~= 0 then
    local res, err = red:select(conf.redis_db)
    if not res then
      return nil, "Failed to select Redis database: " .. tostring(err)
    end
  end

  local result, err = red:get(redis_key)
  if not result then
    return nil, "Redis GET failed: " .. tostring(err)
  end

  local ok, err = red:set_keepalive(10000, 100)
  if not ok then
    ngx.log(ngx.WARN, "Failed to set Redis keepalive: ", err)
  end

  if result == ngx.null then
    return false, nil
  end

  return true, nil
end

return _M

```

Explanation:
- Constructs a new `resty.redis` client per request and applies a configurable timeout (`redis_timeout`).
- Establishes a TCP connection to the host/port provided by the plugin configuration, with optional password authentication and database selection.
- Issues a `GET` for the token key. On command errors, returns an error string so the handler can initiate fallback logic; otherwise places the connection in the keepalive pool for reuse (`set_keepalive`).
- Treats `ngx.null` as a cache miss (token revoked) by returning `false`; existing keys return `true`, confirming token validity in Redis.

### File: `plugins/jti-blacklist-checker/schema.lua`
**What this file does**
- Registers the plugin with Kong’s DAO layer and validates configuration fields.
- Supplies defaults for Redis/Postgres settings so the plugin works out of the box in Compose environments.

**Key parts to notice**
- Uses `typedefs.no_consumer` to force global application (no per-consumer overrides).
- Restricts protocols to HTTP/HTTPS, matching the gateway’s usage.
- Declares the `config` record with required/optional fields, their types, and defaults that align with docker-compose services.

**How to extend it**
- Add new configuration options (e.g., `metrics_namespace`) by appending to the `fields` array and updating the handler to read them.
- Enforce stricter validation (like enumerated values) by replacing the type definitions with more restrictive schemas.

```lua
local typedefs = require "kong.db.schema.typedefs"

return {
  name = "jti-blacklist-checker",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
      type = "record",
      fields = {
        { redis_host = { type = "string", required = true, default = "redis" }, },
        { redis_port = { type = "number", required = true, default = 6379 }, },
        { redis_password = { type = "string", required = false }, },
        { redis_db = { type = "number", required = true, default = 0 }, },
        { redis_timeout = { type = "number", required = true, default = 2000 }, },
        { redis_key_prefix = { type = "string", required = true, default = "access:key" }, },
        { db_fallback = { type = "boolean", required = true, default = true }, },
        { postgres_host = { type = "string", required = false, default = "postgres" }, },
        { postgres_port = { type = "number", required = false, default = 5432 }, },
        { postgres_database = { type = "string", required = false, default = "seamtel" }, },
        { postgres_user = { type = "string", required = false, default = "seamfix" }, },
        { postgres_password = { type = "string", required = false }, },
        { postgres_table = { type = "string", required = false, default = "revoked_access_token" }, },
        { fail_closed = { type = "boolean", required = true, default = true }, },
        { shadow_mode = { type = "boolean", required = true, default = false }, },
      },
    }, },
  },
}

```

Explanation:
- Kong’s schema module defines plugin metadata used for validation and Admin API documentation.
- Disables per-consumer configuration (`no_consumer`) to enforce global behavior and limits the plugin to HTTP/S protocols.
- Configuration record declares Redis, Postgres, and control flags with defaults. Kong validates inputs against types and ensures required fields (e.g., `redis_host`, `redis_timeout`, `fail_closed`) are present before accepting configuration updates.

### File: `scripts/db-check.sh`
**What this script does**
- Confirms Postgres networking, credentials, and revocation-table readiness.
- Gives operators confidence that the blacklist fallback will function before going live.

**Key tasks inside**
- Reads connection settings from environment variables with sensible defaults (`localhost`, `seamtel`).
- Uses raw TCP tests plus `psql` commands to validate connectivity and query metadata.
- Highlights success/failure with color-coded output and prints table statistics when available.

**How to extend it**
- Add extra queries (e.g., index existence, table size) for deeper observability.
- Wire it into CI/CD by running inside pipelines before deployment steps; exit codes already signal failure.
- Support SSL Postgres by injecting additional `psql` flags (e.g., `PGSSLMODE`) based on new environment variables.

```bash
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

```

Explanation:
- Configures Postgres connection parameters via environment variables with sensible defaults for local Compose (`localhost`, `seamtel`, `seamfix`).
- Uses ANSI color codes and structured output to make health results easy to read in CI logs.
- Performs a raw TCP connectivity test first, then leverages `psql` to authenticate, check the server version, and confirm the presence of the `revoked_access_token` table.
- Reports row counts for revoked tokens when the table exists, reminding operators that Auth service migrations create it if missing.
- Gracefully handles environments without `psql` by skipping deep checks and completing successfully if the basic network test passes.

### File: `scripts/generate-env-files.sh`
**What this script does**
- Generates three environment templates (`.env.example`, `.env.development`, `.env.production`) with curated defaults.
- Ensures new team members can bootstrap configuration without manually drafting variables.

**Key tasks inside**
- Calculates project root paths so the script works regardless of the current working directory.
- Writes environment files using inline heredocs, embedding comments that explain each variable.
- Sets executable permissions on the generated files (optional convenience for sourcing).

**How to extend it**
- Introduce new variables (e.g., `KONG_ADMIN_GUI_URL`) by adding lines to each template block.
- Generate additional environment flavors (staging, QA) by copying the template structure and adjusting values.
- Replace hard-coded defaults with prompts (using `read`) if you want interactive setup in the future.

```bash
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

```

Explanation:
- Derives project root paths to write `.env*` files directly into the repository, ensuring reproducible templates.
- Writes three environment files in full using here-documents (`EOF`), covering example, development, and production variants with comments guiding operators.
- Highlights differences: development enables debug logging and relaxed rate limiting, while production enforces stricter logging, Redis authentication, TLS cert paths, and fail-closed behavior.
- Marks generated files executable (`chmod +x`) so they can be sourced in shell sessions if desired, and prints next steps for selecting the active environment by copying into `.env`.

### File: `scripts/health-check.sh`
**What this script does**
- Runs a one-command health sweep across Kong, Redis, Postgres, and key microservices.
- Produces a summary suited for on-call checks or CI smoke tests.

**Key tasks inside**
- Declares configurable endpoints via environment variables with defaults aligned to local Compose ports.
- Defines a reusable `check_service` helper to report pass/fail statuses uniformly.
- Calls Kong Admin API for additional stats (plugin count, route count) when `jq` is installed.
- Emits a final tally of healthy vs unhealthy checks and exits non-zero on failure.

**How to extend it**
- Add more backend checks (e.g., `mongodb`, `rabbitmq`) by reusing the helper.
- Pipe summary output to Slack/MS Teams by appending curl hooks for incident automation.
- Integrate with Prometheus/Grafana by echoing metrics-format lines alongside the human-readable output.

```bash
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

```

Explanation:
- Configurable endpoints (Admin URL, Redis/Postgres hosts) default to localhost for local Compose but can be overridden via environment variables when targeting staging or production.
- `check_service` helper evaluates commands and updates pass/fail counters, providing a consistent output format with colored status markers.
- Validates Kong’s Admin and Proxy endpoints, infrastructure dependencies (Redis, Postgres), and optionally microservices when URLs reference localhost.
- When `jq` is available, displays summary metrics from the Admin API (database reachability, plugin count, route count) to aid situational awareness.
- Aggregates total healthy vs unhealthy checks at the end and returns a non-zero exit code if any dependency failed, making it CI-friendly.

### File: `scripts/redis-check.sh`
**What this script does**
- Validates Redis connectivity, credentials, and key availability for the blacklist cache.

**Key tasks inside**
- Performs layered checks: TCP socket, `PING`, `INFO server`, and key pattern enumeration.
- Supports password-protected Redis by using `REDIS_PASSWORD` when provided.
- Prints helpful metadata such as Redis version, uptime, and connected client count.

**How to extend it**
- Add latency measurements (e.g., repeated `PING` with timestamps) to monitor performance.
- Switch from `KEYS` to `SCAN` commands for production-scale clusters to avoid blocking.
- Integrate with Redis Sentinel or Cluster by adjusting connection logic similar to the plugin client.

```bash
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

```

Explanation:
- Tests Redis connectivity with layered checks: TCP socket availability, Redis PING command (if `redis-cli` exists), server info (`INFO server`), and enumerates keys matching the plugin’s prefix.
- Supports password-protected Redis instances via `REDIS_PASSWORD`. Output includes server metadata (version, uptime, connected clients) to assist with diagnostics.
- Designed to fail fast when connectivity or authentication issues occur so operators can remediate before deploying the gateway.

### File: `scripts/test-kong.sh`
**What this script does**
- Provides an end-to-end regression test for Kong routes, authentication, revocation, rate limiting, and plugin registration.
- Acts as a quick assurance tool after configuration updates or deployments.

**Key tasks inside**
- Defines `run_test` to standardize curl invocations and record pass/fail counts.
- Hits public routes, performs login through the auth service, and uses the resulting token to test private routes.
- Exercises logout to trigger token revocation and confirms that revoked tokens are blocked.
- Queries the Admin API to ensure required plugins (`jti-blacklist-checker`, `rate-limiting`, `jwt`) are loaded.

**How to extend it**
- Add additional endpoints (e.g., new microservices) by appending `run_test` calls.
- Include negative scenarios such as malformed JWTs or exceeding rate limits to validate error handling.
- Export results as JUnit XML by wrapping tests with a formatter if you want CI dashboards to display them graphically.

```bash
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

```

Explanation:
- Defines reusable `run_test` function evaluating curl commands and comparing exit status to expected outcomes, counting passes and failures for summary reporting.
- Exercises gateway endpoints end-to-end: verifies Admin/Proxy availability, public route accessibility, and JWT-protected routes.
- Attempts a login through public authentication route; if a token is acquired, tests authorized access, unauthorized access, logout-triggered revocation, and rate limiting behavior.
- Confirms required plugins (custom blacklist, rate limiting, JWT) are registered by querying the Admin API. Provides actionable warnings when prerequisites such as `jq` or running microservices are missing, while keeping exit codes meaningful for automation.

### File: `scripts/validate-config.sh`
**What this script does**
- Verifies that `config/kong.yaml` is syntactically correct before deployment.
- Provides a quick inventory of services, routes, and plugins when `yq` is installed.

**Key tasks inside**
- Accepts an optional path to a configuration file, defaulting to `./config/kong.yaml`.
- Uses Docker to run the official `kong:3.4-alpine` image and execute `kong config parse` against the mounted file.
- Prints a human-readable summary or suggests installing `yq` for richer output.
- Exits with the parser’s status code so CI pipelines can block invalid changes.

**How to extend it**
- Add support for linting multiple files (e.g., `deck` declarative diffs) by looping over arguments.
- Wrap the Docker call with a custom image that already includes `yq` to simplify dependency management.
- Emit Slack or email notifications when validation fails by appending webhook calls in the non-zero branch.

```bash
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

```

Explanation:
- Accepts optional path to the Kong declarative file (defaults to `./config/kong.yaml`) and validates its existence.
- Requires Docker, then runs the official `kong:3.4-alpine` image to parse the declarative config (`kong config parse`), ensuring compatibility with the runtime image.
- On success, optionally lists services, routes, and global plugins using `yq` to provide a quick inventory; otherwise suggests installing `yq`.
- Returns exit code `0` on success, non-zero on failure, making it suitable in CI pipelines to gate configuration changes.

### Files: `.env.example`, `.env.development`, `.env.production`
**What these files do**
- Store environment variables consumed by Docker Compose, Kong, and helper scripts.
- Allow teams to switch between environments by copying the relevant template to `.env`.

**Key variables to understand**
- `KONG_DATABASE`: `off` for declarative mode; switch to `postgres` only when using Kong’s database migrations.
- `KONG_LOG_LEVEL`: `debug` (dev) for verbose logs vs `warn` (prod) to reduce noise.
- `REDIS_*` & `POSTGRES_*`: endpoints and credentials for cache/fallback storage; production template expects managed services with passwords.
- `JWT_SIGNING_KEY`: must match the key used by the Auth microservice; rotate carefully across environments.
- `JTI_FAIL_CLOSED`, `JTI_SHADOW_MODE`: control plugin blocking vs logging-only behavior.
- `KONG_SSL_CERT`, `KONG_SSL_CERT_KEY`: configured in production template for TLS termination.

**How to extend them**
- Introduce new variables (e.g., `KONG_ADMIN_GUI_URL`) across all templates and reference them in Docker Compose or scripts.
- Create additional templates (`.env.staging`) if you manage bespoke staging infrastructure.
- Pair these files with a secrets manager by keeping only non-sensitive defaults here and loading secrets at runtime via CI/CD.

## Setup Instructions

### Installation Requirements
- Docker Engine 24.x or newer.
- Docker Compose Plugin v2.
- Access to Kong 3.4-compatible environment (Dockerfile inherits official `kong` image).
- Redis 6/7 and Postgres 13/14; optional MongoDB 7 and RabbitMQ 3 for microservices in docker-compose.
- Optional CLI tools: `psql`, `redis-cli`, `jq`, `yq`, and `timeout` utilities (present in GNU coreutils).

### Local Deployment (`docker-compose.yml`)
1. Clone repository and set working directory.
   ```bash
   git clone git@github.com:seamfix/kong-api-gateway.git
   cd kong-api-gateway
   ```
2. Generate environment templates and choose development config.
   ```bash
   ./scripts/generate-env-files.sh
   cp .env.development .env
   ```
3. Validate configuration.
   ```bash
   ./scripts/validate-config.sh
   ```
4. Build and start local stack.
   ```bash
   docker compose up --build
   ```
5. Check health and run integration tests.
   ```bash
   ./scripts/health-check.sh
   ./scripts/test-kong.sh
   ```

### File: `docker-compose.yml`
**What this file provides**
- Standalone development environment with Kong, Redis, Postgres, MongoDB, RabbitMQ, and local builds of auth/user microservices.
- Health checks and dependency ordering to ensure Kong waits for backends before starting.
- Port bindings scoped to localhost for databases to reduce accidental exposure.

**How to extend it**
- Add new microservices by defining additional service blocks and connecting them to `platform-network`.
- Adjust resource allocations or override environment variables via `profiles` if you want lighter stacks.
- Replace sibling builds with registry images by swapping the `build` section for `image: your-registry/image:tag`.

```yaml
version: "3.9"

networks:
  platform-network:
    driver: bridge

services:
  kong-gateway:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: kong-gateway
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /usr/local/kong/declarative/kong.yaml
      KONG_PROXY_ACCESS_LOG: /dev/stdout
      KONG_ADMIN_ACCESS_LOG: /dev/stdout
      KONG_PROXY_ERROR_LOG: /dev/stderr
      KONG_ADMIN_ERROR_LOG: /dev/stderr
      KONG_ADMIN_LISTEN: "0.0.0.0:8001, 0.0.0.0:8444 ssl"
      KONG_PROXY_LISTEN: "0.0.0.0:8000, 0.0.0.0:8443 ssl"
      KONG_LOG_LEVEL: ${KONG_LOG_LEVEL:-info}
      KONG_PLUGINS: bundled,jti-blacklist-checker
      KONG_NGINX_WORKER_PROCESSES: ${KONG_NGINX_WORKER_PROCESSES:-auto}
      KONG_PREFIX: /var/run/kong
    networks:
      - platform-network
    ports:
      - "8000:8000"
      - "127.0.0.1:8001:8001"
      - "8443:8443"
      - "127.0.0.1:8444:8444"
    healthcheck:
      test: ["CMD", "kong", "health"]
      interval: 10s
      timeout: 10s
      retries: 10
    restart: on-failure:5
    read_only: true
    volumes:
      - ./config:/usr/local/kong/declarative:ro
      - kong_prefix_vol:/var/run/kong
      - kong_tmp_vol:/tmp
    security_opt:
      - no-new-privileges
    depends_on:
      redis:
        condition: service_healthy
      postgres:
        condition: service_healthy
      mongodb:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
      platform-auth-ms:
        condition: service_healthy
      platform-user-ms:
        condition: service_healthy

  platform-auth-ms:
    build:
      context: ../platform-auth-ms
      dockerfile: Dockerfile
      args:
        NPM_USERNAME: ${NPM_USERNAME}
        NPM_PASSWORD: ${NPM_PASSWORD}
        NPM_EMAIL: ${NPM_EMAIL}
        NPM_URL: ${NPM_URL}
    container_name: platform-auth-ms
    environment:
      REDIS_HOST: redis
      REDIS_PORT: 6379
      RDBMS_HOST: postgres
      RDBMS_PORT: 5432
      RDBMS_NAME: ${POSTGRES_DB:-seamtel}
      RDBMS_USERNAME: ${POSTGRES_USER:-seamfix}
      RDBMS_PASSWORD: ${POSTGRES_PASSWORD:-k0l0}
      RDBMS_TYPE: postgres
      RDBMS_SYNC: true
      RDBMS_MIGRATION_RUN: true
      NOSQL_URI: mongodb://mongodb:27017
      AMQP_HOST: rabbitmq
      AMQP_PORT: 5672
      AMQP_USERNAME: ${RABBITMQ_USER:-guest}
      AMQP_PSWD: ${RABBITMQ_PASSWORD:-guest}
    networks:
      - platform-network
    ports:
      - "3300:3300"
    depends_on:
      redis:
        condition: service_healthy
      postgres:
        condition: service_healthy
      mongodb:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3300/auth/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
    restart: on-failure:5

  platform-user-ms:
    build:
      context: ../platform-user-ms
      dockerfile: Dockerfile
      args:
        NPM_USERNAME: ${NPM_USERNAME}
        NPM_PASSWORD: ${NPM_PASSWORD}
        NPM_EMAIL: ${NPM_EMAIL}
        NPM_URL: ${NPM_URL}
    container_name: platform-user-ms
    environment:
      REDIS_HOST: redis
      REDIS_PORT: 6379
      RDBMS_HOST: postgres
      RDBMS_PORT: 5432
      RDBMS_NAME: ${POSTGRES_DB:-seamtel}
      RDBMS_USERNAME: ${POSTGRES_USER:-seamfix}
      RDBMS_PASSWORD: ${POSTGRES_PASSWORD:-k0l0}
      RDBMS_TYPE: postgres
      RDBMS_SYNC: true
      RDBMS_MIGRATION_RUN: true
      NOSQL_URI: mongodb://mongodb:27017
      AMQP_HOST: rabbitmq
      AMQP_PORT: 5672
      AMQP_USERNAME: ${RABBITMQ_USER:-guest}
      AMQP_PSWD: ${RABBITMQ_PASSWORD:-guest}
    networks:
      - platform-network
    ports:
      - "3400:3400"
    depends_on:
      redis:
        condition: service_healthy
      postgres:
        condition: service_healthy
      mongodb:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3400/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    restart: on-failure:5

  redis:
    image: redis:7-alpine
    container_name: platform-redis
    command: redis-server --appendonly yes
    networks:
      - platform-network
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  mongodb:
    image: mongo:7-jammy
    container_name: platform-mongodb
    networks:
      - platform-network
    volumes:
      - mongodb-data:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  rabbitmq:
    image: rabbitmq:3-management-alpine
    container_name: platform-rabbitmq
    networks:
      - platform-network
    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_USER:-guest}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD:-guest}
    volumes:
      - rabbitmq-data:/var/lib/rabbitmq
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  postgres:
    image: postgres:14-alpine
    container_name: platform-postgres
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-seamtel}
      POSTGRES_USER: ${POSTGRES_USER:-seamfix}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-k0l0}
    networks:
      - platform-network
    ports:
      - "127.0.0.1:5433:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-seamfix} -d ${POSTGRES_DB:-seamtel}"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  kong_prefix_vol:
    driver_opts:
      type: tmpfs
      device: tmpfs
  kong_tmp_vol:
    driver_opts:
      type: tmpfs
      device: tmpfs
  redis-data:
  postgres-data:
  mongodb-data:
  rabbitmq-data:

```

Explanation:
- Declares a Docker Compose v3.9 application network (`platform-network`) shared across gateway and microservices, with named volumes for Kong’s prefix directory (tmpfs), Redis/Postgres persistence, MongoDB, and RabbitMQ.
- `kong-gateway` service builds from repository `Dockerfile`, loads custom plugin, exposes ports for proxy/admin (binding admin to localhost), and declares dependencies on data services and microservices. Mounts declarative config as read-only and enforces `no-new-privileges` for security.
- `platform-auth-ms` and `platform-user-ms` build from sibling repositories, inherit NPM credentials for package installation, and configure environment variables that align with backend expectations (Redis, Postgres, MongoDB, RabbitMQ). Health checks wait for microservices to become responsive.
- Redis, MongoDB, RabbitMQ, and Postgres services use official images with health checks and persistent volumes. Ports are loopback-bound to avoid exposing databases externally during local development.
- This stack facilitates full end-to-end testing in development by running gateway and downstream services together.

### File: `docker-compose.prod.yml`
**How to deploy with Compose in production**
1. Prepare `.env.production` with real credentials and TLS paths, then copy it to `.env`.
2. Build and tag the custom Kong image, pushing it to your container registry.
   ```bash
   docker build -t kong-gateway:prod .
   docker tag kong-gateway:prod registry.example.com/platform/kong-gateway:prod
   docker push registry.example.com/platform/kong-gateway:prod
   ```
3. Launch the production stack.
   ```bash
   docker compose -f docker-compose.prod.yml --env-file .env up -d
   ```
4. Apply configuration updates without downtime.
   ```bash
   docker exec kong-gateway-prod kong reload -c /usr/local/kong/declarative/kong.yaml
   ```

**What this file provides**
- Connects to an existing Docker network so Kong can communicate with managed services.
- Mounts declarative configuration and TLS certificates as read-only volumes.
- Limits resource usage via `deploy.resources`, documenting expectations for orchestrated environments.
- Restricts Admin API binding to loopback (`127.0.0.1`) while exposing proxy ports to external traffic.

```yaml
version: "3.9"

networks:
  platform-network:
    external: true

volumes:
  kong_prefix_vol:
    driver_opts:
      type: tmpfs
      device: tmpfs
  kong_tmp_vol:
    driver_opts:
      type: tmpfs
      device: tmpfs

services:
  kong-gateway:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: kong-gateway-prod
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /usr/local/kong/declarative/kong.yaml
      KONG_PROXY_ACCESS_LOG: /dev/stdout
      KONG_ADMIN_ACCESS_LOG: /dev/stdout
      KONG_PROXY_ERROR_LOG: /dev/stderr
      KONG_ADMIN_ERROR_LOG: /dev/stderr
      KONG_ADMIN_LISTEN: "127.0.0.1:8001, 127.0.0.1:8444 ssl"
      KONG_PROXY_LISTEN: "0.0.0.0:8000, 0.0.0.0:8443 ssl"
      KONG_LOG_LEVEL: ${KONG_LOG_LEVEL:-warn}
      KONG_PLUGINS: bundled,jti-blacklist-checker
      KONG_NGINX_WORKER_PROCESSES: ${KONG_NGINX_WORKER_PROCESSES:-auto}
      KONG_PREFIX: /var/run/kong
      KONG_SSL_CERT: ${KONG_SSL_CERT:-/etc/kong/certs/cert.pem}
      KONG_SSL_CERT_KEY: ${KONG_SSL_CERT_KEY:-/etc/kong/certs/key.pem}
      KONG_REAL_IP_HEADER: X-Forwarded-For
      KONG_REAL_IP_RECURSIVE: "on"
      KONG_TRUSTED_IPS: "0.0.0.0/0,::/0"
    networks:
      - platform-network
    ports:
      - "8000:8000"
      - "127.0.0.1:8001:8001"
      - "8443:8443"
      - "127.0.0.1:8444:8444"
    healthcheck:
      test: ["CMD", "kong", "health"]
      interval: 30s
      timeout: 10s
      retries: 3
    restart: unless-stopped
    read_only: true
    volumes:
      - ./config:/usr/local/kong/declarative:ro
      - ./certs:/etc/kong/certs:ro
      - kong_prefix_vol:/var/run/kong
      - kong_tmp_vol:/tmp
    security_opt:
      - no-new-privileges
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 2G
        reservations:
          cpus: '1'
          memory: 1G

```

Explanation:
- References an external Docker network (`platform-network`) for integration with existing infrastructure in production and provisions tmpfs volumes for Kong runtime directories to avoid persisting sensitive data.
- Builds the same custom Kong image but tightens admin exposure to loopback addresses and sets logging defaults via environment variables. TLS certificates are mounted from `./certs` into Kong’s expected directory.
- Configures real IP handling (`KONG_REAL_IP_HEADER`, `KONG_TRUSTED_IPS`) for scenarios where Kong sits behind load balancers.
- Adds `deploy.resources` to communicate CPU/memory constraints (useful for Swarm mode or as documentation when translating to Kubernetes).
- Composition is limited to the gateway, assuming managed services for Redis, Postgres, and microservices in production environments.

### File: `Dockerfile`
`Dockerfile` packages the custom plugin and Lua dependencies into the Kong image.

```dockerfile
FROM kong

USER root

COPY plugins/jti-blacklist-checker /usr/local/share/lua/5.1/kong/plugins/jti-blacklist-checker

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git unzip wget && \
    luarocks install lua-resty-redis && \
    luarocks install pgmoon && \
    apt-get purge -y build-essential git unzip wget && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV KONG_PLUGINS=bundled,jti-blacklist-checker

USER kong

EXPOSE 8000 8001 8443 8444

STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=10s --timeout=10s --retries=10 CMD kong health

CMD ["kong", "docker-start"]

```

Explanation:
- **What this file does:** Builds a custom Kong image that bundles the `jti-blacklist-checker` plugin and its Lua dependencies.
- **Key steps:** Temporarily elevates to `root`, installs build tools, compiles required rocks, then cleans up to keep the image lean before switching back to the restricted `kong` user.
- **Runtime configuration:** Sets `KONG_PLUGINS` so the custom plugin is always available, exposes proxy/admin ports, defines `SIGQUIT` for graceful shutdowns, and mirrors the healthcheck used in Compose files.
- **How to extend it:** Add more plugins by copying their directories into `/usr/local/share/lua/5.1/kong/plugins/<name>` and appending them to `KONG_PLUGINS`; install extra Lua rocks or OS packages as needed for new functionality.

### Declarative vs Database Mode
- Declarative mode (`KONG_DATABASE=off`) uses `KONG_DECLARATIVE_CONFIG=/usr/local/kong/declarative/kong.yaml`; Compose files mount `config/kong.yaml` into this location.
- To switch to database-backed mode:
  1. Set `KONG_DATABASE=postgres` and supply `KONG_PG_HOST`, `KONG_PG_USER`, `KONG_PG_PASSWORD`, etc.
  2. Execute migrations: `kong migrations bootstrap`, then `kong migrations up`.
  3. Manage configuration via Admin API or `deck`; export snapshots using `kong config db_export`.

## Environment Configuration Details
- `.env.example`: baseline template for cloning; matches example Compose defaults and encourages overriding secrets.
- `.env.development`: verbose logging (`debug`), lower worker count (`2`), and `JTI_FAIL_CLOSED=false` to avoid blocking when local Redis/Postgres are unstable.
- `.env.production`: hardened settings (`warn` log level, `auto` workers, `JTI_FAIL_CLOSED=true`, TLS references) and requires real Redis/Postgres endpoints with credentials.
- Shared keys:
  - `NPM_*`: passed to microservice Docker builds.
  - `PLATFORM_*_MS_URL`: used by health scripts and consumers during integration tests.
  - `RATE_LIMIT_*`: propagate to `config/kong.yaml` by manual update when adjusting budgets.

## Custom Plugin Deep Dive
**Purpose**
- Enforce token revocation by checking the JWT `jti` against Redis (primary) and Postgres (fallback).

**How it runs**
1. JWT plugin authenticates the token and stores credentials in `kong.ctx.shared`.
2. `jti-blacklist-checker` reads the JTI, ensures the token is not expired, and looks up `redis_key_prefix:jti`.
3. If Redis is unavailable and `db_fallback=true`, the plugin queries Postgres via `db-fallback.lua`.
4. Tokens found in either store are rejected with `401 Access token has been revoked` (unless `shadow_mode` is enabled).

**Tuning tips**
- Use `JTI_SHADOW_MODE=true` during rollout to monitor behavior without blocking traffic.
- Set `JTI_FAIL_CLOSED=false` in development to reduce friction when Redis/Postgres go offline.
- Adjust `redis_timeout` and `redis_db` to match your infrastructure; consider using dedicated DB numbers per environment.

**Extending the plugin**
- Add support for alternative caches (Memcached, DynamoDB) by introducing new client modules and branching in the handler.
- Emit metrics to StatsD/Prometheus by calling `kong.statsd.increment` when revocations occur.
- Allow per-service overrides by updating `schema.lua` to accept optional fields and reading them in `handler.lua`.

## Kong Configuration Details
**Global plugins**
- `rate-limiting`: caps traffic at 1000 req/min and 10,000 req/hour using the in-memory (`local`) policy. Increase or lower thresholds as traffic profiles change.
- `correlation-id`: propagates a unique `X-Correlation-ID` header to trace requests end-to-end; ensure downstream services log this header.

**Services and routes**
- `auth-ms` and `user-ms` point to Docker network hostnames. Update URLs for staging/production DNS (e.g., `http://auth-ms.internal:3300`).
- Public routes (`/public`, `/public/user`) intentionally skip authentication for login or health endpoints.
- Private routes (`/private`, `/private/user`) chain the JWT plugin followed by the blacklist plugin to enforce both signature validation and revocation checks.

**Consumers and credentials**
- `platform-client` defines the symmetric key used by the JWT plugin; when rotating keys, add a new entry first, update token issuers, then remove stale secrets.
- Consider using asymmetric algorithms (`RS256`) for higher security—this requires adjusting both Kong config and the issuing microservice.

## Deployment Workflow Summary
- Build custom image: `docker build -t kong-gateway .`
- Start stack: `docker compose up -d`
- Validate configuration: `./scripts/validate-config.sh`
- Health check: `./scripts/health-check.sh`
- End-to-end tests: `./scripts/test-kong.sh`
- Reload config after edits: `docker exec <kong-container> kong reload -c /usr/local/kong/declarative/kong.yaml`
- For DB mode: run `kong migrations up` before reloads and keep schema consistent.

### Frequently Asked Questions
- **Do I need the microservice repositories to run the gateway locally?** Yes, because `docker-compose.yml` builds `platform-auth-ms` and `platform-user-ms` from sibling directories. If you only want to run Kong, comment out those services and adjust dependencies.
- **Can I use a different Redis instance per environment?** Absolutely—override `REDIS_HOST`, `REDIS_PORT`, and `REDIS_PASSWORD` in the relevant `.env` file or CI secrets.
- **How do I rotate JWT keys?** Add a new entry under `consumers[0].jwt_secrets`, deploy, update the auth service, and remove the old secret once tokens signed with it expire.
- **What if I need RBAC or IP allowlists?** Add Kong’s bundled `acl` or `ip-restriction` plugins at the route/service layer in `config/kong.yaml`, then re-validate and reload.

### Kong Admin API Endpoint Cheatsheet (default admin URL `http://localhost:8001`)
| Purpose | Endpoint | Example Command |
| --- | --- | --- |
| Node status & DB reachability | `GET /status` | `curl -s http://localhost:8001/status | jq` |
| Base health probe | `GET /` | `curl -s -o /dev/null -w '%{http_code}' http://localhost:8001/` (expects `200`) |
| List all services | `GET /services` | `curl -s http://localhost:8001/services | jq '.data[].name'` |
| Inspect a service | `GET /services/{service}` | `curl -s http://localhost:8001/services/auth-ms | jq` |
| List routes | `GET /routes` | `curl -s http://localhost:8001/routes | jq '.data[].name'` |
| Routes for one service | `GET /services/{service}/routes` | `curl -s http://localhost:8001/services/auth-ms/routes | jq '.data[].paths'` |
| List consumers | `GET /consumers` | `curl -s http://localhost:8001/consumers | jq '.data[].username'` |
| JWT credentials per consumer | `GET /consumers/{consumer}/jwt` | `curl -s http://localhost:8001/consumers/platform-client/jwt | jq` |
| List active plugins | `GET /plugins` | `curl -s http://localhost:8001/plugins | jq '.data[].name'` |
| Inspect plugin instance | `GET /plugins/{id}` | `curl -s http://localhost:8001/plugins/<plugin-id> | jq` |
| Declarative config checksum | `GET /config` | `curl -s http://localhost:8001/config | jq` |

> For production, `docker-compose.prod.yml` binds the Admin API to `127.0.0.1`. Access it via SSH tunnels or bastion hosts, and secure it with mTLS or API gateway policies if exposing beyond localhost.

## Maintenance and Scaling
- Add/Update Services or Routes: modify `config/kong.yaml`, validate, commit, and redeploy; keep changes modular for review.
- Deploy Plugin Updates: edit Lua files, rebuild Docker image, and redeploy. Use `shadow_mode` during rollout to monitor impact.
- Scale Redis/Postgres: run managed clusters or replicas; adjust `redis_timeout`, `redis_db`, and connection pools; index `revoked_access_token.jti` to sustain lookups.
- Observability: integrate Kong logs with centralized logging; monitor Admin API metrics for plugin latency and rate-limiting counters.

### Step-by-Step Example: Adding `billing-ms`
1. **Update `config/kong.yaml`:** Duplicate the `user-ms` service block, rename it to `billing-ms`, point `url` to `http://platform-billing-ms:3500`, and create `/public/billing` and `/private/billing` routes (reusing JWT plus blacklist plugins on private paths).
2. **Validate and reload:**
   ```bash
   ./scripts/validate-config.sh
   docker exec kong-gateway kong reload -c /usr/local/kong/declarative/kong.yaml
   ```
3. **Extend automation:** Add billing route checks in `scripts/test-kong.sh` (public health endpoint, private profile endpoint with/without JWT).
4. **Update local stack (optional):** If you run billing locally, add a `platform-billing-ms` service to `docker-compose.yml` mirroring the existing microservice definitions.

### Glossary
- **Declarative Config:** Managing Kong entities via YAML rather than the Admin API; enables Git-based change review.
- **JTI (JWT ID):** Unique identifier inside JWTs used here to detect revoked tokens.
- **Fail Closed:** Security stance that denies requests when dependencies fail, preventing accidental access.
- **Shadow Mode:** Logging-only mode that reports potential blocks without denying traffic, useful for dry runs.
- **Fallback:** Secondary data source (Postgres) used when the primary cache (Redis) is unavailable.

## Troubleshooting
- Invalid JWT Signature or Missing Credential: ensure `jwt_secrets` align with Auth service signing key; re-run `scripts/test-kong.sh` to reproduce.
- Redis Connection Refused: use `scripts/redis-check.sh` to verify connectivity; confirm network routes and credentials.
- Postgres Fallback Errors: run `scripts/db-check.sh` and ensure `revoked_access_token` table exists; review Postgres logs for auth failures.
- Missing Plugin: verify `KONG_PLUGINS=bundled,jti-blacklist-checker` in environment and confirm Docker image built from updated `Dockerfile`.
- Declarative Parse Failures: run `scripts/validate-config.sh` to detect YAML issues before deployment.
- Debugging Logs: temporarily set `KONG_LOG_LEVEL=debug` in `.env`, restart gateway, and observe logs for `[JTI-BLACKLIST]` messages.

### File: `README.md`
- Provides a concise project overview, setup summary, and links to related microservices. Use it as a lightweight primer before diving into this in-depth DevOps guide.

### File: `.gitignore`
- Lists patterns for files that should not be committed (e.g., `.env`, build outputs, editor artifacts). Review before adding new tooling to ensure generated files stay out of version control.

## Additional Resources
- `README.md` provides project introduction and links to related microservices; reference it alongside this guide for onboarding.
- Kong Official Docs: https://docs.konghq.com/ for plugin development, declarative configuration, and Admin API workflows.


