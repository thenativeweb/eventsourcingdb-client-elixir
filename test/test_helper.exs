Testcontainers.start_link()

# The tests start their containers in their setup, which counts towards their
# timeout, and a start that replaces two containers in which the database does
# not become reachable takes three times the startup timeout of 30 seconds.
ExUnit.start(timeout: 3 * 30_000 + 60_000)
