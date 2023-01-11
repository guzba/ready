import ready

## This example demonstrates pipelining mulitple Redis commands before
## calling receive to get the replies.
##
## Remember to call receive for every command you sent~

let redis = newRedisConn() # Defaults to localhost:6379

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

echo num
