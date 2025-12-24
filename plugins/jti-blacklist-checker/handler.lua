local redis_client = require "kong.plugins.jti-blacklist-checker.redis-client"
local db_fallback  = require "kong.plugins.jti-blacklist-checker.db-fallback"

local JtiBlacklistHandler = {
  VERSION  = "1.2.0",
  PRIORITY = 900, -- Must be lower than JWT (1450)
}

function JtiBlacklistHandler:access(conf)
  -- 1. Get the JWT data from the CORRECT Kong context
local jwt_data = kong.ctx.shared.authenticated_jwt_token or ngx.ctx.authenticated_jwt_token  
  if not jwt_data or not jwt_data.payload then
    kong.log.debug("[JTI] No JWT context found. Skipping check.")
    return 
  end

  local claims = jwt_data.payload
  local jti    = claims.jti

  if not jti then
    return kong.response.exit(401, { message = "Invalid token: missing JTI", code = "MISSING_JTI" })
  end

  -- 2. Check Redis (WHITELIST LOGIC: Must exist to be valid)
  local redis_key = conf.redis_key_prefix .. ":" .. jti
  local exists_in_redis, redis_err = redis_client.check_token(conf, redis_key)

  if redis_err then
    kong.log.err("[JTI] Redis Error: ", redis_err)
    
    -- 3. Fallback to DB if Redis is down
    if conf.db_fallback then
      local is_revoked_in_db, db_err = db_fallback.check_revoked_token(conf, jti)
      
      if db_err then
        kong.log.err("[JTI] DB Fallback Error: ", db_err)
        if conf.fail_closed then
          return kong.response.exit(503, { message = "Service unavailable", code = "AUTH_SERVICE_ERROR" })
        end
      elseif is_revoked_in_db then
        return kong.response.exit(401, { message = "Token revoked", code = "TOKEN_REVOKED" })
      end
      -- If not in DB and Redis was down, we assume it's still valid (Fail-open on logic)
      return 
    end
  end

  -- 4. Logic: If NOT found in Redis, it is considered Revoked/Logged out
  if not exists_in_redis then
    kong.log.notice("[JTI] JTI not found in Redis whitelist. Rejecting: ", jti)
    return kong.response.exit(401, { message = "Session expired or logged out", code = "SESSION_EXPIRED" })
  end

  kong.log.debug("[JTI] Token valid in Redis: ", jti)
end

return JtiBlacklistHandler