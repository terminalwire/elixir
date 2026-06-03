defmodule Terminalwire.Server.Adapter do
  @moduledoc """
  The seam between a WebSocket endpoint and Terminalwire. Your transport
  (Phoenix.Socket, Plug.Cowboy WebSock, raw Cowboy) implements this by forwarding
  binary frames in and providing a way to push binary frames out.

  The integration shape is symmetric on every transport:

    * inbound: when the socket receives a binary message, call
      `Terminalwire.Server.Session.receive_frame(session, bytes)`
    * outbound: give the session an `on_send` function (1-arity, takes iodata/
      binary) that pushes a binary WebSocket frame to the client.

  This module documents that contract; see `Terminalwire.Server.Session` for the
  driver and `Terminalwire.WebSock` for a ready-made `WebSock`-based adapter that
  works with Phoenix, Bandit, and Plug.Cowboy.
  """

  @typedoc "A function that pushes one binary frame to the client over the socket."
  @type sender :: (binary() -> any())
end
