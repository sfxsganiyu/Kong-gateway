local redis_client = require "kong.plugins.jti-blacklist-checker.redis-client"
local db_fallback  = require "kong.plugins.jti-blacklist-checker.db-fallback"
local cjson        = require "cjson.safe"

local JtiBlacklistHandler = {
  VERSION  = "1.3.9-ROBUST-DOT-DECODE",
  PRIORITY = 900, 
}

--- Helper: Decode Base64Url (JWT standard requires handling padding and URL-safe chars)
local function b64_decode(input)
  if not input then return nil end
  -- Add padding if missing
  local reminder = #input % 4
  if reminder > 0 then 
    input = input .. string.rep("=", 4 - reminder) 
  end
  -- Convert URL-safe Base64 to standard Base64
  input = input:gsub("-", "+"):gsub("_", "/")
  return ngx.decode_base64(input)
end

--- Robust JTI extractor using structural (dot) detection
local function extract_jti(data)
  if not data then return nil end

  -- CASE 1: Table (Already decoded by a previous plugin like Kong JWT)
  if type(data) == "table" then
    local jti = data.jti or (data.payload and data.payload.jti) or (data.claims and data.claims.jti)
    if jti then return jti end
  end

  -- CASE 2: String (Raw JWT)
  if type(data) == "string" then
    -- Structural Check: Extract the middle segment (payload) between the first and second dots.
    -- This is more robust than checking for "eyJ" as it relies on the JWT spec structure.
    local payload_b64 = data:match("[^%.]+%.([^%.]+)%.")
    
    if payload_b64 then
      local decoded_payload = b64_decode(payload_b64)
      if decoded_payload then
        local payload_table, err = cjson.decode(decoded_payload)
        if payload_table then
          return payload_table.jti
        else
          kong.log.err("[JTI-VERBOSE] JSON parse failed: ", tostring(err))
        end
      end
    end
  end

  return nil
end

function JtiBlacklistHandler:access(conf)
  local rid = kong.request.get_header("kong-request-id") or "no-id"
  kong.log.err("[JTI-DEBUG][", rid, "] --- Starting Blacklist Check ---")

  -- We check these sources in order of likelihood
  local sources = {
    { name = "kong.ctx.shared.authenticated_jwt_token", data = kong.ctx.shared.authenticated_jwt_token },
    { name = "kong.ctx.shared.jwt_auth_token",          data = kong.ctx.shared.jwt_auth_token },
    { name = "ngx.ctx.authenticated_jwt_token",         data = ngx.ctx.authenticated_jwt_token },
  }

  local jti = nil
  local found_source_name = "none"

  for _, source in ipairs(sources) do
    if source.data then
      -- Log metadata to confirm we are seeing the full string even if logs truncate later
      local d_type = type(source.data)
      local d_len = (d_type == "string") and #source.data or "N/A"
      kong.log.err("[JTI-DEBUG] Source: ", source.name, " (Type: ", d_type, " Len: ", d_len, ")")
      
      jti = extract_jti(source.data)
      if jti then
        found_source_name = source.name
        break
      end
    end
  end

  -- Block if JTI is missing
  if not jti then
    kong.log.err("[JTI-DEBUG] Error: JTI extraction failed for all sources.")
    return kong.response.exit(401, { code = "MISSING_JTI", message = "Invalid Session Identifier" })
  end

  kong.log.err("[JTI-DEBUG] Found JTI: [", jti, "] from [", found_source_name, "]")

  -- Redis Check
  local prefix = conf.redis_key_prefix or "jti"
  local redis_key = prefix .. ":" .. jti
  local exists_in_redis, redis_err = redis_client.check_token(conf, redis_key)

  if redis_err then
    kong.log.err("[JTI-DEBUG] Redis Error: ", redis_err)
    if conf.db_fallback then
      local is_revoked, db_err = db_fallback.check_revoked_token(conf, jti)
      if is_revoked then 
        return kong.response.exit(401, { code = "TOKEN_REVOKED" }) 
      end
      if not db_err then return end -- Fail-open
    end
  end

  -- Final Enforcement (Assuming Redis acts as a Whitelist of active JTIs)
  if not exists_in_redis then
    kong.log.err("[JTI-DEBUG] REJECTED: JTI not active in Redis.")
    return kong.response.exit(401, { code = "SESSION_EXPIRED", message = "Your session has expired." })
  end

  kong.log.err("[JTI-DEBUG] --- Authorized ---")
end

return JtiBlacklistHandler