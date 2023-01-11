import ready, std/options

## This example demonstrates opening a Redis connection, sending a command and
## then receiving the reply.

let redis = newRedisConn() # Defaults to localhost:6379

let reply = redis.roundtrip("GET", "mykey").to(Option[string])

echo reply
