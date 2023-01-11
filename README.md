# Ready

`nimble install ready`

![Github Actions](https://github.com/guzba/ready/workflows/Github%20Actions/badge.svg)

[API reference](https://nimdocs.com/guzba/ready)

Ready is a Redis client that is built to work well in a multi-threaded program such as an HTTP server built using [Mummy](https://github.com/guzba/mummy).

Check out the [examples/](https://github.com/guzba/ready/tree/master/examples) folder for more sample code using Ready.

## Using Ready

Ready supports both individual Redis connections:

```nim
import ready

let redis = newRedisConn() # Defaults to localhost:6379
```

And Redis connection pools:

```nim
import ready

let redisPool = newRedisPool(3) # Defaults to localhost:6379

redisPool.withConnection conn:
    # `conn` is automatically recycled back into the pool after this block
    let reply = conn.roundtrip("PING")
```

Send any of Redis's vast set of commands:

```nim
import ready

let redis = newRedisConn()

let reply = redis.roundtrip("HSET", "mykey", "myfield", "myvalue")
```

Easily pipeline commands and transactions:

```nim
import ready

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
  reply1 = redis.receive() # OK
  reply2 = redis.receive() # QUEUED
  reply3 = redis.receive() # QUEUED
  reply4 = redis.receive() # 1, OK
```

Use [PubSub](https://redis.io/docs/manual/pubsub/) to concurrently receive messages and send connection updates such as SUBSCRIBE or UNSUBSCRIBE.

```nim
import ready, std/os

let pubsub = newRedisConn()

proc receiveProc() =
  try:
    while true:
      let reply = pubsub.receive()
      echo "Event: ", reply[0].to(string)
      echo "Channel: ", reply[1].to(string)
      echo "Raw: ", reply
  except RedisError as e:
    echo e.msg

var receiveThread: Thread[void]
createThread(receiveThread, receiveProc)

pubsub.send("SUBSCRIBE", "mychannel")
```

## Pro Tips

You can use Ready in two ways, either by calling `send` and `receive` or by calling `roundtrip`. Calling `roundtrip` is the equivalent of calling `send` and then calling `receive` immediately.

Why use `send` and `receive` separately? Two reasons:

First, where possible, it is more efficient to pipeline many Redis commands. This is easy to do with Ready, just call `send` multiple times (or call `send` with a seq of commands).

Second, you may want to have a separate thread be sending vs receiving. A common use of this is [PubSub](https://redis.io/docs/manual/pubsub/), where one thread is dedicated to receiving messages and the sending thread manages what channels are subscribed to. See [this example](https://github.com/guzba/ready/blob/master/examples/pubsub.nim).

Whenever a `receive` call gets an error reply from Redis a `RedisError` is raised. Remember that `roundrip` calls `receive` internally so you'll know if any errors occurred before you start working with the reply.

## Working with replies

A call to `receive` or `roundtrip` will return a `RedisReply` object. You'll want to convert that into the types to expect. Ready makes that easy by calling `reply.to`.

```nim
# Basic conversions:

echo reply.to(int)
echo reply.to(string)
echo reply.to(Option[string]) # If the reply can be nil

# Convert array replies to seq:

echo reply.to(seq[int])
echo reply.to(seq[string])
echo reply.to(seq[Option[string]])

# Convert array replies to tuples:

echo reply.to((int, string))
echo reply.to((int, Option[string]))
echo reply.to((string, Option[string], int))

# Mix and match:

echo reply.to((string, Option[string], seq[int]))

# Index access, if you know the reply is an array you can access its elements

echo reply[0].to(string)

```

A call to `reply.to` for a type Ready does not know how to convert to will fail at compile time.

If Ready is unable to convert the reply from Redis to your requested type, a `RedisError` is raised.
