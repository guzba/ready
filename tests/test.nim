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

# let pubsub = newRedisConn()

# proc recvProc() =
#   try:
#     while true:
#       let msg = pubsub.recv()
#   except RedisError as e:
#     echo e.msg

# var recvThread: Thread[void]
# createThread(recvThread, recvProc)

# pubsub.send("SUBSCRIBE", "mychannel")

# sleep(4000)

# pubsub.close()

# sleep(1000)


# let pool = newRedisPool(1)
# pool.withConnnection redis:
#   # echo redis.roundtrip("MGET", "key", "empty", "doesntexist")
#   # echo redis.roundtrip("INCR", "key")
#   # echo redis.roundtrip("HGETALL", "map")
#   # echo redis.roundtrip("HMGET", "map", "a", "b", "c", "d", "e")
#   # echo redis.roundtrip("PING")
#   # redis.send("GET", "key")
#   # redis.send("GET", "empty")
#   # echo redis.recv()
#   # echo redis.recv()

#   # discard redis.roundtrip("SET", "integer", "0")
#   # echo redis.roundtrip("INCR", "integer").to(int32)
#   # echo redis.roundtrip("INCR", "integer").to(string)
#   # echo redis.roundtrip("INCR", "integer").to(Option[string])

#   # redis.send("MULTI")
#   # redis.send("INCR", "integer")
#   # redis.send("INCR", "integer")
#   # redis.send("INCR", "integer")
#   # redis.send("EXEC")

#   # redis.send([
#   #   ("MULTI", @[]),
#   #   ("INCR", @["integer"]),
#   #   ("INCR", @["integer"]),
#   #   ("INCR", @["integer"]),
#   #   ("EXEC", @[]),
#   # ])

#   # discard redis.receive()
#   # discard redis.receive()
#   # discard redis.receive()
#   # discard redis.receive()
#   # # echo redis.receive().to(seq[int])
#   # echo redis.receive().to((int, int, Option[string]))


#   redis.send("MULTI")
#   # redis.send("LPUSH", "metavars", "foo", "foobar", "hoge")
#   redis.send("LRANGE", "metavars", "0", "-1")
#   redis.send("GET", "key")
#   redis.send("GET", "key")
#   redis.send("EXEC")
#   echo redis.receive().to(string)
#   echo redis.receive().to(string)
#   # echo redis.receive()
#   echo redis.receive().to(string)
#   echo redis.receive().to(string)
#   echo redis.receive().to((seq[string], string, string))
#   # echo "len = ", reply.len

# echo "-- EXITING"
