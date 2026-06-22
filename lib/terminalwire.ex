defmodule Terminalwire do
  @moduledoc ~S"""
  Terminalwire v2 server for Elixir.

  Stream a command-line app from your Phoenix/Plug/Cowboy server to the
  Terminalwire client over a single WebSocket — no web API required. This package
  is the layer **between your WebSocket endpoint and your CLI/terminal code**.

  ## Quick start

  Define your CLI with `Terminalwire.CLI` — public functions are commands, their
  parameters are arguments, and `@desc` is the help text:

      defmodule MyApp.CLI do
        use Terminalwire.CLI, name: "my-app"

        @desc "Greet someone by name"
        def hello(name), do: puts("Hello, #{name}!")
      end

  Upgrade your WebSocket route to `Terminalwire.WebSock` with the generated `run/1`:

      WebSockAdapter.upgrade(conn, Terminalwire.WebSock, [handler: &MyApp.CLI.run/1], [])

  Prefer to parse args yourself? `Terminalwire.CLI` is sugar over a plain handler —
  a `run(ctx)` function taking a `Terminalwire.Server.Context`. Use that directly
  with any parser (`OptionParser`, Optimus, …).

  ## Layers

    * `Terminalwire.Protocol` / `Terminalwire.Codec` / `Terminalwire.Negotiator` /
      `Terminalwire.Frames` — the sans-IO protocol core (mirrors the Ruby gem and
      the language-neutral conformance corpus).
    * `Terminalwire.Server.Connection` — the sans-IO server state machine.
    * `Terminalwire.Server.Session` — the process that drives it over a transport.
    * `Terminalwire.Server.Context` — the CLI-facing API.
    * `Terminalwire.CLI` — the Thor-style command router (functions as commands).
    * `Terminalwire.WebSock` — the ready-made WebSocket adapter.
  """
end
