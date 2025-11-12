local pgmoon = require("pgmoon")

local _M = {}

function _M.check_revoked_token(conf, jti)
  if not conf.postgres_host or not conf.postgres_database then
    return nil, "PostgreSQL configuration missing"
  end

  local pg = pgmoon.new({
    host = conf.postgres_host,
    port = conf.postgres_port or 5432,
    database = conf.postgres_database,
    user = conf.postgres_user,
    password = conf.postgres_password,
  })

  local ok, err = pg:connect()
  if not ok then
    return nil, "Failed to connect to PostgreSQL: " .. tostring(err)
  end

  local table_name = conf.postgres_table or "revoked_access_token"
  local query = string.format(
    "SELECT jti FROM %s WHERE jti = %s LIMIT 1",
    table_name,
    pg:escape_literal(jti)
  )

  local result, err = pg:query(query)
  
  pg:keepalive()

  if not result then
    return nil, "PostgreSQL query failed: " .. tostring(err)
  end

  if result and #result > 0 then
    return true, nil
  end

  return false, nil
end

return _M

