-- -- handler.lua
-- local redis_client = require "kong.plugins.jti-blacklist-checker.redis-client"
-- local db_fallback  = require "kong.plugins.jti-blacklist-checker.db-fallback"

-- local kong = kong
-- local ngx  = ngx

-- local JtiBlacklistHandler = {
--   VERSION  = "1.0.0",
--   PRIORITY = 900,
-- }

-- function JtiBlacklistHandler:access(conf)
--   -- ---------------------------------------------
--   -- 1. Read JWT injected by Kong JWT plugin
--   -- ---------------------------------------------
--   local jwt = kong.ctx.shared.jwt_token
--   if not jwt or not jwt.claims then
--     kong.log.err("[JTI-BLACKLIST] JWT plugin did not run or token missing")

--     if conf.fail_closed then
--       return kong.response.exit(401, {
--         message = "Unauthorized",
--         code    = "NO_JWT"
--       })
--     end

--     -- fail open if configured
--     return
--   end

--   local claims = jwt.claims
--   local jti  = claims.jti

--   if not jti then
--     kong.log.err("[JTI-BLACKLIST] Missing jti claim")
--     return kong.response.exit(401, {
--       message = "Invalid token",
--       code    = "MISSING_JTI"
--     })
--   end

--   -- ---------------------------------------------
--   -- 2. Optional hard expiry check (defensive)
--   -- ---------------------------------------------
--   if claims.exp and claims.exp <= ngx.time() then
--     return kong.response.exit(401, {
--       message = "Token expired",
--       code = "TOKEN_EXPIRED"
--     })
--   end

--   -- ---------------------------------------------
--   -- 3. Redis lookup (primary source of truth)
--   -- ---------------------------------------------
--   local redis_key = conf.redis_key_prefix .. ":" .. jti
--   kong.log.debug("[JTI-BLACKLIST] Checking Redis key: " .. redis_key)

--   local exists, redis_err = redis_client.check_token(conf, redis_key)

--   -- =========================================================
--   -- ❗ REDIS ERROR PATH → DB FALLBACK → FAIL CLOSED
--   -- =========================================================
--   if redis_err then
--     kong.log.err("[JTI-BLACKLIST] Redis error: " .. redis_err)

--     if conf.db_fallback then
--       local revoked, db_err = db_fallback.check_revoked_token(conf, jti)

--       if db_err then
--         kong.log.err("[JTI-BLACKLIST] DB fallback error: " .. db_err)
--       end

--       if revoked == true then
--         return kong.response.exit(401, {
--           message = "Access token revoked",
--           code    = "ACCESS_TOKEN_REVOKED"
--         })
--       end

--       -- 🔒 Any uncertainty → FAIL CLOSED
--       return kong.response.exit(401, {
--         message = "Token verification failed",
--         code    = "TOKEN_VERIFICATION_FAILED"
--       })
--     end

--     -- No DB fallback → service unavailable
--     return kong.response.exit(503, {
--       message = "Token verification failed",
--       code    = "REDIS_UNAVAILABLE"
--     })
--   end

--   -- ---------------------------------------------
--   -- 4. Redis says key missing → token revoked
--   -- ---------------------------------------------
--   if not exists then
--     kong.log.warn("[JTI-BLACKLIST] Token revoked (Redis key missing): " .. jti)

--     if conf.shadow_mode then
--       kong.log.warn("[JTI-BLACKLIST] SHADOW MODE: request allowed")
--       return
--     end

--     return kong.response.exit(401, {
--       message = "Access token revoked",
--       code    = "ACCESS_TOKEN_REVOKED"
--     })
--   end

--   -- ---------------------------------------------
--   -- 5. Token is valid & allowed
--   -- ---------------------------------------------
--   kong.log.debug("[JTI-BLACKLIST] Token allowed: " .. jti)
-- end

-- return JtiBlacklistHandler

-- handler.lua
local redis_client = require "kong.plugins.jti-blacklist-checker.redis-client"
local db_fallback  = require "kong.plugins.jti-blacklist-checker.db-fallback"

local kong = kong
local ngx  = ngx

local JtiBlacklistHandler = {
  VERSION  = "1.1.0",
  PRIORITY = 900,
}

function JtiBlacklistHandler:access(conf)
  kong.log.err("========== JTI BLACKLIST DEBUG START ==========")

  local auth_header = kong.request.get_header("authorization")
  kong.log.err("[DEBUG] Authorization header: ", auth_header or "nil")

  local jwt_credential = kong.ctx.shared.authenticated_credential
  local jwt_token = kong.ctx.shared.jwt_token

  kong.log.err("[DEBUG] kong.ctx.shared.authenticated_credential: ", jwt_credential and "PRESENT" or "NIL")
  kong.log.err("[DEBUG] kong.ctx.shared.jwt_token: ", jwt_token and "PRESENT" or "NIL")

  local jti = nil
  local claims = nil

  if jwt_credential then
    jti = jwt_credential.jti
    claims = jwt_credential
    kong.log.err("[DEBUG] Using authenticated_credential")
  elseif jwt_token and jwt_token.claims then
    claims = jwt_token.claims
    jti = claims.jti
    kong.log.err("[DEBUG] Using jwt_token.claims")
  end

  if not jwt_credential and not jwt_token then
    kong.log.err("[JTI-BLACKLIST] JWT missing or not authenticated by JWT plugin")

    return kong.response.exit(401, {
      message = "Unauthorized",
      code    = "NO_JWT_CONTEXT"
    })
  end

  if not claims then
    kong.log.err("[JTI-BLACKLIST] JWT claims not found")

    return kong.response.exit(401, {
      message = "Unauthorized",
      code    = "NO_JWT_CLAIMS"
    })
  end

  kong.log.err("[DEBUG] jti: ", jti or "nil")
  kong.log.err("[DEBUG] iss: ", claims.iss or "nil")
  kong.log.err("[DEBUG] exp: ", claims.exp or "nil")
  kong.log.err("[DEBUG] now: ", ngx.time())

  if not jti then
    return kong.response.exit(401, {
      message = "Invalid token",
      code    = "MISSING_JTI"
    })
  end

  if claims.exp and claims.exp <= ngx.time() then
    return kong.response.exit(401, {
      message = "Token expired",
      code    = "TOKEN_EXPIRED"
    })
  end

  local redis_key = conf.redis_key_prefix .. ":" .. jti
  kong.log.err("[DEBUG] Redis key lookup: ", redis_key)

  local exists, redis_err = redis_client.check_token(conf, redis_key)

  -- ❌ Redis failure → FAIL CLOSED
  if redis_err then
    kong.log.err("[JTI-BLACKLIST] Redis error: ", redis_err)

    if conf.db_fallback then
      local revoked, db_err = db_fallback.check_revoked_token(conf, jti)

      kong.log.err("[DEBUG] DB fallback revoked: ", revoked)
      kong.log.err("[DEBUG] DB fallback error: ", db_err)

      return kong.response.exit(401, {
        message = "Access token revoked",
        code    = "ACCESS_TOKEN_REVOKED"
      })
    end

    return kong.response.exit(503, {
      message = "Token verification failed",
      code    = "REDIS_UNAVAILABLE"
    })
  end

  -- ❌ Redis key missing → revoked
  if not exists then
    kong.log.err("[JTI-BLACKLIST] Token revoked (missing in Redis): ", jti)

    return kong.response.exit(401, {
      message = "Access token revoked",
      code    = "ACCESS_TOKEN_REVOKED"
    })
  end

  kong.log.err("[JTI-BLACKLIST] Token allowed: ", jti)
  kong.log.err("========== JTI BLACKLIST DEBUG END ==========")
end

return JtiBlacklistHandler

