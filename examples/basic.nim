import hero, std/options

let redis = newRedisConn()

let reply = redis.roundtrip("GET", "mykey").to(Option[string])

echo reply
