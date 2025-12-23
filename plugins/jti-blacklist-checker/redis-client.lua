local redis = require "resty.redis"
local ngx = ngx

local _M = {}

function _M.check_token(conf, redis_key)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout)

  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if not ok then
    return nil, "Failed to connect to Redis: " .. tostring(err)
  end

  if conf.redis_password and conf.redis_password ~= "" then
    local ok, err = red:auth(conf.redis_password)
    if not ok then
      return nil, "Redis AUTH failed: " .. tostring(err)
    end
  end

  if conf.redis_db and conf.redis_db ~= 0 then
    local ok, err = red:select(conf.redis_db)
    if not ok then
      return nil, "Redis SELECT failed: " .. tostring(err)
    end
  end

  local res, err = red:get(redis_key)

  -- ❗ REAL Redis error
  if err then
    return nil, err
  end

  -- ❗ KEY DOES NOT EXIST → TOKEN REVOKED
  if res == ngx.null then
    return false, nil
  end

  -- Key exists → token is active
  red:set_keepalive(10000, 100)
  return true, nil
end

return _M
