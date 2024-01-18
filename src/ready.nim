import ready/connections
export connections

when compileOption("threads"):
  when not defined(nimdoc):
    when not defined(gcArc) and not defined(gcOrc):
      {.error: "Ready requires --mm:arc or --mm:orc when --threads:on.".}

  ## Using the connection pool requires --threads:on
  import ready/pools
  export pools
