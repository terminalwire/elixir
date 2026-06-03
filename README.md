# Terminalwire (Elixir)

Terminalwire v2 server for Elixir — the layer **between your WebSocket endpoint
(Phoenix / Bandit / Plug.Cowboy) and your CLI / terminal code**. Stream a
command-line app from your server to the Terminalwire client over a single
WebSocket, with no web API.

```
 Terminalwire client ⇄ WebSocket endpoint ⇄ Terminalwire.WebSock
                                            ⇄ Server.Session (protocol)
                                            ⇄ Server.Context ⇄ your CLI handler
```

## Install

```elixir
def deps do
  [
    {:terminalwire, "~> 0.1"},
    {:websock_adapter, "~> 0.5"}   # to upgrade a Plug/Phoenix conn to a socket
  ]
end
```

## Use

Write a handler that takes a `Terminalwire.Server.Context` — this is where you
parse args (with any CLI library) and talk to the user's terminal:

```elixir
defmodule MyCLI do
  alias Terminalwire.Server.Context

  def run(ctx) do
    case Context.args(ctx) do
      ["deploy" | _] ->
        env = Context.gets(ctx, "Environment? ") |> String.trim()
        Context.puts(ctx, "Deploying to #{env}…")
        0

      _ ->
        Context.warn(ctx, "unknown command")
        1
    end
  end
end
```

Upgrade your WebSocket route to the ready-made adapter:

```elixir
# Plug / Bandit / Cowboy
WebSockAdapter.upgrade(conn, Terminalwire.WebSock, [handler: &MyCLI.run/1], [])
```

## Architecture

| layer | module |
|-------|--------|
| sans-IO protocol core | `Terminalwire.Protocol`, `Codec`, `Negotiator`, `Frames` |
| sans-IO server state machine | `Terminalwire.Server.Connection` |
| process that drives it | `Terminalwire.Server.Session` |
| CLI-facing API | `Terminalwire.Server.Context` |
| WebSocket adapter | `Terminalwire.WebSock` |

The protocol core mirrors the Ruby server (`terminalwire2`) and the Go client,
and is validated against the **same language-neutral conformance corpus** in
`terminalwire/protocol` — run `mix test` with `TERMINALWIRE_CORPUS` pointed at it.
That corpus is the cross-implementation contract: pass it and this server
interoperates on the wire with the client and every other server.

## License

Apache-2.0 (source-available — safe to install on your own servers).
