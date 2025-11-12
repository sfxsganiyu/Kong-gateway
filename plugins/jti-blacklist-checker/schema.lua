local typedefs = require "kong.db.schema.typedefs"

return {
  name = "jti-blacklist-checker",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
      type = "record",
      fields = {
        { redis_host = { type = "string", required = true, default = "redis" }, },
        { redis_port = { type = "number", required = true, default = 6379 }, },
        { redis_password = { type = "string", required = false }, },
        { redis_db = { type = "number", required = true, default = 0 }, },
        { redis_timeout = { type = "number", required = true, default = 2000 }, },
        { redis_key_prefix = { type = "string", required = true, default = "access:key" }, },
        { db_fallback = { type = "boolean", required = true, default = true }, },
        { postgres_host = { type = "string", required = false, default = "postgres" }, },
        { postgres_port = { type = "number", required = false, default = 5432 }, },
        { postgres_database = { type = "string", required = false, default = "seamtel" }, },
        { postgres_user = { type = "string", required = false, default = "seamfix" }, },
        { postgres_password = { type = "string", required = false }, },
        { postgres_table = { type = "string", required = false, default = "revoked_access_token" }, },
        { fail_closed = { type = "boolean", required = true, default = true }, },
        { shadow_mode = { type = "boolean", required = true, default = false }, },
      },
    }, },
  },
}

