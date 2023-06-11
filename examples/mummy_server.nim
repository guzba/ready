import mummy, mummy/routers, ready

## This example shows how to use Ready and Mummy for an HTTP server.
##
## We set up a simple server and use Redis to maintain a simple request counter.

let pool = newRedisPool(2) # Defaults to localhost:6379

proc indexHandler(request: Request) =
  let count = pool.command("INCR", "index_request_counter").to(int)

  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  request.respond(
    200,
    headers,
    "Hello, World! This is request " & $count & " to this server."
  )

var router: Router
router.get("/", indexHandler)

let server = newServer(router)
echo "Serving on http://localhost:8080"
server.serve(Port(8080))
