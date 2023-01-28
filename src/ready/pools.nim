import connections, std/locks, std/sequtils, std/tables, std/times, waterpark

type
  RedisPoolObj = object
    port: Port
    address: string
    pool: Pool[RedisConn]
    lastReturnedLock: Lock
    lastReturned: Table[RedisConn, float]
    onConnect: proc(conn: RedisConn) {.gcsafe.}
    onBorrow: proc(conn: RedisConn, lastReturned: float) {.gcsafe.}

  RedisPool* = ptr RedisPoolObj

proc close*(pool: RedisPool) =
  ## Closes the database connections in the pool then deallocates the pool.
  ## All connections should be returned to the pool before it is closed.
  let entries = toSeq(pool.pool.items)
  for entry in entries:
    entry.close()
    pool.pool.delete(entry)
  pool.pool.close()
  `=destroy`(pool[])
  deallocShared(pool)

proc openNewConnection(pool: RedisPool): RedisConn =
  result = newRedisConn(pool.port, pool.address)
  if pool.onConnect != nil:
    pool.onConnect(result)

proc recycle*(pool: RedisPool, conn: RedisConn) {.raises: [], gcsafe.} =
  withLock pool.lastReturnedLock:
    pool.lastReturned[conn] = epochTime()
  pool.pool.recycle(conn)

proc newRedisPool*(
  size: int,
  port = Port(6379),
  address = "localhost",
  onConnect: proc(conn: RedisConn) {.gcsafe.} = nil,
  onBorrow: proc(conn: RedisConn, lastReturned: float) {.gcsafe.} = nil
): RedisPool =
  ## Creates a new thead-safe pool of Redis connections.
  if size <= 0:
    raise newException(CatchableError, "Invalid pool size")
  result = cast[RedisPool](allocShared0(sizeof(RedisPoolObj)))
  result.port = port
  result.address = address
  initLock(result.lastReturnedLock)
  result.pool = newPool[RedisConn]()
  result.onConnect = onConnect
  result.onBorrow = onBorrow
  try:
    for _ in 0 ..< size:
      result.recycle(result.openNewConnection())
  except:
    try:
      result.close()
    except:
      discard
    raise getCurrentException()

proc borrow*(pool: RedisPool): RedisConn {.gcsafe.} =
  result = pool.pool.borrow()
  if pool.onBorrow != nil:
    try:
      var lastReturned: float
      withLock pool.lastReturnedLock:
        lastReturned = pool.lastReturned[result]
      pool.onBorrow(result, lastReturned)
    except:
      # Close this connection and open a new one
      result.close()
      result = pool.openNewConnection()
      let lastReturned = epochTime()
      withLock pool.lastReturnedLock:
        pool.lastReturned[result] = lastReturned
      if pool.onBorrow != nil:
        pool.onBorrow(result, lastReturned)

template withConnnection*(pool: RedisPool, conn, body) =
  block:
    let conn = pool.borrow()
    try:
      body
    finally:
      pool.recycle(conn)
