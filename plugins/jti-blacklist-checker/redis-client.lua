local redis = require "resty.redis"
local _M = {}

function _M.check_token(conf, redis_key)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout)

  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if not ok then return nil, "Connect failed: " .. tostring(err) end

  if conf.redis_password and conf.redis_password ~= "" then
    local ok, err = red:auth(conf.redis_password)
    if not ok then return nil, "Auth failed: " .. tostring(err) end
  end

  if conf.redis_db and conf.redis_db ~= 0 then
    red:select(conf.redis_db)
  end

  local res, err = red:get(redis_key)
  
  -- Clean up: Put connection back in the pool
  red:set_keepalive(10000, 100)

  if err then return nil, err end
  if res == ngx.null then
    return false, nil -- Token not found (Invalid)
  end

  return true, nil -- Token found (Valid)
end

return _M