import ready

## This example demonstrates creating a pool Redis connections and setting them
## up using the onConnect callback.

## nim c --threads:on --mm:orc -r examples/pool_connect_callback.nim

proc setUpRedisConn(conn: RedisConn) =
  ## This proc is called for every Redis connection opened in the pool.
  ## Use this callback to set up the connection, such as sending AUTH
  ## and SELECT commands as needed.
  # discard conn.command("AUTH", "password")
  discard conn.command("SELECT", "0")

let pool = newRedisPool(2, onConnect = setUpRedisConn)
