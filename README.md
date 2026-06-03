# Terminalwire (Elixir)

**Ship a CLI for your web app. No API required.**

Terminalwire streams a command-line app straight from your Phoenix/Plug server to
your users' machines over a single WebSocket. Instead of building an API,
generating an SDK, and shipping a separate client, you write your CLI *in your
app* — calling your contexts, Ecto, and business logic directly — and it runs on
the user's workstation with their terminal, files, and browser.

```
 Terminalwire client ⇄ WebSocket endpoint ⇄ Terminalwire.WebSock
                                            ⇄ Server.Session (protocol)
                                            ⇄ Server.Context ⇄ your CLI handler
```

## Why this is nice

- **No API to build or version.** Your CLI calls your app's code directly — no
  serializers, no SDK, no client/server version skew.
- **It feels local.** Output streams in real time, prompts and passwords work,
  it's color/TTY-aware, resizes with the window, `Ctrl-C` interrupts the
  server-side command, and you can pipe into it (`cat data.csv | your-app import`).
- **Secure by construction.** The client is the trust boundary: the server
  *requests* access to a file/env var/the browser and the client enforces a
  per-app entitlement policy. Your server never touches the user's machine.
- **One BEAM process per session.** Each connection is a supervised process; the
  CLI handler runs in its own task. Natural fit for Phoenix.
- **Same protocol, any client.** This server speaks the exact wire protocol the
  Go client and the Ruby server do — proven by a shared conformance corpus.

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
