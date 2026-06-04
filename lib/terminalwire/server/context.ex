defmodule Terminalwire.Server.Context do
  @moduledoc """
  The server's handle on the client's terminal — the API your CLI code calls.
  Output (`puts`/`print`/`warn`) is fire-and-forget; input and resource ops
  (`gets`, `read_secret`, `file`/`env` reads) are synchronous request/response.
  Mirrors `Terminalwire2::Server::Context`.

      def run(ctx) do
        Terminalwire.Server.Context.puts(ctx, "Deploying…")
        name = Terminalwire.Server.Context.gets(ctx, "Environment? ")
        Terminalwire.Server.Context.puts(ctx, "→ \#{name}")
        0
      end
  """

  alias Terminalwire.Server.Session
  alias Terminalwire.ResponseError

  @enforce_keys [:session]
  defstruct [:session, :program, :entitlement, :terminal, :capabilities]

  @type t :: %__MODULE__{}

  @default_timeout :timer.minutes(5)

  @doc false
  def new(session, ready_payload) do
    %__MODULE__{
      session: session,
      program: ready_payload[:program],
      entitlement: ready_payload[:entitlement],
      terminal: ready_payload[:terminal],
      capabilities: ready_payload[:capabilities] || []
    }
  end

  @doc "The program name + args the client launched with."
  def args(%__MODULE__{program: %{"args" => args}}), do: args
  def args(_), do: []

  @doc """
  The client's terminal as a `Terminalwire.Server.Terminal` struct
  (`cols`, `rows`, `tty?`, …), so server code can do `Context.terminal(ctx).cols`
  instead of digging through the raw handshake map.
  """
  def terminal(%__MODULE__{terminal: t}), do: Terminalwire.Server.Terminal.from_map(t)

  # --- output (one-way) ---

  def print(%__MODULE__{} = ctx, data),
    do: Session.emit_output(ctx.session, :stdout, to_string(data))

  def puts(%__MODULE__{} = ctx, data \\ ""), do: print(ctx, "#{data}\n")

  def warn(%__MODULE__{} = ctx, data \\ ""),
    do: Session.emit_output(ctx.session, :stderr, "#{data}\n")

  # --- input / resources (request/response) ---

  def gets(%__MODULE__{} = ctx, prompt \\ nil) do
    if prompt, do: print(ctx, prompt)
    request!(ctx, "stdin", "gets", %{})
  end

  def read_secret(%__MODULE__{} = ctx, prompt \\ nil) do
    if prompt, do: print(ctx, prompt)
    request!(ctx, "stdin", "getpass", %{})
  end

  def env(%__MODULE__{} = ctx, name),
    do: request!(ctx, "env", "read", %{"name" => to_string(name)})

  def file_read(%__MODULE__{} = ctx, path),
    do: request!(ctx, "file", "read", %{"path" => to_string(path)})

  def file_write(%__MODULE__{} = ctx, path, content) do
    request!(ctx, "file", "write", %{"path" => to_string(path), "content" => content})
  end

  @doc "End the session with an exit status (defaults to 0)."
  def exit(%__MODULE__{} = ctx, status \\ 0), do: Session.exit(ctx.session, status)

  # --- internals ---

  @doc "Lower-level: returns {:ok, value} | {:error, code, message}."
  def request(%__MODULE__{} = ctx, resource, method, params, timeout \\ @default_timeout) do
    Session.request(ctx.session, resource, method, params, timeout)
  end

  defp request!(ctx, resource, method, params) do
    case request(ctx, resource, method, params) do
      {:ok, value} -> unwrap(value)
      {:error, code, message} -> raise ResponseError, code: code, message: message
    end
  end

  # A response value may carry binary payloads as Msgpax.Bin (e.g. file.read,
  # which is encoded as msgpack `bin`). Unwrap to a plain Elixir binary so callers
  # get a normal string back instead of a struct. Recurse into list/map shapes
  # (e.g. read_chunk's %{"data" => ..., "eof" => ...}).
  defp unwrap(%Msgpax.Bin{data: data}), do: data
  defp unwrap(list) when is_list(list), do: Enum.map(list, &unwrap/1)
  defp unwrap(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, unwrap(v)} end)
  defp unwrap(other), do: other
end
