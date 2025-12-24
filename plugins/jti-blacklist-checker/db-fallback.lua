local pgmoon = require("pgmoon")
local _M = {}

function _M.check_revoked_token(conf, jti)
  local pg = pgmoon.new({
    host = conf.postgres_host,
    port = conf.postgres_port,
    database = conf.postgres_database,
    user = conf.postgres_user,
    password = conf.postgres_password,
  })

  local ok, err = pg:connect()
  if not ok then return nil, "DB Connect error: " .. tostring(err) end

  local query = string.format(
    "SELECT 1 FROM %s WHERE jti = %s LIMIT 1",
    conf.postgres_table,
    pg:escape_literal(jti)
  )

  local res, err = pg:query(query)
  pg:keepalive()

  if err then return nil, err end

  -- If record exists, the token is BANNED/REVOKED
  if res and #res > 0 then
    return true, nil
  end

  return false, nil
end

return _M