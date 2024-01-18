# Ready

`nimble install ready`

[API reference](https://guzba.github.io/ready/)

Ready is a Redis client that is built to work well in multi-threaded programs. A great use-case for Ready is in a multi-threaded HTTP server like [Mummy](https://github.com/guzba/mummy).

Check out the [examples/](https://github.com/guzba/ready/tree/master/examples) folder for more sample code using Ready.

## Using Ready

First you'll need to open a Redis connection. By default Ready connects to the default Redis server at localhost:6379. You can easily specify a different address and port in `newRedisConn` when needed.

```nim
import ready

let redis = newRedisConn() # Defaults to localhost:6379
```

After opening a connection you can start sending commands. You can send any of Redis's vast set of commands.

```nim
import ready, std/options

let redis = newRedisConn() # Defaults to localhost:6379

let value = redis.command("GET", "key").to(Option[string])
```

We use `Option[string]` above since the reply may be nil if the key is not present. Alternatively, if you know the key exists, you could just use `string`.

You can also easily work with replies to more complex commands:

```nim
import ready

let redis = newRedisConn() # Defaults to localhost:6379

let values = redis.command("MGET", "key1", "key2", "key3").to(seq[string])
```

Here we are using `MGET` to request multiple keys in one command. Since we expect multiple reply entries, we can use `to` to convert the reply to a `seq[string]`.

## Working with replies

A call to `command` or `receive` will return a `RedisReply` object. You'll want to convert that into the types you expect. Ready makes that easy by providing the `to` proc.

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

## Connection pooling

Ready includes a built-in connection pool when compiled with `--threads:on`:

```nim
import ready

let redisPool = newRedisPool(3) # Defaults to localhost:6379

# This automatically removes a connection from the pool, runs the command
# and then returns it back to the pool
redisPool.command("PING")
```

Or, if you want to run more than one command with the same connection:

```nim
import ready

let redisPool = newRedisPool(3) # Defaults to localhost:6379

redisPool.withConnection conn:
    # `conn` is automatically recycled back into the pool after this block
    discard conn.command("PING")
```

Reusing Redis connections is much faster and more efficient than opening new connections for every command.

## Pipelining commands and transactions

Ready also includes separate `send` and `receive` calls as an alternative to the `command` call. These commands make pipelining commands easy:

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

# Match the number of `receive` calls to the number of commands sent

discard redis.receive() # OK
discard redis.receive() # QUEUED
discard redis.receive() # QUEUED
let (num, _) = redis.receive().to((int, string))
```

Pipelining as an advanced technique when using Redis that can drastically increase performance when possible.

Important! Remember to match the number of `receive` calls to the number of commands sent.

## Publish and subscribe (PubSub)

Ready makes it easy to use Redis's [PubSub](https://redis.io/docs/manual/pubsub/) functionality.

Here we dedicate a thread to receiving messages on a PubSub connection while our other thread is free to send commands like `SUBSCRIBE` and `UNSUBSCRIBE` to manage the PubSub connection.

```nim
let pubsub = newRedisConn() # Defaults to localhost:6379

proc receiveThreadProc() =
  try:
    while true:
      let reply = pubsub.receive()
      echo "Event: ", reply[0].to(string)
      echo "Channel: ", reply[1].to(string)
      echo "Raw: ", reply
  except RedisError as e:
    echo e.msg

var receiveThread: Thread[void]
createThread(receiveThread, receiveThreadProc)

pubsub.send("SUBSCRIBE", "mychannel")
```

Note that using PubSub with Ready requires threads.

## Pro Tips

You can use Ready in two ways, either by calling `command` or by calling `send` and `receive`. Calling `command` is the equivalent of calling `send` and then calling `receive` immediately.

Whenever a `command` or `receive` call gets an error reply from Redis a `RedisError` is raised. This means discarding the reply in `discard redis.command("PING")` is perfectly ok. If the reply was an error an exception would have been raised.

If you open a short-lived Redis connection, remember to call `close` when you no longer need it. The connections are not garbage collected. (For HTTP servers this is unlikely, see [#1](https://github.com/guzba/ready/issues/1#issuecomment-1586255510) for a brief discussion.)

## Why use `send` and `receive` separately? Two reasons:

First, where possible, it is more efficient to pipeline many Redis commands. This is easy to do with Ready, just call `send` multiple times (or ideally call `send` with a seq of commands).

Second, you may want to have a separate thread be sending vs receiving. A common use of this is [PubSub](https://redis.io/docs/manual/pubsub/), where one thread is dedicated to receiving messages and the sending thread manages what channels are subscribed to. See [this example](https://github.com/guzba/ready/blob/master/examples/pubsub.nim).
