import connections, std/sequtils, waterpark

type RedisPool* = object
  pool: Pool[RedisConn]

proc close*(pool: RedisPool) =
  ## Closes the database connections in the pool then deallocates the pool.
  ## All connections should be returned to the pool before it is closed.
  let entries = toSeq(pool.pool.items)
  for entry in entries:
    entry.close()
    pool.pool.delete(entry)
  pool.pool.close()

proc newRedisPool*(
  size: int,
  port = Port(6379),
  address = "localhost"
): RedisPool =
  ## Creates a new thead-safe pool of Redis connections.
  if size <= 0:
    raise newException(CatchableError, "Invalid pool size")
  result.pool = newPool[RedisConn]()
  try:
    for _ in 0 ..< size:
      result.pool.recycle(newRedisConn(port, address))
  except:
    try:
      result.close()
    except:
      discard
    raise getCurrentException()

proc borrow*(pool: RedisPool): RedisConn {.inline, raises: [], gcsafe.} =
  pool.pool.borrow()

proc recycle*(pool: RedisPool, conn: RedisConn) {.inline, raises: [], gcsafe.} =
  pool.pool.recycle(conn)

template withConnnection*(pool: RedisPool, conn, body) =
  block:
    let conn = pool.borrow()
    try:
      body
    finally:
      pool.recycle(conn)
