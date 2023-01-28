import std/nativesockets, std/sequtils, std/os, std/strutils, std/parseutils, std/options, std/typetraits

when defined(windows):
  import winlean
elif defined(posix):
  import posix

export Port

## RESP https://redis.io/docs/reference/protocol-spec/

const
  initialRecvBufLen = (32 * 1024) - 9 # 8 byte cap field + null terminator

type
  RedisError* = object of CatchableError

  RedisConnObj = object
    socket: SocketHandle
    recvBuf: string
    bytesReceived, recvPos: int

  RedisConn* = ptr RedisConnObj

  RedisReplyKind = enum
    SimpleStringReply, BulkStringReply, IntegerReply, ArrayReply

  RedisReply* = object
    case kind: RedisReplyKind
    of SimpleStringReply:
      simple: string
    of BulkStringReply:
      bulk: Option[string]
    of IntegerReply:
      value: int
    of ArrayReply:
      elements: seq[RedisReply]

proc `$`*(conn: RedisConn): string =
  "RedisConn " & $cast[uint](conn)

proc `$`*(reply: RedisReply): string =
  case reply.kind:
  of IntegerReply:
    $reply.value
  of SimpleStringReply:
    reply.simple
  of BulkStringReply:
    $reply.bulk
  of ArrayReply:
    "[" & join(reply.elements, ", ") & "]"

proc close*(conn: RedisConn) {.raises: [], gcsafe.} =
  ## Closes and deallocates the connection.
  if conn.socket.int > 0:
    discard conn.socket.shutdown(when defined(windows): 2 else: SHUT_RDWR)
    conn.socket.close()
  `=destroy`(conn[])
  deallocShared(conn)

proc send*(
  conn: RedisConn,
  commands: openarray[(string, seq[string])]
) {.raises: [RedisError].} =
  var msg: string
  for (command, args) in commands:
    msg.add "*" & $(1 + args.len) & "\r\n"
    msg.add "$" & $command.len & "\r\n" & command & "\r\n"
    for arg in args:
      msg.add "$" & $arg.len & "\r\n" & arg & "\r\n"

  if conn.socket.send(msg[0].addr, msg.len.cint, 0) < 0:
    raise newException(RedisError, osErrorMsg(osLastError()))

proc send*(
  conn: RedisConn,
  command: string,
  args: varargs[string]
) {.inline, raises: [RedisError].} =
  conn.send([(command, toSeq(args))])

proc redisParseInt(buf: string, first: int): int =
  try:
    discard parseInt(buf, result, first)
  except ValueError:
    raise newException(RedisError, "Error parsing number")

proc findReplyEnd(
  conn: RedisConn, start: int
): int {.raises: [RedisError].} =
  if start < conn.bytesReceived:
    let dataType = conn.recvBuf[start]
    case dataType:
    of '+', '-', ':':
      let simpleEnd = conn.recvBuf.find("\r\n", start + 1, conn.bytesReceived - 1)
      if simpleEnd > 0:
        return simpleEnd + 2
    of '$':
      let lenEnd = conn.recvBuf.find("\r\n", start + 1, conn.bytesReceived - 1)
      if lenEnd > 0:
        let
          strLen = redisParseInt(conn.recvBuf, start + 1)
          respEnd =
            if strLen >= 0:
              lenEnd + 2 + strLen + 2
            else:
              lenEnd + 2
        if respEnd <= conn.bytesReceived:
          return respEnd
    of '*':
      let numEnd = conn.recvBuf.find("\r\n", start + 1, conn.bytesReceived - 1)
      if numEnd > 0:
        let numElements = redisParseInt(conn.recvBuf, start + 1)
        var nextElementStart = numEnd + 2
        for i in 0 ..< numElements:
          nextElementStart = conn.findReplyEnd(nextElementStart)
          if nextElementStart == -1:
            break
        return nextElementStart
    else:
      raise newException(
        RedisError,
        "Unexpected RESP data type " & dataType & " (" & $dataType.uint8 & ")"
      )

  # We have not received the end of the RESP data yet
  return -1

proc parseReply(buf: string, pos: var int): RedisReply {.raises: [RedisError].} =
  let dataType = buf[pos]
  inc pos
  case dataType:
  of '-':
    let simpleEnd = buf.find("\r\n", pos)
    raise newException(RedisError, buf[pos ..< simpleEnd])
  of '+':
    result = RedisReply(kind: SimpleStringReply)
    let simpleEnd = buf.find("\r\n", pos)
    result.simple = buf[pos ..< simpleEnd]
    pos = simpleEnd + 2
  of ':':
    result = RedisReply(kind: IntegerReply)
    let simpleEnd = buf.find("\r\n", pos)
    result.value = redisParseInt(buf, pos)
    pos = simpleEnd + 2
  of '$':
    result = RedisReply(kind: BulkStringReply)
    let
      lenEnd = buf.find("\r\n", pos)
      strlen = redisParseInt(buf, pos)
    pos = lenEnd + 2
    if strLen >= 0:
      result.bulk = some(buf[pos ..< pos + strLen])
    else:
      result.bulk = none(string)
    pos += strLen + 2
  of '*':
    result = RedisReply(kind: ArrayReply)
    let
      numEnd = buf.find("\r\n", pos)
      numElements = redisParseInt(buf, pos)
    pos = numEnd + 2
    for i in 0 ..< numElements:
      result.elements.add(parseReply(buf, pos))
  else:
    raise newException(
      RedisError,
      "Unexpected RESP data type " & dataType & " (" & $dataType.uint8 & ")"
    )

proc receive*(
  conn: RedisConn
): RedisReply {.raises: [RedisError].} =
  ## Receives a single reply from the Redis server.
  while true:
    # Check the receive buffer for the reply
    if conn.bytesReceived > 0:
      let replyEnd = conn.findReplyEnd(conn.recvPos)
      if replyEnd > 0:
        # We have the reply, parse it
        try:
          var pos = conn.recvPos
          result = parseReply(conn.recvBuf, pos)
        finally:
          conn.recvPos = replyEnd
          if conn.bytesReceived == conn.recvPos:
            conn.bytesReceived = 0
            conn.recvPos = 0
        break

    # Expand the buffer if it is full
    if conn.bytesReceived == conn.recvBuf.len:
      conn.recvBuf.setLen(conn.recvBuf.len * 2)

    # Read more response data
    let bytesReceived = conn.socket.recv(
      conn.recvBuf[conn.bytesReceived].addr,
      (conn.recvBuf.len - conn.bytesReceived).cint,
      0
    )
    if bytesReceived > 0:
      conn.bytesReceived += bytesReceived
    else:
      raise newException(RedisError, osErrorMsg(osLastError()))

proc command*(
  conn: RedisConn,
  command: string,
  args: varargs[string]
): RedisReply {.raises: [RedisError]} =
  conn.send([(command, toSeq(args))])
  conn.receive()

proc newRedisConn*(
  port = Port(6379),
  address = "localhost"
): RedisConn {.raises: [OSError].} =
  result = cast[RedisConn](allocShared0(sizeof(RedisConnObj)))
  result.recvBuf.setLen(initialRecvBufLen)

  try:
    result.socket = createNativeSocket(
      Domain.AF_INET,
      SockType.SOCK_STREAM,
      Protocol.IPPROTO_TCP,
      false
    )
    if result.socket == osInvalidSocket:
      raiseOSError(osLastError())

    let ai = getAddrInfo(
      address,
      port,
      Domain.AF_INET,
      SockType.SOCK_STREAM,
      Protocol.IPPROTO_TCP,
    )
    try:
      if result.socket.connect(ai.ai_addr, ai.ai_addrlen.SockLen) < 0:
        raiseOSError(osLastError())
    finally:
      freeAddrInfo(ai)
  except OSError as e:
    result.close()
    raise e

proc to*[T](reply: RedisReply, t: typedesc[T]): T =
  when t is SomeInteger:
    case reply.kind:
    of SimpleStringReply:
      raise newException(RedisError, "Cannot convert string to " & $t)
    of IntegerReply:
      cast[T](reply.value)
    of BulkStringReply:
      if reply.bulk.isSome:
        cast[T](redisParseInt(reply.bulk.get(), 0))
      else:
        raise newException(RedisError, "Reply is nil")
    of ArrayReply:
      raise newException(RedisError, "Cannot convert array to " & $t)
  elif t is string:
    case reply.kind:
    of SimpleStringReply:
      reply.simple
    of BulkStringReply:
      if reply.bulk.isSome:
        reply.bulk.get()
      else:
        raise newException(RedisError, "Reply is nil")
    of IntegerReply:
      $reply.value
    of ArrayReply:
      raise newException(RedisError, "Cannot convert array to " & $t)
  elif t is Option[string]:
    case reply.kind:
    of SimpleStringReply:
      some(reply.simple)
    of BulkStringReply:
      reply.bulk
    of IntegerReply:
      some($reply.value)
    of ArrayReply:
      raise newException(RedisError, "Cannot convert array to " & $t)
  elif t is seq[int]:
    case reply.kind:
    of ArrayReply:
      for element in reply.elements:
        result.add(element.to(int))
    else:
      raise newException(RedisError, "Cannot convert non-array reply to " & $t)
  elif t is seq[string]:
    case reply.kind:
    of ArrayReply:
      for element in reply.elements:
        result.add(element.to(string))
    else:
      raise newException(RedisError, "Cannot convert non-array reply to " & $t)
  elif t is tuple:
    case reply.kind:
    of ArrayReply:
      var i: int
      for name, value in result.fieldPairs:
        if i == reply.elements.len:
          raise newException(RedisError, "Reply array len < tuple len")
        when value is SomeInteger:
          value = reply.elements[i].to(typeof(value))
        elif value is string:
          value = reply.elements[i].to(string)
        elif value is Option[string]:
          value = reply.elements[i].to(Option[string])
        elif value is seq[int]:
          value = reply.elements[i].to(seq[int])
        elif value is seq[string]:
          value = reply.elements[i].to(seq[string])
        inc i
      if i != reply.elements.len:
        raise newException(RedisError, "Reply array len > tuple len")
    else:
      raise newException(RedisError, "Cannot convert non-array reply to " & $t)
  else:
    {.error: "Coverting to " & $t & " not supported.".}

proc `[]`*(reply: RedisReply, index: int): RedisReply =
  if reply.kind == ArrayReply:
    reply.elements[index]
  else:
    raise newException(RedisError, "Reply is not an array")
