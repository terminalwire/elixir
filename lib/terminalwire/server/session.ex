defmodule Terminalwire.Server.Session do
  @moduledoc """
  Drives a `Terminalwire.Server.Connection` over a real transport. This is the
  process that sits between the WebSocket endpoint and your CLI code:

    * the endpoint pushes inbound binary frames in via `receive_frame/2`
    * the session decodes, advances the protocol state machine, and pushes
      outbound frames back through the `on_send` function the endpoint provided
    * once the handshake completes, your `handler` runs (in a task) with a
      `Terminalwire.Server.Context` to talk to the client's terminal

  A GenServer so it owns the connection state and serializes frame handling
  (the read-pump role), while the CLI handler runs in a separate task and calls
  back in for synchronous requests (stdin, files) — matching the Ruby runtime's
  pump + waiters model.
  """

  use GenServer
  require Logger

  alias Terminalwire.{Codec, Frames}
  alias Terminalwire.Server.{Connection, Context}

  # --- public API ---

  @doc """
  Start a session.

  Options:
    * `:on_send` (required) — 1-arity fun pushing a binary frame to the client.
    * `:handler` (required) — `fun(Context.t())` run after the handshake; its
      return value becomes the exit status (0 unless it returns an integer).
    * `:server_capabilities`, `:server_min`, `:server_max` — negotiation knobs.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Forward one inbound binary frame from the socket."
  def receive_frame(session, bytes) when is_binary(bytes) do
    GenServer.cast(session, {:frame, bytes})
  end

  @doc "Tell the session the socket closed; it shuts the handler down."
  def close(session), do: GenServer.stop(session, :normal)

  # Called by Context (from the handler task) — synchronous resource request.
  @doc false
  def request(session, resource, method, params, timeout) do
    GenServer.call(session, {:request, resource, method, params}, timeout)
  end

  # Called by Context — fire-and-forget output (flow-controlled internally).
  @doc false
  def emit_output(session, stream, bytes) do
    GenServer.call(session, {:output, stream, bytes}, :infinity)
  end

  @doc false
  def exit(session, status), do: GenServer.cast(session, {:exit, status})

  # --- GenServer ---

  @impl true
  def init(opts) do
    on_send = Keyword.fetch!(opts, :on_send)
    handler = Keyword.fetch!(opts, :handler)

    conn =
      Connection.new(
        server_min: Keyword.get(opts, :server_min),
        server_max: Keyword.get(opts, :server_max),
        server_capabilities: Keyword.get(opts, :server_capabilities)
      )
      |> drop_nil_opts()

    {:ok,
     %{
       conn: conn,
       on_send: on_send,
       handler: handler,
       handler_task: nil,
       # per-request reply destinations: sid => GenServer.from
       waiters: %{},
       # output stream ids by name, opened lazily
       streams: %{},
       # flow windows: sid => remaining credit
       windows: %{}
     }}
  end

  @impl true
  def handle_cast({:frame, bytes}, state) do
    {conn, directives} = Connection.receive_frame(state.conn, Codec.decode(bytes))
    state = %{state | conn: conn}
    {:noreply, Enum.reduce(directives, state, &apply_directive/2)}
  rescue
    e in Terminalwire.ProtocolError ->
      Logger.warning("terminalwire: dropping malformed frame: #{Exception.message(e)}")
      {:noreply, state}
  end

  def handle_cast({:exit, status}, state) do
    send_frame(state, Frames.exit(status))
    {:stop, :normal, state}
  end

  @impl true
  def handle_call({:request, resource, method, params}, from, state) do
    {conn, sid, frame} = Connection.call(state.conn, resource, method, params)
    send_frame(state, frame)
    {:noreply, %{state | conn: conn, waiters: Map.put(state.waiters, sid, from)}}
  end

  def handle_call({:output, stream, bytes}, _from, state) do
    {state, sid} = ensure_stream(state, stream)
    # Chunk to flow credit; here we keep it simple and send whole (window default
    # is large). A future enhancement blocks on credit like the Ruby runtime.
    send_frame(state, Frames.data(sid, bytes))
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({ref, status}, %{handler_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    code = if is_integer(status), do: status, else: 0
    send_frame(state, Frames.exit(code))
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("terminalwire: handler crashed: #{inspect(reason)}")
    send_frame(state, Frames.exit(1))
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- directive application ---

  defp apply_directive({:send, frame}, state) do
    send_frame(state, frame)
    state
  end

  defp apply_directive({:event, :ready, payload}, state) do
    # Handshake done — launch the CLI handler with a Context bound to this session.
    ctx = Context.new(self(), payload)

    task =
      Task.Supervisor.async_nolink(Terminalwire.TaskSupervisor, fn -> state.handler.(ctx) end)

    %{state | handler_task: task}
  end

  defp apply_directive({:event, :response, payload}, state) do
    case Map.pop(state.waiters, payload.sid) do
      {nil, _} ->
        state

      {from, waiters} ->
        reply_response(from, payload)
        %{state | waiters: waiters}
    end
  end

  defp apply_directive({:event, :window_adjust, payload}, state) do
    update_in(state.windows, fn w ->
      Map.update(w, payload.sid, payload.bytes, &(&1 + payload.bytes))
    end)
  end

  defp apply_directive({:event, _other, _payload}, state), do: state

  defp reply_response(from, %{ok: true, value: value}), do: GenServer.reply(from, {:ok, value})

  defp reply_response(from, %{ok: false, error: error}) do
    error = error || %{}

    GenServer.reply(
      from,
      {:error, error["code"] || "internal", error["message"] || "request failed"}
    )
  end

  defp ensure_stream(state, stream) do
    name = to_string(stream)

    case Map.get(state.streams, name) do
      nil ->
        {conn, sid, frame} = Connection.open_stream(state.conn, name)
        send_frame(%{state | conn: conn}, frame)
        {%{state | conn: conn, streams: Map.put(state.streams, name, sid)}, sid}

      sid ->
        {state, sid}
    end
  end

  defp send_frame(state, frame), do: state.on_send.(Codec.encode(frame))

  defp drop_nil_opts(conn) do
    conn
    |> Map.update!(:server_min, &(&1 || Terminalwire.Protocol.min_version()))
    |> Map.update!(:server_max, &(&1 || Terminalwire.Protocol.max_version()))
    |> Map.update!(:server_capabilities, &(&1 || Terminalwire.Protocol.capabilities()))
  end
end
