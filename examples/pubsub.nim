import hero, std/os

## nim c --threads:on --mm:orc -r examples/pubsub.nim

let pubsub = newRedisConn()

proc recvProc() =
  try:
    while true:
      let reply = pubsub.receive()
      echo "Event: ", reply[0].to(string)
      echo "Channel: ", reply[1].to(string)
      echo "Raw: ", reply
  except RedisError as e:
    echo e.msg

var recvThread: Thread[void]
createThread(recvThread, recvProc)

pubsub.send("SUBSCRIBE", "mychannel")

sleep(5000)
