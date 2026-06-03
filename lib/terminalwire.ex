defmodule Terminalwire do
  @moduledoc """
  Terminalwire v2 server for Elixir.

  Stream a command-line app from your Phoenix/Plug/Cowboy server to the
  Terminalwire client over a single WebSocket — no web API required. This package
  is the layer **between your WebSocket endpoint and your CLI/terminal code**.

  ## Quick start

  Write a handler that takes a `Terminalwire.Server.Context`:

      defmodule MyCLI do
        alias Terminalwire.Server.Context

        def run(ctx) do
          case Context.args(ctx) do
            ["deploy" | _] ->
              env = Context.gets(ctx, "Environment? ")
              Context.puts(ctx, "Deploying to " <> String.trim(env) <> "…")
              0

            _ ->
              Context.warn(ctx, "unknown command")
              1
          end
        end
      end

  Upgrade your WebSocket route to `Terminalwire.WebSock` with that handler:

      WebSockAdapter.upgrade(conn, Terminalwire.WebSock, [handler: &MyCLI.run/1], [])

  ## Layers

    * `Terminalwire.Protocol` / `Terminalwire.Codec` / `Terminalwire.Negotiator` /
      `Terminalwire.Frames` — the sans-IO protocol core (mirrors the Ruby gem and
      the language-neutral conformance corpus).
    * `Terminalwire.Server.Connection` — the sans-IO server state machine.
    * `Terminalwire.Server.Session` — the process that drives it over a transport.
    * `Terminalwire.Server.Context` — the CLI-facing API.
    * `Terminalwire.WebSock` — the ready-made WebSocket adapter.
  """
end
