import ready, std/os

## This example shows how to do a simple multi-threaded PubSub where
## a thread is dedicated to receiving incoming messages and the other thread
## is free to send commands to manage the connection, such as more SUBSCRIBE
## commands or UNSUBSCRIBE commands.

## nim c --threads:on --mm:orc -r examples/pubsub.nim

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
createThread(receiveThread, receiveProc)

pubsub.send("SUBSCRIBE", "mychannel")

sleep(5000)
