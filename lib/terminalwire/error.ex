defmodule Terminalwire.ProtocolError do
  @moduledoc "Raised when bytes off the wire are not a well-formed frame."
  defexception [:message]
end

defmodule Terminalwire.ResponseError do
  @moduledoc "Raised server-side when a `response` comes back with ok: false."
  defexception [:code, :message]

  @impl true
  def exception(opts) do
    code = Keyword.get(opts, :code, "internal")
    message = Keyword.get(opts, :message, "request failed")
    %__MODULE__{code: code, message: "#{code}: #{message}"}
  end
end
