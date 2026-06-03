defmodule Terminalwire.WebSock do
  @moduledoc """
  A ready-made [`WebSock`](https://hex.pm/packages/websock) handler that bridges a
  WebSocket connection to a `Terminalwire.Server.Session`. WebSock is the common
  interface spoken by Phoenix, Bandit, and Plug.Cowboy, so this one module wires
  Terminalwire into all of them.

  You supply a `:handler` — `fun(Terminalwire.Server.Context.t())` — that is your
  CLI. Everything between the socket and that function (handshake, framing, flow,
  request/response) is handled here.

  ## Plug / Bandit / Cowboy

      # in a Plug pipeline
      WebSockAdapter.upgrade(conn, Terminalwire.WebSock, [handler: &MyCLI.run/1], [])

  ## Phoenix

      # in your endpoint/router, upgrade the connection to this handler:
      conn
      |> WebSockAdapter.upgrade(Terminalwire.WebSock, [handler: &MyCLI.run/1], timeout: :infinity)

  The handler runs once the client completes the handshake; its integer return
  value (if any) becomes the exit code.

  > This module has an optional dependency on `:websock`. Add `{:websock, "~> 0.5"}`
  > (and an adapter like `:websock_adapter`) to your app to use it.
  """

  # We don't `use WebSock` (optional dep); we implement its callbacks by name so
  # the module compiles even when :websock isn't present. WebSock dispatches by
  # arity/name, so these match its behaviour.

  @doc false
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    parent = self()

    {:ok, session} =
      Terminalwire.Server.Session.start_link(
        handler: handler,
        on_send: fn bytes -> send(parent, {:tw_push, bytes}) end,
        server_capabilities: Keyword.get(opts, :server_capabilities),
        server_min: Keyword.get(opts, :server_min),
        server_max: Keyword.get(opts, :server_max)
      )

    {:ok, %{session: session}}
  end

  @doc false
  def handle_in({bytes, [opcode: :binary]}, state) do
    Terminalwire.Server.Session.receive_frame(state.session, bytes)
    {:ok, state}
  end

  # Ignore text frames — the protocol is binary msgpack.
  def handle_in({_data, [opcode: :text]}, state), do: {:ok, state}

  @doc false
  # The session pushes outbound frames to us as {:tw_push, bytes}; forward them as
  # binary WebSocket frames.
  def handle_info({:tw_push, bytes}, state) do
    {:push, {:binary, bytes}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @doc false
  def terminate(_reason, state) do
    if Process.alive?(state.session), do: Terminalwire.Server.Session.close(state.session)
    :ok
  end
end
