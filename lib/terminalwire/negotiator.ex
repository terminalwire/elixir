defmodule Terminalwire.Negotiator do
  @moduledoc """
  Pure handshake negotiation: given what the client speaks and what the server
  supports, decide the agreed protocol version and capability set. A function,
  not a state machine — identical across languages (conformance/vectors/negotiate).
  Mirrors `Terminalwire::V2::Negotiator`.
  """

  @doc """
  Returns `{:welcome, protocol, capabilities}` or `{:incompatible, min, max}`.

  `capabilities` is the intersection, preserving the client's advertised order.
  """
  def negotiate(client_protocol, client_capabilities, server_min, server_max, server_capabilities) do
    if client_protocol < server_min do
      {:incompatible, server_min, server_max}
    else
      agreed = min(client_protocol, server_max)
      server_set = MapSet.new(server_capabilities)
      caps = Enum.filter(client_capabilities, &MapSet.member?(server_set, &1))
      {:welcome, agreed, caps}
    end
  end
end
