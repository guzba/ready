import std/nativesockets, std/sequtils, std/os, std/strutils, std/parseutils,
    std/options

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
    bytesReceived: int

  RedisConn* = ptr RedisConnObj

  RedisReply* = object
    entries: seq[Option[string]]

proc `$`*(reply: RedisReply): string =
  $reply.entries

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

  if conn.socket.send(msg[0].addr, msg.len, 0) < 0:
    raise newException(RedisError, osErrorMsg(osLastError()))

proc send*(
  conn: RedisConn,
  command: string,
  args: varargs[string]
) {.raises: [RedisError].} =
  conn.send([(command, toSeq(args))])

proc parseReplyEntry(reply: string, pos: var int): Option[string] =
  let dataType = reply[pos]
  inc pos
  case dataType:
  of '-':
    let simpleEnd = reply.find('\r', pos, reply.high)
    raise newException(RedisError, reply[pos ..< simpleEnd])
  of '+', ':':
    let simpleEnd = reply.find('\r', pos, reply.high)
    result = some(reply[pos ..< simpleEnd])
    pos = simpleEnd + 2
  of '$':
    let lenEnd = reply.find('\r', pos, reply.high)
    var strLen: int
    try:
      discard parseInt(reply, strLen, pos)
      # raise newException(ValueError, "HERE")
    except ValueError:
      # Unrecoverable?
      raise newException(
        RedisError,
        "Error parsing Bulk String length: " &
        reply[pos ..< lenEnd]
      )
    pos = lenEnd + 2
    result =
      if strLen >= 0:
        some(reply[pos ..< pos + strLen])
      else:
        none(string)
    pos += strLen + 2
  else:
    raise newException(
      RedisError,
      "Unexpected RESP entry type " & dataType & " (" & $dataType.uint8 & ")"
    )

proc parseReply(reply: string, parsed: var seq[Option[string]]) =
  var pos = 0
  if reply[pos] == '*':
    let numEnd = reply.find('\r', 1, reply.high)
    var numElements: int
    try:
      discard parseInt(reply, numElements, 1)
    except ValueError:
      # Unrecoverable?
      raise newException(
        RedisError,
        "Error parsing number of elements in array: " &
        reply[1 ..< numEnd]
      )
    pos = numEnd + 2
    for i in 0 ..< numElements:
      parsed.add(parseReplyEntry(reply, pos))
  else:
    parsed.add(parseReplyEntry(reply, pos))

proc findReplyEnd(conn: RedisConn, start: int): int {.raises: [RedisError].} =
  if start < conn.recvBuf.len:
    let dataType = conn.recvBuf[start]
    case dataType:
    of '+', '-', ':':
      let simpleEnd = conn.recvBuf.find('\n', start + 1, conn.bytesReceived - 1)
      if simpleEnd > 0:
        return simpleEnd + 1
    of '$':
      let lenEnd = conn.recvBuf.find('\n', start + 1, conn.bytesReceived - 1)
      if lenEnd > 0:
        var strLen: int
        try:
          discard parseInt(conn.recvBuf, strLen, start + 1)
        except ValueError:
          # Unrecoverable?
          raise newException(
            RedisError,
            "Error parsing Bulk String length: " &
            conn.recvBuf[start + 1 ..< lenEnd]
          )
        let respEnd =
          if strLen >= 0:
            lenEnd + 1 + strLen + 2
          else:
            lenEnd + 1
        if respEnd <= conn.bytesReceived:
          return respEnd
    of '*':
      let numEnd = conn.recvBuf.find('\n', start + 1, conn.bytesReceived - 1)
      if numEnd > 0:
        var numElements: int
        try:
          discard parseInt(conn.recvBuf, numElements, start + 1)
        except ValueError:
          # Unrecoverable?
          raise newException(
            RedisError,
            "Error parsing number of elements in array: " &
            conn.recvBuf[start + 1 ..< numEnd]
          )
        var nextElementStart = numEnd + 1
        for i in 0 ..< numElements:
          nextElementStart = conn.findReplyEnd(nextElementStart)
          if nextElementStart == -1:
            break
        return nextElementStart
    else:
      # Unrecoverable?
      raise newException(
        RedisError,
        "Unexpected RESP data type " & dataType & " (" & $dataType.uint8 & ")"
      )

  # We have not received the end of the RESP data yet
  return -1

proc recv*(conn: RedisConn): RedisReply {.raises: [RedisError].} =
  ## Receives a single reply from the Redis server.
  while true:
    # Check the receive buffer for the reply
    if conn.bytesReceived > 0:
      let replyLen = conn.findReplyEnd(0)
      if replyLen > 0:
        # We have the reply, remove it from the receive buffer
        var reply = newString(replyLen)
        copyMem(
          reply[0].addr,
          conn.recvBuf[0].addr,
          replyLen
        )
        conn.bytesReceived -= replyLen
        if conn.bytesReceived > 0:
          copyMem(
            conn.recvBuf[0].addr,
            conn.recvBuf[replyLen].addr,
            conn.bytesReceived
          )
        # Parse after cleaning up the receive buffer in case this raises
        parseReply(reply, result.entries)
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

proc sendRecv*(
  conn: RedisConn,
  command: string,
  args: varargs[string]
): RedisReply =
  conn.send([(command, toSeq(args))])
  conn.recv()

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
