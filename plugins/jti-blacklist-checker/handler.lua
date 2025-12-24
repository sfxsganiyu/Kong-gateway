local redis_client = require "kong.plugins.jti-blacklist-checker.redis-client"
local db_fallback  = require "kong.plugins.jti-blacklist-checker.db-fallback"

local JtiBlacklistHandler = {
  VERSION  = "1.3.3-FIXED",
  PRIORITY = 900, 
}

-- Helper to safely find jti within tables
local function extract_jti(data)
  if not data or type(data) ~= "table" then return nil end
  
  -- Check payload (Standard in 3.x), then claims, then root
  local jti = (data.payload and data.payload.jti) or 
              (data.claims and data.claims.jti) or 
              data.jti
  
  if jti then
    kong.log.err("[JTI-LOG] JTI successfully extracted: ", jti)
  end
  
  return jti
end

function JtiBlacklistHandler:access(conf)
  kong.log.err("[JTI-LOG] --- Access Phase Started ---")

  -- 1. Identify all possible sources. 
  -- In 3.9.1, 'jwt_auth_token' is usually the hidden table.
  local sources = {
    { name = "kong.ctx.shared.jwt_auth_token",            data = kong.ctx.shared.jwt_auth_token },
    { name = "kong.ctx.shared.authenticated_jwt_token",   data = kong.ctx.shared.authenticated_jwt_token },
    { name = "ngx.ctx.authenticated_jwt_token",          data = ngx.ctx.authenticated_jwt_token },
  }

  local jti = nil
  local found_source_name = "none"

  -- 2. Loop through sources until a JTI is found
  for _, source in ipairs(sources) do
    if source.data then
      kong.log.err("[JTI-LOG] Checking source: ", source.name)
      
      if type(source.data) == "table" then
        jti = extract_jti(source.data)
        if jti then
          found_source_name = source.name
          break 
        end
      else
        -- Log the string value so you can see what Kong is putting there
        kong.log.err("[JTI-LOG] Skipping ", source.name, " because it is a string: ", tostring(source.data))
      end
    end
  end

  -- 3. Handle failure
  if not jti then
    kong.log.err("[JTI-LOG] ERROR: JTI not found in any valid table source.")
    return kong.response.exit(401, { code = "MISSING_JTI", message = "Invalid token claims" })
  end

  kong.log.err("[JTI-LOG] Success! Using JTI from: ", found_source_name)

  -- 4. Check Redis
  local redis_key = conf.redis_key_prefix .. ":" .. jti
  local exists_in_redis, redis_err = redis_client.check_token(conf, redis_key)

  if redis_err then
    kong.log.err("[JTI-LOG] REDIS ERROR: ", redis_err)
    if conf.db_fallback then
      local is_revoked, db_err = db_fallback.check_revoked_token(conf, jti)
      if db_err then
        if conf.fail_closed then return kong.response.exit(503) end
        return 
      end
      if is_revoked then
        return kong.response.exit(401, { code = "TOKEN_REVOKED" })
      end
      return 
    end
  end

  -- 5. Enforcement
  if not exists_in_redis then
    kong.log.err("[JTI-LOG] BLOCKING: JTI not in Redis: ", jti)
    return kong.response.exit(401, { code = "SESSION_EXPIRED", message = "Session expired" })
  end

  kong.log.err("[JTI-LOG] --- Request Allowed ---")
end

return JtiBlacklistHandler