import hero

## nim c --threads:on --mm:orc -r examples/pool.nim

let pool = newRedisPool(1)
pool.withConnnection redis:
  echo redis.roundtrip("INCR", "number").to(int)
