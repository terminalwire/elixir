# Skip the conformance-corpus tests when no corpus is present, so `mix test` runs
# the fast unit suite standalone (this repo's own CI). The protocol interop matrix
# sets TERMINALWIRE_CORPUS, which includes them.
exclude = if System.get_env("TERMINALWIRE_CORPUS"), do: [], else: [:corpus]
ExUnit.start(exclude: exclude)
