defmodule Terminalwire.Server.SessionTest do
  @moduledoc """
  End-to-end integration of the REAL Session + Context + a CLI handler. A test
  client (this process) plays the client role over the Session's actual seam:
  it receives the server's outbound frames via `on_send`, decodes them with the
  real Codec, and answers requests — exactly as the Go client would. This covers
  the implementation side (Session GenServer, Context API) that protocol tests
  don't reach.
  """
  use ExUnit.Case

  alias Terminalwire.{Codec, Frames}
  alias Terminalwire.Server.{Session, Context}

  # A tiny client simulator: starts a Session whose on_send delivers frames to
  # this process, plays the handshake, and auto-answers stdin/env/file requests
  # from canned data. Returns collected stdout/stderr + exit status.
  defp run(handler, opts \\ []) do
    test = self()

    {:ok, session} =
      Session.start_link(
        handler: handler,
        on_send: fn bytes -> send(test, {:frame, bytes}) end
      )

    # client -> server hello
    Session.receive_frame(session, Codec.encode(hello(opts)))

    loop(session, %{stdout: "", stderr: "", streams: %{}, status: nil, opts: opts})
  end

  defp hello(opts) do
    %{
      "t" => "hello",
      "sid" => 0,
      "protocol" => 2,
      "capabilities" => ["stdio", "file", "env"],
      "program" => %{"name" => "acme", "args" => Keyword.get(opts, :args, [])},
      "entitlement" => %{"authority" => "acme.test"},
      "terminal" => %{
        "stdin" => %{"kind" => "tty"},
        "stdout" => %{"kind" => "tty"},
        "stderr" => %{"kind" => "tty"},
        "device" => %{"cols" => 80, "rows" => 24}
      }
    }
  end

  defp loop(session, state) do
    receive do
      {:frame, bytes} ->
        frame = Codec.decode(bytes)
        state = handle(session, frame, state)

        if frame["t"] == "exit" do
          %{stdout: state.stdout, stderr: state.stderr, status: frame["status"]}
        else
          loop(session, state)
        end
    after
      3000 -> flunk("session timed out; collected: #{inspect(state)}")
    end
  end

  defp handle(_session, %{"t" => "welcome"}, state), do: state

  # The server opened a raw-input stream: enter raw mode and stream one keystroke,
  # like the real client does.
  defp handle(session, %{"t" => "open", "sid" => sid, "stream" => "stdin-raw"}, state) do
    key = Keyword.get(state.opts, :key, "x")
    Session.receive_frame(session, Codec.encode(Frames.data(sid, key)))
    put_in(state, [:streams, sid], "stdin-raw")
  end

  defp handle(_session, %{"t" => "open", "sid" => sid, "stream" => stream}, state) do
    put_in(state, [:streams, sid], stream)
  end

  defp handle(session, %{"t" => "data", "sid" => sid, "bytes" => bytes}, state) do
    data = if is_struct(bytes, Msgpax.Bin), do: bytes.data, else: bytes
    key = if state.streams[sid] == "stderr", do: :stderr, else: :stdout
    # return flow credit, like a real client
    Session.receive_frame(session, Codec.encode(Frames.window_adjust(sid, byte_size(data))))
    Map.update!(state, key, &(&1 <> data))
  end

  defp handle(_session, %{"t" => "close"}, state), do: state

  # Serve the stdin read_chunk pull from opts[:pipe], tracking how much we've fed.
  defp handle(session, %{"t" => "request", "sid" => sid, "resource" => "stdin", "method" => "read_chunk", "params" => p}, state) do
    pipe = Keyword.get(state.opts, :pipe, "")
    pos = Map.get(state, :pipe_pos, 0)
    take = min(p["n"] || 65_536, byte_size(pipe) - pos)
    chunk = binary_part(pipe, pos, take)
    new_pos = pos + take
    resp = %{"data" => Msgpax.Bin.new(chunk), "eof" => new_pos >= byte_size(pipe)}
    Session.receive_frame(session, Codec.encode(Frames.response_ok(sid, resp)))
    Map.put(state, :pipe_pos, new_pos)
  end

  defp handle(session, %{"t" => "request", "sid" => sid, "resource" => res, "method" => meth} = f, state) do
    value =
      case {res, meth} do
        {"stdin", "gets"} -> Keyword.get(state.opts, :stdin, "typed\n")
        {"stdin", "getpass"} -> Keyword.get(state.opts, :password, "secret")
        {"env", "read"} -> Keyword.get(state.opts, :env, %{})[f["params"]["name"]]
        # Real clients return file bytes as msgpack `bin` (Msgpax.Bin) — mimic
        # that so the Context must unwrap it to a plain binary for callers.
        {"file", "read"} ->
          case Keyword.get(state.opts, :files, %{})[f["params"]["path"]] do
            nil -> nil
            body -> Msgpax.Bin.new(body)
          end
        _ -> nil
      end

    Session.receive_frame(session, Codec.encode(Frames.response_ok(sid, value)))
    state
  end

  defp handle(_session, _frame, state), do: state

  # --- tests ---

  test "runs a handler and streams stdout, then exits 0" do
    result = run(fn ctx -> Context.puts(ctx, "hello world"); 0 end)
    assert result.stdout == "hello world\n"
    assert result.status == 0
  end

  test "passes program args to the handler" do
    result =
      run(
        fn ctx ->
          [cmd | _] = Context.args(ctx)
          Context.puts(ctx, "cmd=#{cmd}")
          0
        end,
        args: ["deploy", "--force"]
      )

    assert result.stdout =~ "cmd=deploy"
  end

  test "gets a line from the client over a real request/response" do
    result =
      run(
        fn ctx ->
          name = ctx |> Context.gets("name? ") |> String.trim()
          Context.puts(ctx, "hi #{name}")
          0
        end,
        stdin: "Ada\n"
      )

    assert result.stdout =~ "name? "
    assert result.stdout =~ "hi Ada"
  end

  test "reads a password without echo" do
    result =
      run(
        fn ctx ->
          pw = Context.read_secret(ctx, "pw? ")
          Context.puts(ctx, "len=#{String.length(pw)}")
          0
        end,
        password: "hunter2"
      )

    assert result.stdout =~ "len=7"
  end

  test "reads env and a file through the client" do
    result =
      run(
        fn ctx ->
          Context.puts(ctx, "home=#{Context.env(ctx, "HOME")}")
          Context.puts(ctx, "cfg=#{Context.file_read(ctx, "/etc/acme")}")
          0
        end,
        env: %{"HOME" => "/home/ada"},
        files: %{"/etc/acme" => "config-body"}
      )

    assert result.stdout =~ "home=/home/ada"
    # Regression: file.read comes back as msgpack bin (Msgpax.Bin); Context must
    # unwrap it to a plain binary so string interpolation works (was a crash).
    assert result.stdout =~ "cfg=config-body"
  end

  test "writes to stderr" do
    result = run(fn ctx -> Context.warn(ctx, "oops"); 0 end)
    assert result.stderr == "oops\n"
  end

  # The group-leader redirect: standard IO from the handler (no Context) flows to
  # the client via the Terminalwire.Server.IO device set as the task's group leader.
  test "standard IO.puts streams over the wire" do
    result = run(fn _ctx -> IO.puts("plain IO works"); 0 end)
    assert result.stdout == "plain IO works\n"
    assert result.status == 0
  end

  test "standard IO.gets reads the client's stdin" do
    result =
      run(
        fn _ctx ->
          name = "name? " |> IO.gets() |> String.trim()
          IO.puts("hi #{name}")
          0
        end,
        stdin: "Ada\n"
      )

    assert result.stdout =~ "name? "
    assert result.stdout =~ "hi Ada"
  end

  test ":io.columns reports the client's terminal width through the device" do
    result =
      run(fn _ctx ->
        {:ok, cols} = :io.columns()
        IO.puts("cols=#{cols}")
        0
      end)

    assert result.stdout =~ "cols=80"
  end

  # Flow control: a write larger than the per-frame cap (and the window) is chunked
  # and paced by the client's window_adjust grants, arriving byte-for-byte intact.
  test "large output is chunked and flow-controlled, arriving intact" do
    big = String.duplicate("x", 300_000)
    result = run(fn ctx -> Context.puts(ctx, big); 0 end)
    assert result.stdout == big <> "\n"
    assert result.status == 0
  end

  test "drains piped stdin to EOF, byte-exact" do
    payload = String.duplicate("abc\n", 1000)

    result =
      run(
        fn ctx ->
          data = Context.read(ctx)
          Context.puts(ctx, "len=#{byte_size(data)} head=#{String.slice(data, 0, 3)}")
          0
        end,
        pipe: payload
      )

    assert result.stdout =~ "len=#{byte_size(payload)} head=abc"
  end

  test "read_chunk returns data and an eof flag" do
    result =
      run(
        fn ctx ->
          {a, eof} = Context.read_chunk(ctx, 3)
          Context.puts(ctx, "a=#{a} eof=#{eof}")
          0
        end,
        pipe: "hello"
      )

    assert result.stdout =~ "a=hel eof=false"
  end

  test "read_key reads one keystroke from a raw-input stream" do
    result =
      run(
        fn ctx ->
          key = Context.read_key(ctx)
          Context.puts(ctx, "KEY #{key}")
          0
        end,
        key: "q"
      )

    assert result.stdout =~ "KEY q"
  end

  test "an interrupt signal terminates the handler and exits 130" do
    test = self()

    {:ok, session} =
      Session.start_link(
        handler: fn _ctx -> Process.sleep(:infinity) end,
        on_send: fn b -> send(test, {:frame, b}) end
      )

    Session.receive_frame(session, Codec.encode(hello([])))
    assert_receive {:frame, w}, 1000
    assert Codec.decode(w)["t"] == "welcome"

    # client sends Ctrl-C
    Session.receive_frame(session, Codec.encode(Frames.interrupt()))
    assert_receive {:frame, e}, 1000
    exit_frame = Codec.decode(e)
    assert exit_frame["t"] == "exit"
    assert exit_frame["status"] == 130
  end

  test "non-integer handler return becomes exit 0" do
    result = run(fn ctx -> Context.puts(ctx, "ok"); :done end)
    assert result.status == 0
  end

  test "a crashing handler exits 1 (does not hang)" do
    result = run(fn _ctx -> raise "boom" end)
    assert result.status == 1
  end

  test "Context.file_write round-trips and explicit Context.exit sets the status" do
    result =
      run(fn ctx ->
        Context.file_write(ctx, "/tmp/out", "data")
        Context.exit(ctx, 3)
      end)

    assert result.status == 3
  end

  test "Context.request surfaces a failed response as {:error, code, message}" do
    test = self()

    {:ok, session} =
      Session.start_link(handler: fn ctx -> send(test, {:result, deny_probe(ctx)}); 0 end, on_send: fn b -> send(test, {:frame, b}) end)

    Session.receive_frame(session, Codec.encode(hello([])))

    # Drive: wait for the request, answer with an error, collect the handler's result.
    loop_until_error(session)
  end

  defp deny_probe(ctx) do
    Context.request(ctx, "file", "read", %{"path" => "/etc/shadow"}, 2000)
  end

  defp loop_until_error(session) do
    receive do
      {:frame, bytes} ->
        f = Codec.decode(bytes)

        cond do
          f["t"] == "request" ->
            Session.receive_frame(session, Codec.encode(Frames.response_error(f["sid"], "denied", "nope")))
            loop_until_error(session)

          true ->
            loop_until_error(session)
        end

      {:result, result} ->
        assert {:error, "denied", "nope"} = result
    after
      3000 -> flunk("never saw the handler result")
    end
  end
end
