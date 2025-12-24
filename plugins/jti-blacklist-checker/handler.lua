local redis_client = require "kong.plugins.jti-blacklist-checker.redis-client"
local db_fallback  = require "kong.plugins.jti-blacklist-checker.db-fallback"

local JtiBlacklistHandler = {
  VERSION  = "1.2.5-LOGGED",
  PRIORITY = 900, 
}

-- Helper to find jti in nested tables
local function extract_jti(data)
  if not data or type(data) ~= "table" then return nil end
  
  -- Check root, then claims, then payload
  local jti = data.jti or (data.claims and data.claims.jti) or (data.payload and data.payload.jti)
  
  if jti then
    kong.log.err("[JTI-LOG] JTI successfully extracted: ", jti)
  end
  
  return jti
end

function JtiBlacklistHandler:access(conf)
  kong.log.err("[JTI-LOG] --- Access Phase Started ---")

  -- 1. Define all possible sources in order of preference
  local sources = {
    { name = "kong.ctx.shared.authenticated_jwt_token", data = kong.ctx.shared.authenticated_jwt_token },
    { name = "ngx.ctx.authenticated_jwt_token",          data = ngx.ctx.authenticated_jwt_token },
    { name = "kong.ctx.shared.authenticated_credential", data = kong.ctx.shared.authenticated_credential }
  }

  local jti = nil
  local found_source_name = "none"

  -- 2. Loop through sources until we find a JTI
  for _, source in ipairs(sources) do
    if source.data then
      kong.log.err("[JTI-LOG] Checking source: ", source.name)
      jti = extract_jti(source.data)
      if jti then
        found_source_name = source.name
        break -- Exit the loop as soon as we find the JTI
      end
    end
  end

  -- 3. Handle failure to find JTI anywhere
  if not jti then
    kong.log.err("[JTI-LOG] ERROR: JTI could not be found in ANY context source.")
    
    -- Diagnostic: Print keys of the first available source to see what's wrong
    for _, source in ipairs(sources) do
      if source.data then
        local keys = {}
        for k, _ in pairs(source.data) do table.insert(keys, k) end
        kong.log.err("[JTI-LOG] Diagnostic for ", source.name, " keys: ", table.concat(keys, ", "))
      end
    end
    
    return kong.response.exit(401, { code = "MISSING_JTI", message = "Invalid token claims" })
  end

  kong.log.err("[JTI-LOG] Using JTI from: ", found_source_name)

  -- 4. Check Redis (Whitelist approach)
  local redis_key = conf.redis_key_prefix .. ":" .. jti
  kong.log.err("[JTI-LOG] Checking Redis for key: ", redis_key)
  
  local exists_in_redis, redis_err = redis_client.check_token(conf, redis_key)

  if redis_err then
    kong.log.err("[JTI-LOG] REDIS ERROR: ", redis_err)
    
    -- 5. Database Fallback
    if conf.db_fallback then
      kong.log.err("[JTI-LOG] Attempting DB Fallback for JTI: ", jti)
      local is_revoked, db_err = db_fallback.check_revoked_token(conf, jti)
      
      if db_err then
        kong.log.err("[JTI-LOG] DB ERROR: ", db_err)
        if conf.fail_closed then
          return kong.response.exit(503, { code = "AUTH_SERVICE_UNAVAILABLE" })
        end
      elseif is_revoked then
        kong.log.err("[JTI-LOG] BLOCKING: Token found in Revoked DB: ", jti)
        return kong.response.exit(401, { code = "TOKEN_REVOKED", message = "Token has been revoked" })
      end
      
      kong.log.err("[JTI-LOG] DB Fallback allowed request (not in blacklist)")
      return 
    end
  end

  -- 6. Enforcement
  if not exists_in_redis then
    kong.log.err("[JTI-LOG] BLOCKING: JTI not found in Redis whitelist: ", jti)
    return kong.response.exit(401, { code = "SESSION_EXPIRED", message = "Session expired or logged out" })
  end

  kong.log.err("[JTI-LOG] SUCCESS: Token validated. Allowing request.")
end

return JtiBlacklistHandler