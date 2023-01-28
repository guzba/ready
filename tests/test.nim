import ready, std/os, std/options

block:
  let redis = newRedisConn()
  discard redis.command("SET", "foo", "bar")
  doAssert redis.command("GET", "foo").to(string) == "bar"
  redis.close()

block:
  let redis = newRedisConn()
  redis.send([
    ("SET", @["key1", "value1"]),
    ("SET", @["key2", "value2"]),
    ("SET", @["key3", "value3"])
  ])
  discard redis.receive()
  discard redis.receive()
  discard redis.receive()
  let values = redis.command("MGET", "key1", "key2", "key3").to(seq[string])
  doAssert values == @["value1", "value2", "value3"]
  redis.close()

block:
  proc onConnect(conn: RedisConn) =
    echo "onConnect"

  proc onBorrow(conn: RedisConn, lastReturned: float) =
    echo "onBorrow"
    discard conn.command("PING")

  let pool = newRedisPool(1, onConnect = onConnect, onBorrow = onBorrow)
  pool.withConnnection redis:
    discard redis.command("SET", "mynumber", "0")
    redis.send("INCR", "mynumber")
    redis.send("INCR", "mynumber")
    redis.send("INCR", "mynumber")
    redis.send("INCR", "mynumber")
    doAssert redis.receive().to(int) == 1
    doAssert redis.receive().to(int) == 2
    doAssert redis.receive().to(int) == 3
    doAssert redis.receive().to(int) == 4
  pool.close()

block:
  let pubsub = newRedisConn()

  var received: seq[RedisReply]

  proc receiveThreadProc() =
    try:
      while true:
        {.gcsafe.}:
          received.add(pubsub.receive())
    except RedisError as e:
      echo e.msg

  var receiveThread: Thread[void]
  createThread(receiveThread, receiveThreadProc)

  pubsub.send("SUBSCRIBE", "mychannel")

  proc publishThreadProc() =
    let publisher = newRedisConn()

    for i in 0 ..< 10:
      discard publisher.command("PUBLISH", "mychannel", $i)

    publisher.close()

  var publishThread: Thread[void]
  createThread(publishThread, publishThreadProc)

  joinThread(publishThread)

  sleep(100)

  pubsub.close()

  doAssert received[0].to((string, string, int)) == ("subscribe", "mychannel", 1)
  for i in 0 ..< 10:
    doAssert received[i + 1].to((string, string, string)) ==
      ("message", "mychannel", $i)

  sleep(1000)
