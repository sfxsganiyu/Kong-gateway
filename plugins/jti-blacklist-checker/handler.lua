local redis_client = require "kong.plugins.jti-blacklist-checker.redis-client"
local db_fallback  = require "kong.plugins.jti-blacklist-checker.db-fallback"

local JtiBlacklistHandler = {
  VERSION  = "1.2.2", -- Incremented version
  PRIORITY = 900,
}

function JtiBlacklistHandler:access(conf)
  kong.log.debug("[JTI-DEBUG] Entering JTI Blacklist Handler...")

  -- 1. UNIVERSAL CONTEXT LOOKUP
  -- We log exactly which source provides the data
  local jwt_data = kong.ctx.shared.authenticated_jwt_token
  if jwt_data then kong.log.debug("[JTI-DEBUG] Found token in kong.ctx.shared.authenticated_jwt_token") end
  
  if not jwt_data then
    jwt_data = ngx.ctx.authenticated_jwt_token
    if jwt_data then kong.log.debug("[JTI-DEBUG] Found token in ngx.ctx.authenticated_jwt_token") end
  end

  if not jwt_data then
    jwt_data = kong.ctx.shared.authenticated_credential
    if jwt_data then kong.log.debug("[JTI-DEBUG] Found token in kong.ctx.shared.authenticated_credential") end
  end

  if not jwt_data then
    kong.log.err("[JTI] JWT context missing. Ensure JWT plugin is enabled on this route.")
    return kong.response.exit(401, { message = "Unauthorized", code = "NO_JWT_CONTEXT" })
  end

  -- DEBUG: Print the entire JWT structure to see claims
  -- Use 'inspect' to see the table content in the logs
  kong.log.debug("[JTI-DEBUG] Full JWT Data Structure:")
  kong.log.inspect(jwt_data)

  -- 2. EXTRACT JTI
  local claims = jwt_data.payload or jwt_data.claims or jwt_data
  local jti    = claims.jti

  kong.log.debug("[JTI-DEBUG] Extracted JTI: ", tostring(jti))

  if not jti then
    kong.log.err("[JTI] JTI claim missing from token payload")
    return kong.response.exit(401, { message = "Invalid token: missing JTI", code = "MISSING_JTI" })
  end

  -- 3. REDIS CHECK
  local redis_key = conf.redis_key_prefix .. ":" .. jti
  kong.log.debug("[JTI-DEBUG] Checking Redis Key: ", redis_key)
  
  local exists_in_redis, redis_err = redis_client.check_token(conf, redis_key)

  if redis_err then
    kong.log.err("[JTI] Redis Error: ", redis_err)
    
    -- 4. DB FALLBACK
    if conf.db_fallback then
      kong.log.debug("[JTI-DEBUG] Redis failed, attempting DB Fallback for JTI: ", jti)
      local is_revoked_in_db, db_err = db_fallback.check_revoked_token(conf, jti)
      
      if db_err then
        kong.log.err("[JTI] DB Fallback Error: ", db_err)
        if conf.fail_closed then
          return kong.response.exit(503, { message = "Service unavailable", code = "AUTH_SERVICE_ERROR" })
        end
      elseif is_revoked_in_db then
        kong.log.notice("[JTI] Token found in DB revoked list: ", jti)
        return kong.response.exit(401, { message = "Token revoked", code = "TOKEN_REVOKED" })
      end
      
      kong.log.debug("[JTI-DEBUG] JTI not found in Revoked DB. Allowing request.")
      return 
    end
  end

  -- 5. FINAL VALIDATION (Whitelist Logic)
  if not exists_in_redis then
    kong.log.notice("[JTI] JTI not found in Redis whitelist: ", jti)
    return kong.response.exit(401, { message = "Session expired or logged out", code = "SESSION_EXPIRED" })
  end

  kong.log.info("[JTI] Access Granted for JTI: ", jti)
end

return JtiBlacklistHandler