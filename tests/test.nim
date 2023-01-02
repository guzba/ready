import hero, std/os

# let redis = newRedisConn()
# redis.send("INCR")
# redis.send("INCRBY", $10)
# redis.send("SET", "foo", "bar", "GET")
# redis.recv()
# redis.recv()
# redis.recv()
# redis.sendRecv("SET", "foo", "bar", "GET")
# redis.close()

let pubsub = newRedisConn()

proc recvProc() =
  try:
    while true:
      let msg = pubsub.recv()
  except RedisError as e:
    echo e.msg

var recvThread: Thread[void]
createThread(recvThread, recvProc)

pubsub.send("SUBSCRIBE", "mychannel")

sleep(4000)

pubsub.close()

sleep(1000)


# let pool = newRedisPool(1)
# pool.withConnnection redis:
#   echo redis.sendRecv("MGET", "key", "empty", "doesntexist")
#   # echo redis.sendRecv("INCR", "key")
#   echo redis.sendRecv("HGETALL", "map")
#   echo redis.sendRecv("HMGET", "map", "a", "b", "c", "d", "e")
#   echo redis.sendRecv("PING")
#   # redis.send("GET", "key")
#   # redis.send("GET", "empty")
#   # echo redis.recv()
#   # echo redis.recv()

# echo "HERE"
