import Config

# The library itself needs no configuration. These settings only configure
# the Phoenix endpoints used by TraceGuard's own test suite.
if config_env() == :test, do: import_config("test.exs")
