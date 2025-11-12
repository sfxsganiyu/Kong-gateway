local redis = require "resty.redis"

local _M = {}

function _M.check_token(conf, redis_key)
  local red = redis:new()
  
  red:set_timeout(conf.redis_timeout)
  
  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if not ok then
    return nil, "Failed to connect to Redis: " .. tostring(err)
  end

  if conf.redis_password and conf.redis_password ~= "" then
    local res, err = red:auth(conf.redis_password)
    if not res then
      return nil, "Failed to authenticate with Redis: " .. tostring(err)
    end
  end

  if conf.redis_db and conf.redis_db ~= 0 then
    local res, err = red:select(conf.redis_db)
    if not res then
      return nil, "Failed to select Redis database: " .. tostring(err)
    end
  end

  local result, err = red:get(redis_key)
  if not result then
    return nil, "Redis GET failed: " .. tostring(err)
  end

  local ok, err = red:set_keepalive(10000, 100)
  if not ok then
    ngx.log(ngx.WARN, "Failed to set Redis keepalive: ", err)
  end

  if result == ngx.null then
    return false, nil
  end

  return true, nil
end

return _M

