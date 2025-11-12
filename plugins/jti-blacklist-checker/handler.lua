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

