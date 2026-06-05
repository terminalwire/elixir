defmodule Terminalwire.Frames do
  @moduledoc """
  Builders for each frame type — the wire shape defined in one place. Every
  builder returns a map with string keys. Mirrors `Terminalwire::V2::Frames`.
  """

  alias Terminalwire.Protocol
  alias Terminalwire.Protocol.{Type, Signal}

  @control Protocol.control_sid()

  def welcome(protocol, capabilities) do
    %{
      "t" => Type.welcome(),
      "sid" => @control,
      "protocol" => protocol,
      "capabilities" => capabilities
    }
  end

  def incompatible(min, max, message) do
    %{
      "t" => Type.incompatible(),
      "sid" => @control,
      "supported" => %{"min" => min, "max" => max},
      "message" => message
    }
  end

  def exit(status) do
    %{"t" => Type.exit(), "sid" => @control, "status" => status}
  end

  def open(sid, stream, mode \\ nil) do
    base = %{"t" => Type.open(), "sid" => sid, "stream" => stream}
    if mode, do: Map.put(base, "mode", mode), else: base
  end

  @doc "A data frame. `bytes` is wrapped as MessagePack `bin` for cross-language interop."
  def data(sid, bytes) when is_binary(bytes) do
    %{"t" => Type.data(), "sid" => sid, "bytes" => Msgpax.Bin.new(bytes)}
  end

  def close(sid), do: %{"t" => Type.close(), "sid" => sid}

  def request(sid, resource, method, params \\ %{}) do
    %{
      "t" => Type.request(),
      "sid" => sid,
      "resource" => resource,
      "method" => method,
      "params" => params
    }
  end

  def response_ok(sid, value) do
    %{"t" => Type.response(), "sid" => sid, "ok" => true, "value" => value}
  end

  def response_error(sid, code, message) do
    %{
      "t" => Type.response(),
      "sid" => sid,
      "ok" => false,
      "error" => %{"code" => code, "message" => message}
    }
  end

  def signal(name, payload \\ %{}) do
    Map.merge(%{"t" => Type.signal(), "sid" => @control, "name" => name}, payload)
  end

  def resize(cols, rows), do: signal(Signal.resize(), %{"cols" => cols, "rows" => rows})
  def interrupt, do: signal(Signal.interrupt())

  def window_adjust(sid, bytes) do
    %{"t" => Type.window_adjust(), "sid" => sid, "bytes" => bytes}
  end
end
