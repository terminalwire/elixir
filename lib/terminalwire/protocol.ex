defmodule Terminalwire.Protocol do
  @moduledoc """
  Wire-level constants for the Terminalwire v2 protocol. Mirrors the Ruby
  `Terminalwire2::Protocol` and the language-neutral conformance corpus — see the
  protocol spec. These values are part of the cross-language contract; do not
  change them without a corpus vector to match.
  """

  @version 2
  @min_version 2
  @max_version 2
  @control_sid 0

  # The default per-output-stream flow-control window (bytes) a peer offers.
  @default_window 256 * 1024

  @capabilities ~w(stdio file directory browser env signal flow raw-input terminal-query)

  def version, do: @version
  def min_version, do: @min_version
  def max_version, do: @max_version
  def control_sid, do: @control_sid
  def default_window, do: @default_window
  def capabilities, do: @capabilities

  defmodule Type do
    @moduledoc "Frame type tokens (the `t` field)."
    def hello, do: "hello"
    def welcome, do: "welcome"
    def incompatible, do: "incompatible"
    def exit, do: "exit"
    def open, do: "open"
    def data, do: "data"
    def close, do: "close"
    def request, do: "request"
    def response, do: "response"
    def signal, do: "signal"
    def window_adjust, do: "window_adjust"
  end

  defmodule Signal do
    @moduledoc "Names carried by a `signal` frame."
    def resize, do: "resize"
    def interrupt, do: "interrupt"
  end

  defmodule ErrorCode do
    @moduledoc "Error codes carried on a failed `response`."
    def denied, do: "denied"
    def not_found, do: "not_found"
    def io, do: "io"
    def protocol, do: "protocol"
    def internal, do: "internal"
  end
end
