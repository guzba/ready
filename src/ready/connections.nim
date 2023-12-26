import std/nativesockets, std/os, std/strutils, std/parseutils,
    std/options, std/typetraits, std/atomics

when not defined(nimdoc):
  # nimdoc produces bizarre and annoying errors
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
    poisoned: Atomic[bool]

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

func `$`*(conn: RedisConn): string =
  "RedisConn " & $cast[uint](conn)

func `$`*(reply: RedisReply): string =
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
    when not defined(nimdoc):
      discard conn.socket.shutdown(when defined(windows): 2 else: SHUT_RDWR)
    conn.socket.close()
  `=destroy`(conn[])
  deallocShared(conn)

template raisePoisonedConnError() =
  raise newException(RedisError, "Redis connection is in a broken state")

proc send*(
  conn: RedisConn,
  commands: openarray[(string, seq[string])]
) {.raises: [RedisError].} =
  ## Sends commands to the Redis server.

  if conn.poisoned.load(moRelaxed):
    raisePoisonedConnError()

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
  ## Sends a command to the Redis server.

  # conn.send([(command, toSeq(args))])

  if conn.poisoned.load(moRelaxed):
    raisePoisonedConnError()

  var msg: string
  msg.add "*" & $(1 + args.len) & "\r\n"
  msg.add "$" & $command.len & "\r\n" & command & "\r\n"
  for arg in args:
    msg.add "$" & $arg.len & "\r\n" & arg & "\r\n"

  if conn.socket.send(msg[0].addr, msg.len.cint, 0) < 0:
    raise newException(RedisError, osErrorMsg(osLastError()))

proc recvBytes(conn: RedisConn) {.raises: [RedisError].} =
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

proc redisParseInt(conn: RedisConn): int =
  try:
    discard parseInt(conn.recvBuf, result, conn.recvPos)
  except ValueError:
    conn.poisoned.store(true, moRelaxed)
    raise newException(RedisError, "Error parsing number")

proc receive*(
  conn: RedisConn
): RedisReply {.raises: [RedisError].} =
  ## Receives a single reply from the Redis server.

  if conn.poisoned.load(moRelaxed):
    raisePoisonedConnError()

  if conn.recvPos == conn.bytesReceived:
    # If we haven't received any response data yet do an initial recv
    conn.recvBytes()

  let dataType = conn.recvBuf[conn.recvPos]
  inc conn.recvPos
  case dataType:
  of '-':
    while true:
      let simpleEnd = conn.recvBuf.find("\r\n", conn.recvPos)
      if simpleEnd > 0:
        var msg = conn.recvBuf[conn.recvPos ..< simpleEnd]
        conn.recvPos = simpleEnd + 2
        raise newException(RedisError, move msg)
      conn.recvBytes()
  of '+':
    result = RedisReply(kind: SimpleStringReply)
    while true:
      let simpleEnd = conn.recvBuf.find("\r\n", conn.recvPos)
      if simpleEnd > 0:
        result.simple = conn.recvBuf[conn.recvPos ..< simpleEnd]
        conn.recvPos = simpleEnd + 2
        break
      conn.recvBytes()
  of ':':
    result = RedisReply(kind: IntegerReply)
    while true:
      let simpleEnd = conn.recvBuf.find("\r\n", conn.recvPos)
      if simpleEnd > 0:
        result.value = redisParseInt(conn)
        conn.recvPos = simpleEnd + 2
        break
      conn.recvBytes()
  of '$':
    result = RedisReply(kind: BulkStringReply)
    while true:
      let lenEnd = conn.recvBuf.find("\r\n", conn.recvPos)
      if lenEnd > 0:
        let strLen = redisParseInt(conn)
        if strLen >= 0:
          if conn.bytesReceived >= lenEnd + 2 + strLen + 2:
            var bulk = newString(strLen)
            copyMem(bulk.cstring, conn.recvBuf[lenEnd + 2].addr, strLen)
            result.bulk = some(move bulk)
            conn.recvPos = lenEnd + 2 + strLen + 2
            break
        else:
          conn.recvPos = lenEnd + 2
          result.bulk = none(string)
          break
      conn.recvBytes()
  of '*':
    result = RedisReply(kind: ArrayReply)
    while true:
      let numEnd = conn.recvBuf.find("\r\n", conn.recvPos)
      if numEnd > 0:
        let numElements = redisParseInt(conn)
        conn.recvPos = numEnd + 2
        for i in 0 ..< numElements:
          result.elements.add(conn.receive())
        break
      conn.recvBytes()
  else:
    conn.poisoned.store(true, moRelaxed)
    raise newException(
      RedisError,
      "Unexpected RESP data type " & dataType & " (" & $dataType.uint8 & ")"
    )

  # If we've read to the end of the recv buffer, reset
  if conn.recvPos > 0 and conn.bytesReceived == conn.recvPos:
    conn.bytesReceived = 0
    conn.recvPos = 0

proc command*(
  conn: RedisConn,
  command: string,
  args: varargs[string]
): RedisReply {.raises: [RedisError]} =
  ## Sends a command to the Redis server and receives the reply.
  conn.send(command, args)
  conn.receive()

proc newRedisConn*(
  address = "localhost",
  port = Port(6379)
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
        cast[T](parseInt(reply.bulk.get))
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
        reply.bulk.get
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
  elif t is Option[int]:
    case reply.kind:
    of SimpleStringReply:
      raise newException(RedisError, "Cannot convert string to " & $t)
    of BulkStringReply:
      if reply.bulk.isSome:
        some(parseInt(reply.bulk.get))
      else:
        none(int)
    of IntegerReply:
      some(reply.value)
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
  elif t is seq[Option[string]]:
    case reply.kind:
    of ArrayReply:
      for element in reply.elements:
        case element.kind:
        of SimpleStringReply:
          result.add(some(element.simple))
        of BulkStringReply:
          result.add(element.bulk)
        of IntegerReply:
          result.add(some($element.value))
        of ArrayReply:
          raise newException(RedisError, "Cannot convert array to " & $t)
    else:
      raise newException(RedisError, "Cannot convert non-array reply to " & $t)
  elif t is seq[Option[int]]:
    case reply.kind:
    of ArrayReply:
      for element in reply.elements:
        case element.kind:
        of SimpleStringReply:
          raise newException(RedisError, "Cannot convert string to " & $t)
        of BulkStringReply:
          if element.bulk.isSome:
            result.add(some(parseInt(element.bulk.get)))
          else:
            result.add(none(int))
        of IntegerReply:
          result.add(some(element.value))
        of ArrayReply:
          raise newException(RedisError, "Cannot convert array to " & $t)
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
