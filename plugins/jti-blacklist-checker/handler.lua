-- handler.lua
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
    kong.log.info("[JTI-BLACKLIST] Shadow mode enabled (no blocking)")
  end

  -- ✅ CORRECT SOURCE OF JWT DATA
  local jwt = kong.ctx.shared.jwt_token
  if not jwt or not jwt.claims then
    kong.log.err("[JTI-BLACKLIST] JWT plugin did not run or token missing")

    if conf.fail_closed then
      return kong.response.exit(401, {
        message = "Unauthorized",
        code = "NO_JWT"
      })
    end
    return
  end

  local claims = jwt.claims
  local jti = claims.jti

  if not jti then
    kong.log.err("[JTI-BLACKLIST] Missing jti claim")
    return kong.response.exit(401, {
      message = "Invalid token",
      code = "MISSING_JTI"
    })
  end

  -- Optional but safe expiry check
  if claims.exp and claims.exp <= ngx.time() then
    return kong.response.exit(401, {
      message = "Token expired",
      code = "TOKEN_EXPIRED"
    })
  end

  local redis_key = conf.redis_key_prefix .. ":" .. jti
  kong.log.debug("[JTI-BLACKLIST] Redis check → " .. redis_key)

  local exists, redis_err = redis_client.check_token(conf, redis_key)

  -- ❗ Redis failure → FAIL CLOSED
  if redis_err then
    kong.log.err("[JTI-BLACKLIST] Redis error: " .. redis_err)

    if conf.db_fallback then
      local revoked, db_err = db_fallback.check_revoked_token(conf, jti)

      -- ❗ ANY uncertainty → BLOCK
      return kong.response.exit(401, {
        message = "Access token revoked",
        code = "ACCESS_TOKEN_REVOKED"
      })
    end

    return kong.response.exit(503, {
      message = "Token verification failed",
      code = "REDIS_UNAVAILABLE"
    })
  end

  -- ❗ Redis key missing → TOKEN REVOKED
  if not exists then
    kong.log.warn("[JTI-BLACKLIST] Token revoked (Redis key missing): " .. jti)

    if conf.shadow_mode then
      kong.log.warn("[JTI-BLACKLIST] SHADOW: would block revoked token")
      return
    end

    return kong.response.exit(401, {
      message = "Access token revoked",
      code = "ACCESS_TOKEN_REVOKED"
    })
  end

  -- ✅ Token explicitly allowed
  kong.log.debug("[JTI-BLACKLIST] Token allowed: " .. jti)
end

return JtiBlacklistHandler
