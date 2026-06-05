defmodule Terminalwire.Server.IO do
  @moduledoc """
  An Erlang I/O-protocol device backed by a Terminalwire session. Set as the CLI
  handler's group leader (see `Terminalwire.Server.Session`), it routes the
  *standard* IO — `IO.puts`/`IO.gets`/`IO.write`, `IO.ANSI`, `:io.columns`, and
  any library built on them (e.g. Owl) — over the wire to the client's terminal,
  with no `Context` threading. This mirrors the Ruby server's `Server.redirect`,
  which points `$stdout`/`$stdin` at the client.

    * put_chars → the client's stdout stream (flow-controlled by the session)
    * get_line/get_until/get_chars → a line from the client's stdin
    * get_geometry → the client's live terminal size (kept current on resize)

  stderr is NOT routed here — in Erlang it's a separate named device, not the
  group leader. Use `Context.warn/2` for stderr.
  """
  use GenServer

  alias Terminalwire.Server.Session

  @doc "Start a device bound to `session`, seeded with the client's terminal size."
  def start_link(session, cols, rows) do
    GenServer.start_link(__MODULE__, %{session: session, cols: cols, rows: rows})
  end

  @doc "Push the client's new terminal size after a resize (keeps :io.columns live)."
  def resized(io, cols, rows), do: send(io, {:tw_resized, cols, rows})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:tw_resized, cols, rows}, state),
    do: {:noreply, %{state | cols: cols, rows: rows}}

  def handle_info({:io_request, from, reply_as, request}, state) do
    {reply, state} = io_request(request, state)
    send(from, {:io_reply, reply_as, reply})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Erlang I/O protocol ---

  defp io_request({:put_chars, _enc, chars}, state), do: {put(state, chars), state}

  defp io_request({:put_chars, _enc, mod, fun, args}, state),
    do: {put(state, apply(mod, fun, args)), state}

  # Legacy (no explicit encoding) forms.
  defp io_request({:put_chars, chars}, state), do: io_request({:put_chars, :latin1, chars}, state)

  defp io_request({:put_chars, mod, fun, args}, state),
    do: io_request({:put_chars, :latin1, mod, fun, args}, state)

  defp io_request({:get_line, _enc, prompt}, state), do: {get_line(state, prompt), state}
  defp io_request({:get_until, _enc, prompt, _m, _f, _a}, state), do: {get_line(state, prompt), state}
  defp io_request({:get_chars, _enc, prompt, _n}, state), do: {get_line(state, prompt), state}

  defp io_request({:get_geometry, :columns}, state), do: {state.cols, state}
  defp io_request({:get_geometry, :rows}, state), do: {state.rows, state}
  defp io_request({:get_geometry, _}, state), do: {{:error, :enotsup}, state}

  defp io_request({:setopts, _opts}, state), do: {:ok, state}
  defp io_request(:getopts, state), do: {[binary: true, encoding: :unicode], state}

  # Batched requests: run in order, stop at the first error, reply with the last.
  defp io_request({:requests, reqs}, state), do: run_requests(reqs, state, :ok)

  defp io_request(_other, state), do: {{:error, :request}, state}

  defp run_requests([req | rest], state, _last) do
    case io_request(req, state) do
      {{:error, _} = err, state} -> {err, state}
      {reply, state} -> run_requests(rest, state, reply)
    end
  end

  defp run_requests([], state, last), do: {last, state}

  # Output to the client's stdout, flow-controlled by the session (blocks here
  # until there's credit — exactly the backpressure IO.puts callers expect).
  defp put(state, chars) do
    Session.emit_output(state.session, :stdout, IO.chardata_to_string(chars))
  rescue
    _ -> {:error, :put_chars}
  end

  # The io protocol replies to get_* with the data ITSELF (or :eof / {:error, _}),
  # NOT wrapped in {:ok, _} — that's the put_chars/geometry convention, not this.
  defp get_line(state, prompt) do
    if prompt?(prompt), do: put(state, prompt)

    case Session.request(state.session, "stdin", "gets", %{}, :infinity) do
      {:ok, value} -> normalize(value)
      {:error, _code, _message} -> :eof
    end
  rescue
    _ -> {:error, :get_line}
  end

  defp prompt?(p), do: p not in [nil, ~c"", "", :default]

  defp normalize(%Msgpax.Bin{data: data}), do: data
  defp normalize(value) when is_binary(value), do: value
  defp normalize(nil), do: ""
  defp normalize(other), do: to_string(other)
end
