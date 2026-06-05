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

  Output is **flow-controlled** (the SSH/HTTP-2 window model): each output stream
  has credit; `emit_output/3` chunks to `@max_frame` and blocks the writer until
  credit exists, topped up by `window_adjust` frames. Blocking is done by deferring
  the GenServer reply (we stash `from` and reply once the bytes are sent), so the
  session itself never blocks and keeps processing inbound frames.

  The handler also gets a `Terminalwire.Server.IO` device set as its group leader,
  so standard `IO.*` and libraries like Owl flow over the wire (see that module).
  """

  use GenServer
  require Logger

  alias Terminalwire.{Codec, Frames, Protocol}
  alias Terminalwire.Server.{Connection, Context, Terminal}

  # Largest payload in a single data frame; the actual size is min(this, credit).
  @max_frame 32 * 1024

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

  # Called by Context / the IO device — flow-controlled output. Blocks (via a
  # deferred reply) until the bytes have been sent within the client's window.
  @doc false
  def emit_output(session, stream, bytes) do
    GenServer.call(session, {:output, stream, bytes}, :infinity)
  end

  @doc false
  def exit(session, status), do: GenServer.cast(session, {:exit, status})

  # Raw input (REPL/TUI): open a stdin-raw stream in `mode` (raw/cbreak); the
  # client streams keystrokes as data frames until we close it.
  @doc false
  def open_raw_input(session, mode), do: GenServer.call(session, {:open_raw, mode})

  @doc false
  def read_raw(session, sid), do: GenServer.call(session, {:read_raw, sid}, :infinity)

  @doc false
  def close_raw_input(session, sid), do: GenServer.call(session, {:close_raw, sid})

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
       # flow windows: sid => remaining credit (bytes)
       windows: %{},
       # output awaiting credit: sid => :queue of {from, bytes}
       pending: %{},
       # the client's advertised initial window (per stream)
       client_window: Protocol.default_window(),
       # the IO device set as the handler's group leader
       io: nil,
       # raw input streams: sid => %{q: :queue of chunks, waiter: from|nil, closed: bool}
       raw: %{}
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

  def handle_call({:output, stream, bytes}, from, state) do
    {state, sid} = ensure_stream(state, stream)
    bytes = IO.iodata_to_binary(bytes)

    if bytes == "" do
      # A zero-length write is a flush, not flow-controlled — send it and return.
      send_frame(state, Frames.data(sid, ""))
      {:reply, :ok, state}
    else
      queue = :queue.in({from, bytes}, Map.get(state.pending, sid, :queue.new()))
      # Don't reply now — drain replies to `from` once its bytes are fully sent.
      {:noreply, drain(%{state | pending: Map.put(state.pending, sid, queue)}, sid)}
    end
  end

  # Raw input: open a stdin-raw stream the client streams keystrokes on.
  def handle_call({:open_raw, mode}, _from, state) do
    {conn, sid, frame} = Connection.open_stream(state.conn, "stdin-raw", mode)
    state = %{state | conn: conn}
    send_frame(state, frame)
    raw = Map.put(state.raw, sid, %{q: :queue.new(), waiter: nil, closed: false})
    {:reply, sid, %{state | raw: raw}}
  end

  # Read the next keystroke chunk; blocks (deferred reply) until one arrives, or
  # returns nil once the stream is closed / unknown.
  def handle_call({:read_raw, sid}, from, state) do
    case Map.get(state.raw, sid) do
      nil ->
        {:reply, nil, state}

      %{q: q} = rs ->
        case :queue.out(q) do
          {{:value, chunk}, rest} ->
            {:reply, chunk, %{state | raw: Map.put(state.raw, sid, %{rs | q: rest})}}

          {:empty, _} ->
            if rs.closed,
              do: {:reply, nil, state},
              else: {:noreply, %{state | raw: Map.put(state.raw, sid, %{rs | waiter: from})}}
        end
    end
  end

  def handle_call({:close_raw, sid}, _from, state) do
    case Map.get(state.raw, sid) do
      nil ->
        {:reply, :ok, state}

      rs ->
        send_frame(state, Frames.close(sid))
        if rs.waiter, do: GenServer.reply(rs.waiter, nil)
        {:reply, :ok, %{state | raw: Map.delete(state.raw, sid)}}
    end
  end

  @impl true
  def handle_info({ref, status}, %{handler_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    code = if is_integer(status), do: status, else: 0
    send_frame(state, Frames.exit(code))
    {:stop, :normal, state}
  end

  # The handler was interrupted (Ctrl-C from the client) — exit 130, like a local
  # SIGINT, instead of treating it as a crash.
  def handle_info({:DOWN, _ref, :process, _pid, :tw_interrupt}, state) do
    send_frame(state, Frames.exit(130))
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("terminalwire: handler crashed: #{inspect(reason)}")
    send_frame(state, Frames.exit(1))
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The session is going away (socket closed, handler done/crashed). Unblock
  # everyone parked on a deferred reply so they get a clean answer instead of
  # crashing on the dead GenServer — mirrors the Ruby runtime's shutdown (fail
  # in-flight requests, ack pending output, return nil to raw readers). In the
  # normal-completion path these are all empty, so this only does work on an
  # abrupt disconnect.
  @impl true
  def terminate(_reason, state) do
    # Was the handler parked on a deferred reply when we went down? If so, the
    # replies below wake it and it unwinds cleanly on its own — we must NOT kill it
    # (a brutal_kill would race the unwind and lose the handler's result).
    parked? =
      map_size(state.waiters) > 0 or map_size(state.pending) > 0 or
        Enum.any?(state.raw, fn {_sid, rs} -> rs.waiter end)

    Enum.each(state.waiters, fn {_sid, from} ->
      GenServer.reply(from, {:error, "io", "connection closed"})
    end)

    Enum.each(state.pending, fn {_sid, queue} ->
      Enum.each(:queue.to_list(queue), fn {from, _bytes} -> GenServer.reply(from, :ok) end)
    end)

    Enum.each(state.raw, fn {_sid, rs} -> rs.waiter && GenServer.reply(rs.waiter, nil) end)

    # Kill the handler ONLY if it was not parked. async_nolink monitors but does not
    # link, so a handler parked in pure compute / Process.sleep / a receive with no
    # IO (nothing for the replies above to wake) would otherwise outlive the session
    # as an orphan under the global TaskSupervisor. A parked handler unwinds via the
    # replies; an already-finished one makes shutdown a no-op.
    if state.handler_task && not parked?,
      do: Task.shutdown(state.handler_task, :brutal_kill)

    :ok
  end

  # --- directive application ---

  defp apply_directive({:send, frame}, state) do
    send_frame(state, frame)
    state
  end

  defp apply_directive({:event, :ready, payload}, state) do
    # Handshake done. Seed the IO device with the client's terminal size, set it
    # as the handler's group leader (so standard IO + Owl route over the wire),
    # and launch the CLI handler with a Context bound to this session.
    client_window = get_in(payload, [:flow, "window"]) || Protocol.default_window()
    t = Terminal.from_map(payload[:terminal])
    {:ok, io} = Terminalwire.Server.IO.start_link(self(), t.cols, t.rows)
    ctx = Context.new(self(), payload)

    task =
      Task.Supervisor.async_nolink(Terminalwire.TaskSupervisor, fn ->
        Process.group_leader(self(), io)
        state.handler.(ctx)
      end)

    %{state | handler_task: task, io: io, client_window: client_window}
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
    # Only credit a stream we actually opened, with a valid grant — ignore unknown
    # sids and malformed (non-integer / negative) bytes (mirrors the Ruby flow
    # controller). Otherwise Map.update would seed a phantom window for an unknown
    # sid, a negative grant would stall the stream, and a non-integer would crash
    # the cast handler (it's outside the ProtocolError-only rescue).
    if Map.has_key?(state.windows, payload.sid) and is_integer(payload.bytes) and payload.bytes >= 0 do
      drain(update_in(state.windows[payload.sid], &(&1 + payload.bytes)), payload.sid)
    else
      state
    end
  end

  defp apply_directive({:event, :resize, payload}, state) do
    # Keep the IO device's geometry live so :io.columns / Owl.IO.columns reflect
    # the client's current size mid-session.
    if state.io, do: Terminalwire.Server.IO.resized(state.io, payload.cols, payload.rows)
    state
  end

  # A keystroke chunk on a raw-input stream: hand it to a blocked reader, or
  # buffer it until one calls read_raw. Drop chunks for unknown/closed streams.
  defp apply_directive({:event, :input, payload}, state) do
    bytes = unwrap_bin(payload.bytes)

    case Map.get(state.raw, payload.sid) do
      nil ->
        state

      %{waiter: nil, q: q} = rs ->
        %{state | raw: Map.put(state.raw, payload.sid, %{rs | q: :queue.in(bytes, q)})}

      %{waiter: from} = rs ->
        GenServer.reply(from, bytes)
        %{state | raw: Map.put(state.raw, payload.sid, %{rs | waiter: nil})}
    end
  end

  # Ctrl-C: interrupt the handler so the session exits 130 (a local SIGINT).
  defp apply_directive({:event, :interrupt, _payload}, state) do
    if state.handler_task, do: Process.exit(state.handler_task.pid, :tw_interrupt)
    state
  end

  defp apply_directive({:event, _other, _payload}, state), do: state

  defp unwrap_bin(%Msgpax.Bin{data: data}), do: data
  defp unwrap_bin(bytes) when is_binary(bytes), do: bytes
  # A data frame's `bytes` must be binary. A non-binary payload (map/int/list from
  # a malformed or hostile client) used to hit `to_string/1`, which RAISES on a map
  # (Protocol.UndefinedError) — and that is NOT a ProtocolError, so it escaped the
  # handle_cast rescue and crashed the whole session. Raise ProtocolError instead so
  # the malformed frame is dropped like any other (see handle_cast).
  defp unwrap_bin(_other),
    do: raise(Terminalwire.ProtocolError, message: "data 'bytes' must be binary")

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
        state = %{state | conn: conn}
        send_frame(state, frame)

        state = %{
          state
          | streams: Map.put(state.streams, name, sid),
            windows: Map.put(state.windows, sid, state.client_window)
        }

        {state, sid}

      sid ->
        {state, sid}
    end
  end

  # Send as much queued output for `sid` as current credit allows, chunked to
  # @max_frame, replying :ok to each writer once all its bytes are out. Runs
  # inside the GenServer and never blocks: a write that outruns the window stays
  # queued (its `from` un-replied) until window_adjust frames top the credit up.
  defp drain(state, sid) do
    credit = Map.get(state.windows, sid, 0)
    queue = Map.get(state.pending, sid, :queue.new())
    {credit, queue} = do_drain(state, sid, credit, queue)

    %{
      state
      | windows: Map.put(state.windows, sid, credit),
        pending: Map.put(state.pending, sid, queue)
    }
  end

  defp do_drain(state, sid, credit, queue) when credit > 0 do
    case :queue.out(queue) do
      {{:value, {from, bytes}}, rest} ->
        take = min(min(byte_size(bytes), @max_frame), credit)
        <<chunk::binary-size(take), remaining::binary>> = bytes
        send_frame(state, Frames.data(sid, chunk))

        if remaining == "" do
          GenServer.reply(from, :ok)
          do_drain(state, sid, credit - take, rest)
        else
          do_drain(state, sid, credit - take, :queue.in_r({from, remaining}, rest))
        end

      {:empty, queue} ->
        {credit, queue}
    end
  end

  defp do_drain(_state, _sid, credit, queue), do: {credit, queue}

  defp send_frame(state, frame), do: state.on_send.(Codec.encode(frame))

  defp drop_nil_opts(conn) do
    conn
    |> Map.update!(:server_min, &(&1 || Terminalwire.Protocol.min_version()))
    |> Map.update!(:server_max, &(&1 || Terminalwire.Protocol.max_version()))
    |> Map.update!(:server_capabilities, &(&1 || Terminalwire.Protocol.capabilities()))
  end
end
