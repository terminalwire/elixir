defmodule Terminalwire.Server.Terminal do
  @moduledoc """
  The client's terminal, as seen by the server. A typed view over the raw
  handshake `terminal` map so server code reads `t.cols` / `t.tty?` instead of
  digging through string-keyed maps. Mirrors the Ruby server's Terminal accessor.
  """

  defstruct cols: 80, rows: 24, term: "", color: "none", encoding: "UTF-8",
            stdin_tty: false, stdout_tty: false, stderr_tty: false

  @type t :: %__MODULE__{}

  @doc "Build from the raw `hello.terminal` map (string keys); nil-safe."
  def from_map(nil), do: %__MODULE__{}

  def from_map(map) when is_map(map) do
    device = Map.get(map, "device", %{})

    %__MODULE__{
      cols: Map.get(device, "cols", 80),
      rows: Map.get(device, "rows", 24),
      term: Map.get(device, "term", ""),
      color: Map.get(device, "color", "none"),
      encoding: Map.get(device, "encoding", "UTF-8"),
      stdin_tty: tty?(map, "stdin"),
      stdout_tty: tty?(map, "stdout"),
      stderr_tty: tty?(map, "stderr")
    }
  end

  @doc "Does the client have a real terminal (any standard stream is a tty)?"
  def tty?(%__MODULE__{stdin_tty: i, stdout_tty: o, stderr_tty: e}), do: i or o or e

  defp tty?(map, stream), do: get_in(map, [stream, "kind"]) == "tty"
end
