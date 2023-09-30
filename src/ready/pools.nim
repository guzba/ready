import connections, std/locks, std/random, std/tables, std/times

type
  RedisPoolObj = object
    address: string
    port: Port
    conns: seq[RedisConn]
    lock: Lock
    cond: Cond
    r: Rand
    lastReturned: Table[RedisConn, float]
    onConnect: proc(conn: RedisConn) {.gcsafe.}
    onBorrow: proc(conn: RedisConn, lastReturned: float) {.gcsafe.}

  RedisPool* = ptr RedisPoolObj

proc close*(pool: RedisPool) =
  ## Closes the Redis connections in the pool then deallocates the pool.
  ## All connections should be returned to the pool before it is closed.
  withLock pool.lock:
    for conn in pool.conns:
      conn.close()
  `=destroy`(pool[])
  deallocShared(pool)

proc openNewConnection(pool: RedisPool): RedisConn =
  result = newRedisConn(pool.address, pool.port)
  if pool.onConnect != nil:
    pool.onConnect(result)

proc recycle*(pool: RedisPool, conn: RedisConn) {.raises: [], gcsafe.} =
  ## Returns a Redis connection to the pool.
  withLock pool.lock:
    pool.conns.add(conn)
    pool.r.shuffle(pool.conns)
    pool.lastReturned[conn] = epochTime()
  signal(pool.cond)

proc newRedisPool*(
  size: int,
  address = "localhost",
  port = Port(6379),
  onConnect: proc(conn: RedisConn) {.gcsafe.} = nil,
  onBorrow: proc(conn: RedisConn, lastReturned: float) {.gcsafe.} = nil
): RedisPool =
  ## Creates a new thead-safe pool of Redis connections.
  if size <= 0:
    raise newException(CatchableError, "Invalid pool size")
  result = cast[RedisPool](allocShared0(sizeof(RedisPoolObj)))
  result.port = port
  result.address = address
  initLock(result.lock)
  initCond(result.cond)
  result.r = initRand(2023)
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
  ## Removes a Redis connection from the pool. This call blocks until it can take
  ## a connection. Remember to add the connection back to the pool with recycle
  ## when you're finished with it.

  acquire(pool.lock)
  while pool.conns.len == 0:
    wait(pool.cond, pool.lock)
  result = pool.conns.pop()
  release(pool.lock)

  if pool.onBorrow != nil:
    try:
      var lastReturned: float
      withLock pool.lock:
        lastReturned = pool.lastReturned[result]
      pool.onBorrow(result, lastReturned)
    except:
      # Close this connection and open a new one
      withLock pool.lock:
        pool.lastReturned.del(result)
      result.close()
      result = pool.openNewConnection()
      if pool.onBorrow != nil:
        pool.onBorrow(result, epochTime())

template withConnection*(pool: RedisPool, conn, body) =
  block:
    let conn = pool.borrow()
    try:
      body
    finally:
      pool.recycle(conn)

proc command*(
  pool: RedisPool,
  command: string,
  args: varargs[string]
): RedisReply =
  ## Borrows a Redis connection from the pool, sends a command to the
  ## server and receives the reply.
  pool.withConnection conn:
    result = conn.command(command, args)
