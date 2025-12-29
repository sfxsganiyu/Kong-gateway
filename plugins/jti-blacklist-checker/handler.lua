local redis_client = require "kong.plugins.jti-blacklist-checker.redis-client"
local db_fallback  = require "kong.plugins.jti-blacklist-checker.db-fallback"
local cjson        = require "cjson.safe"

local JtiBlacklistHandler = {
  VERSION  = "1.4.1-FINAL-CORRECTED",
  PRIORITY = 900, 
}

-- Decode Base64URL (JWT payload)
local function b64_decode(input)
  if not input then return nil end
  local rem = #input % 4
  if rem > 0 then
    input = input .. string.rep("=", 4 - rem)
  end
  input = input:gsub("-", "+"):gsub("_", "/")
  return ngx.decode_base64(input)
end

-- Extract JTI from either a table or a raw JWT string
local function extract_jti(data)
  if not data then return nil end

  -- CASE 1: Already-decoded table
  if type(data) == "table" then
    return data.jti
        or (data.payload and data.payload.jti)
        or (data.claims and data.claims.jti)
  end

  -- CASE 2: Raw JWT string (STRICT STRUCTURE)
  if type(data) == "string" then
    -- Must have header.payload.signature
    local first_dot = data:find("%.")
    if not first_dot then return nil end

    local after_first_dot = data:sub(first_dot + 1)
    local second_dot = after_first_dot:find("%.")
    if not second_dot then
      return nil -- ❗ invalid JWT, do NOT accept
    end

    local payload_b64 = after_first_dot:sub(1, second_dot - 1)
    if not payload_b64 or payload_b64 == "" then return nil end

    local decoded = b64_decode(payload_b64)
    if not decoded then return nil end

    local payload = cjson.decode(decoded)
    if payload and payload.jti then
      return payload.jti
    end
  end

  return nil
end

function JtiBlacklistHandler:access(conf)
  local rid = kong.request.get_header("kong-request-id") or "no-id"
  kong.log.err("[JTI] START ", rid)

  local sources = {
    { name = "authenticated_jwt_token", data = kong.ctx.shared.authenticated_jwt_token },
    { name = "jwt_auth_token",          data = kong.ctx.shared.jwt_auth_token },
    { name = "ngx_ctx_jwt",             data = ngx.ctx.authenticated_jwt_token },
  }

  local jti
  for _, src in ipairs(sources) do
    if src.data then
      jti = extract_jti(src.data)
      if jti then
        kong.log.err("[JTI] Found JTI: ", jti, " from ", src.name)
        break
      end
    end
  end

  if not jti then
    kong.log.err("[JTI] ERROR: JTI extraction failed")
    return kong.response.exit(401, {
      code = "MISSING_JTI",
      message = "Invalid or malformed token"
    })
  end

  local redis_key = (conf.redis_key_prefix or "jti") .. ":" .. jti
  local exists, err = redis_client.check_token(conf, redis_key)

  -- Handle Redis failure safely
  if err then
    kong.log.err("[JTI] Redis error: ", err)
    if conf.db_fallback then
      local revoked = db_fallback.check_revoked_token(conf, jti)
      if revoked then
        return kong.response.exit(409, {
          code = "TOKEN_REVOKED",
          message = "Access token revoked"
        })
      end
      return -- fail-open
    end
  end

  -- Redis acts as WHITELIST of active JTIs
  if not exists then
    return kong.response.exit(401, {
      code = "SESSION_EXPIRED",
      message = "Access token expired"
    })
  end

  kong.log.err("[JTI] ALLOWED")
end

return JtiBlacklistHandler
