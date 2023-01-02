# Hero

`nimble install hero`

![Github Actions](https://github.com/guzba/hero/workflows/Github%20Actions/badge.svg)

[API reference](https://nimdocs.com/guzba/hero)

Hero is a Redis client that is built to work well in a multi-threaded program.

## Using Hero

Hero supports both individual Redis connections:

```nim
import hero

let redis = newRedisConn() # Defaults to localhost:6379
```

And Redis connection pools:

```nim
import hero

let redisPool = newRedisPool(3) # Defaults to localhost:6379

redisPool.withConnection conn:
    # `conn` is automatically recycled back into the pool after this block
    let reply = conn.sendRecv("PING")
```

Send any of Redis's vast set of commands:

```nim
import hero

let redis = newRedisConn()

let reply = redis.sendRecv("HSET", "mykey", "myfield", "myvalue")
```

Easily pipeline commands and transactions:

```nim
import hero

let redis = newRedisConn()

redis.send("MULTI")
redis.send("INCR", "mycount")
redis.send("SET", "mykey", "myvalue")
redis.send("EXEC")

## OR:

# redis.send([
#  ("MULTI", @[]),
#  ("INCR", @["mycount"]),
#  ("SET", @["mykey", "myvalue"]),
#  ("EXEC", @[])
#])

# Match the number of `recv` calls to the number of commands sent

let
  reply1 = redis.recv() # OK
  reply2 = redis.recv() # QUEUED
  reply3 = redis.recv() # QUEUED
  reply4 = redis.recv() # 4, OK
```

Use [PubSub](https://redis.io/docs/manual/pubsub/) to concurrently receive messages and send connection updates such as SUBSCRIBE or UNSUBSCRIBE.

```nim
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
```
