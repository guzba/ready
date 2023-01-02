import hero/connections
export connections

when compileOption("threads"):
  ## Using the connection pool requires --threads:on
  import hero/pools
  export pools
