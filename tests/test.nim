import hero, std/os

# let redis = newRedisConn()
# # redis.send("INCR")
# # redis.send("INCRBY", $10)
# # redis.send("SET", "foo", "bar", "GET")
# # redis.recv()
# # redis.recv()
# # redis.recv()
# # redis.sendRecv("SET", "foo", "bar", "GET")
# # redis.close()

# proc readProc() =
#   try:
#     while true:
#       echo "HERE: "
#       let reply = redis.recv()
#       let f = reply.to(string)
#   except:
#     echo getCurrentExceptionMsg()

# var readThread: Thread[void]
# createThread(readThread, readProc)

# # redis.send([("GET", @["key"]), ("GET", @["key2"])])
# redis.send("SUBSCRIBE", "c1")
# redis.send("UNSUBSCRIBE", "c1")

# sleep(4000)

# redis.close()

# sleep(1000)


let pool = newRedisPool(1)
pool.withConnnection redis:
  echo redis.sendRecv("MGET", "key", "empty", "doesntexist")
  # echo redis.sendRecv("INCR", "key")
  echo redis.sendRecv("HGETALL", "map")
  echo redis.sendRecv("HMGET", "map", "a", "b", "c", "d", "e")
  # redis.send("GET", "key")
  # redis.send("GET", "empty")
  # echo redis.recv()
  # echo redis.recv()

echo "HERE"
