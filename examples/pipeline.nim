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
  reply1 = redis.receive() # OK
  reply2 = redis.receive() # QUEUED
  reply3 = redis.receive() # QUEUED
  reply4 = redis.receive() # 1, OK

echo reply1.to(string)
echo reply2.to(string)
echo reply3.to(string)
echo reply4.to((int, string))