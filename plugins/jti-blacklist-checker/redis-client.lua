local redis = require "resty.redis"
local _M = {}

function _M.check_token(conf, redis_key)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout)

  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if not ok then return nil, err end

  if conf.redis_password and conf.redis_password ~= "" then
    local ok, err = red:auth(conf.redis_password)
    if not ok then return nil, err end
  end

  local res, err = red:get(redis_key)
  
  -- Put back in pool immediately
  red:set_keepalive(10000, 100)

  if err then return nil, err end
  if res == ngx.null then
    return false, nil -- Not found
  end

  return true, nil -- Found
end

return _M