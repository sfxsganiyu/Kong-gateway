local redis_client = require "kong.plugins.jti-blacklist-checker.redis-client"
local db_fallback  = require "kong.plugins.jti-blacklist-checker.db-fallback"

local JtiBlacklistHandler = {
  VERSION  = "1.2.7-FINAL",
  PRIORITY = 900, 
}

-- Helper to safely find jti within tables
local function extract_jti(data)
  if not data or type(data) ~= "table" then return nil end
  
  -- Check common Kong nesting patterns for JTI
  local jti = data.jti or (data.claims and data.claims.jti) or (data.payload and data.payload.jti)
  
  if jti then
    kong.log.err("[JTI-LOG] JTI successfully extracted: ", jti)
  end
  
  return jti
end

function JtiBlacklistHandler:access(conf)
  kong.log.err("[JTI-LOG] --- Access Phase Started ---")

  -- 1. Identify all possible sources where JWT data might be stored
  local sources = {
    { name = "kong.ctx.shared.authenticated_jwt_token", data = kong.ctx.shared.authenticated_jwt_token },
    { name = "ngx.ctx.authenticated_jwt_token",          data = ngx.ctx.authenticated_jwt_token },
    { name = "kong.ctx.shared.authenticated_credential", data = kong.ctx.shared.authenticated_credential }
  }

  local jti = nil
  local found_source_name = "none"

  -- 2. Loop through sources until a JTI is found
  for _, source in ipairs(sources) do
    if source.data then
      kong.log.err("[JTI-LOG] Checking source: ", source.name)
      
      -- Guard against strings (the 'bad argument to pairs' fix)
      if type(source.data) == "table" then
        jti = extract_jti(source.data)
        if jti then
          found_source_name = source.name
          break 
        end
      else
        kong.log.err("[JTI-LOG] Skipping ", source.name, " because it is a ", type(source.data))
      end
    end
  end

  -- 3. Handle failure to find JTI anywhere
  if not jti then
    kong.log.err("[JTI-LOG] ERROR: JTI not found in any valid table source.")
    return kong.response.exit(401, { code = "MISSING_JTI", message = "Invalid token claims" })
  end

  kong.log.err("[JTI-LOG] Success! Using JTI from: ", found_source_name)

  -- 4. Check Redis (Primary Whitelist Check)
  local redis_key = conf.redis_key_prefix .. ":" .. jti
  local exists_in_redis, redis_err = redis_client.check_token(conf, redis_key)

  if redis_err then
    kong.log.err("[JTI-LOG] REDIS ERROR: ", redis_err)
    
    -- 5. Database Fallback (Only if Redis is down)
    if conf.db_fallback then
      kong.log.err("[JTI-LOG] Attempting DB Fallback for JTI: ", jti)
      local is_revoked, db_err = db_fallback.check_revoked_token(conf, jti)
      
      if db_err then
        kong.log.err("[JTI-LOG] DB FALLBACK ERROR: ", db_err)
        -- Enforce fail_closed setting
        if conf.fail_closed then
          kong.log.err("[JTI-LOG] Fail-Closed active. Blocking request.")
          return kong.response.exit(503, { code = "AUTH_SERVICE_UNAVAILABLE", message = "Auth service error" })
        end
        kong.log.err("[JTI-LOG] Fail-Closed inactive. Allowing request despite DB error.")
        return -- Fail-Open
      end

      if is_revoked then
        kong.log.err("[JTI-LOG] BLOCKING: Token found in Revoked DB: ", jti)
        return kong.response.exit(401, { code = "TOKEN_REVOKED", message = "Token has been revoked" })
      end
      
      kong.log.err("[JTI-LOG] DB Fallback allowed request (JTI not in blacklist)")
      return 
    end
    
    -- If Redis failed and DB fallback is disabled
    if conf.fail_closed then
        return kong.response.exit(503, { code = "REDIS_UNAVAILABLE" })
    end
  end

  -- 6. Final Enforcement (If Redis responded but token wasn't there)
  if not exists_in_redis then
    kong.log.err("[JTI-LOG] BLOCKING: JTI not in Redis whitelist: ", jti)
    return kong.response.exit(401, { code = "SESSION_EXPIRED", message = "Session expired or logged out" })
  end

  kong.log.err("[JTI-LOG] --- Request Allowed ---")
end

return JtiBlacklistHandler