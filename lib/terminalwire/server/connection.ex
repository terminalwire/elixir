defmodule Terminalwire.Server.Connection do
  @moduledoc """
  The server-role protocol state machine. Sans-IO: feed it an incoming frame with
  `receive_frame/2`, get back `{new_state, directives}`. A directive is one of:

    * `{:send, frame}`            — write this frame to the transport
    * {:event, name, payload}`    — a domain event for the application

  No sockets, no processes. Mirrors `Terminalwire2::Server::Connection`. The
  stateful I/O lives in `Terminalwire.Server.Session`.
  """

  alias Terminalwire.{Negotiator, Frames, Protocol, ProtocolError}
  alias Terminalwire.Protocol.{Type, Signal}

  defstruct state: :awaiting_hello,
            protocol: nil,
            capabilities: [],
            server_min: nil,
            server_max: nil,
            server_capabilities: nil,
            next_sid: 1,
            pending: %{}

  def new(opts \\ []) do
    %__MODULE__{
      server_min: Keyword.get(opts, :server_min, Protocol.min_version()),
      server_max: Keyword.get(opts, :server_max, Protocol.max_version()),
      server_capabilities: Keyword.get(opts, :server_capabilities, Protocol.capabilities())
    }
  end

  def ready?(%__MODULE__{state: :ready}), do: true
  def ready?(_), do: false

  @doc "Feed one incoming frame. Returns {conn, directives}."
  def receive_frame(%__MODULE__{state: :awaiting_hello} = conn, frame), do: on_hello(conn, frame)
  def receive_frame(%__MODULE__{state: :ready} = conn, frame), do: on_ready(conn, frame)

  def receive_frame(%__MODULE__{state: s}, frame) do
    raise ProtocolError, message: "received #{inspect(frame["t"])} while #{s}"
  end

  # --- application-driven outgoing helpers (return {conn, sid, frame}) ---

  def open_stream(%__MODULE__{} = conn, stream, mode \\ nil) do
    require_ready!(conn)
    {sid, conn} = allocate(conn)
    {conn, sid, Frames.open(sid, to_string(stream), mode)}
  end

  def call(%__MODULE__{} = conn, resource, method, params \\ %{}) do
    require_ready!(conn)
    {sid, conn} = allocate(conn)
    conn = %{conn | pending: Map.put(conn.pending, sid, %{resource: resource, method: method})}
    {conn, sid, Frames.request(sid, to_string(resource), to_string(method), params)}
  end

  def exit(%__MODULE__{} = conn, status \\ 0) do
    {%{conn | state: :closed}, Frames.exit(status)}
  end

  # --- internals ---

  defp on_hello(conn, frame) do
    unless frame["t"] == Type.hello() do
      raise ProtocolError, message: "expected hello, got #{inspect(frame["t"])}"
    end

    protocol = frame["protocol"]
    capabilities = frame["capabilities"]

    unless is_integer(protocol),
      do: raise(ProtocolError, message: "hello protocol must be an integer")

    unless is_list(capabilities),
      do: raise(ProtocolError, message: "hello capabilities must be an array")

    case Negotiator.negotiate(
           protocol,
           capabilities,
           conn.server_min,
           conn.server_max,
           conn.server_capabilities
         ) do
      {:welcome, agreed, caps} ->
        conn = %{conn | state: :ready, protocol: agreed, capabilities: caps}

        directives = [
          {:send, Frames.welcome(agreed, caps)},
          {:event, :ready,
           %{
             protocol: agreed,
             capabilities: caps,
             program: frame["program"],
             entitlement: frame["entitlement"],
             terminal: frame["terminal"],
             flow: frame["flow"]
           }}
        ]

        {conn, directives}

      {:incompatible, min, max} ->
        msg = "client speaks #{protocol}; server supports #{min}..#{max}"

        {%{conn | state: :closed},
         [
           {:send, Frames.incompatible(min, max, msg)},
           {:event, :incompatible, %{min: min, max: max}}
         ]}
    end
  end

  # Single uniform dispatch over inbound frame type (mirrors the Go client switch).
  defp on_ready(conn, frame) do
    cond do
      frame["t"] == Type.signal() ->
        on_signal(conn, frame)

      frame["t"] == Type.window_adjust() ->
        {conn, [{:event, :window_adjust, %{sid: frame["sid"], bytes: frame["bytes"]}}]}

      frame["t"] == Type.data() ->
        {conn, [{:event, :input, %{sid: frame["sid"], bytes: frame["bytes"]}}]}

      frame["t"] == Type.response() ->
        on_response(conn, frame)

      true ->
        raise ProtocolError, message: "unexpected #{inspect(frame["t"])} while ready"
    end
  end

  defp on_signal(conn, frame) do
    cond do
      frame["name"] == Signal.resize() ->
        {conn, [{:event, :resize, %{cols: frame["cols"], rows: frame["rows"]}}]}

      frame["name"] == Signal.interrupt() ->
        {conn, [{:event, :interrupt, %{}}]}

      true ->
        {conn, []}
    end
  end

  defp on_response(conn, frame) do
    sid = frame["sid"]

    case Map.pop(conn.pending, sid) do
      {nil, _} ->
        # Unknown/duplicate/late/hostile response — ignore, don't crash.
        {conn, []}

      {context, pending} ->
        payload = %{
          sid: sid,
          ok: frame["ok"],
          value: frame["value"],
          error: frame["error"],
          context: context
        }

        {%{conn | pending: pending}, [{:event, :response, payload}]}
    end
  end

  defp allocate(%__MODULE__{next_sid: sid} = conn), do: {sid, %{conn | next_sid: sid + 1}}

  defp require_ready!(%__MODULE__{state: :ready}), do: :ok

  defp require_ready!(%__MODULE__{state: s}),
    do: raise(ProtocolError, message: "connection not ready (state: #{s})")
end
