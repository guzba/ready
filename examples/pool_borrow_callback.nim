import ready, std/times

## This example demonstrates using the borrow callback to verify a Redis
## connection is open before issuing commands.

## nim c --threads:on --mm:orc -r examples/pool_borrow_callback.nim

proc onBorrow(conn: RedisConn, lastReturned: float) =
  ## This proc is called each time a Redis connection is borrowed from the pool.
  ## You can use it to verify a connection is open.
  ## Raising an exception in this callback will close this Redis connection and
  ## a new Redis connection will be opened.
  if epochTime() - lastReturned > 4 * 60:
    # If this PING fails, a RedisError exception will be raised.
    discard conn.command("PING")

let pool = newRedisPool(2, onBorrow = onBorrow)

pool.withConnection conn:
  echo "Borrowed ", conn
