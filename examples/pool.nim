import ready

## This example demonstrates creating a pool Redis connections, then using
## one of those connections to execute a command before it is returned
## to the pool.

## nim c --threads:on --mm:orc -r examples/pool.nim

let pool = newRedisPool(2) # Defaults to localhost:6379
pool.withConnnection redis:
  echo redis.command("INCR", "number").to(int)
