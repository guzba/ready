import ready, std/times

const
  iterations = 10_000
  testKey = "test_key"

var testValue: string
for i in 0 ..< 10_000:
  testValue.add('a')

block:
  let ready = newRedisConn()
  discard ready.command("SET", testKey, testValue)
  ready.close()

block:
  let start = epochTime()

  let ready = newRedisConn()

  for _ in 0 ..< iterations:
    let r = ready.command("GET", testKey).to(string)
    doAssert r.len == testValue.len

  echo epochTime() - start

import redis

block:
  let start = epochTime()

  let nim = open()

  for _ in 0 ..< iterations:
    let r = nim.get(testKey)
    doAssert r.len == testValue.len

  echo epochTime() - start
