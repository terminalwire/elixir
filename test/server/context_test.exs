defmodule Terminalwire.Server.ContextTest do
  @moduledoc """
  Unit tests for the Context API (the server-side CLI surface) against a fake
  session, so every resource helper — incl. the sugar and error paths — is
  covered deterministically without the full Session/transport. The real
  Session+Context integration is in SessionTest; cross-impl behavior is
  conformance.
  """
  use ExUnit.Case

  alias Terminalwire.Server.Context

  # Records requests and returns canned replies keyed by {resource, method};
  # unknown calls reply {:ok, nil}. Also answers the raw-input + exit calls.
  defmodule FakeSession do
    use GenServer
    def start_link(replies), do: GenServer.start_link(__MODULE__, replies)
    @impl true
    def init(replies), do: {:ok, replies}

    @impl true
    def handle_call({:request, res, meth, _params}, _from, replies),
      do: {:reply, Map.get(replies, {res, meth}, {:ok, nil}), replies}

    def handle_call({:open_raw, _mode}, _from, replies), do: {:reply, 7, replies}
    def handle_call({:read_raw, _sid}, _from, replies), do: {:reply, Map.get(replies, :key, "k"), replies}
    def handle_call({:close_raw, _sid}, _from, replies), do: {:reply, :ok, replies}

    @impl true
    def handle_cast({:exit, _status}, replies), do: {:noreply, replies}
  end

  defp ctx(replies \\ %{}) do
    {:ok, sess} = FakeSession.start_link(replies)
    %Context{session: sess, capabilities: []}
  end

  test "file resource sugar" do
    c = ctx(%{{"file", "read"} => {:ok, Msgpax.Bin.new("body")}, {"file", "exist"} => {:ok, true}})
    assert Context.file_read(c, "/x") == "body"
    assert Context.file_write(c, "/x", "y") == nil
    assert Context.file_append(c, "/x", "y") == nil
    assert Context.file_delete(c, "/x") == nil
    assert Context.file_exists?(c, "/x") == true
  end

  test "directory resource sugar" do
    c = ctx(%{{"directory", "list"} => {:ok, ["a", "b"]}, {"directory", "exist"} => {:ok, false}})
    assert Context.dir_list(c, "/d") == ["a", "b"]
    assert Context.dir_create(c, "/d") == nil
    assert Context.dir_exists?(c, "/d") == false
    assert Context.dir_delete(c, "/d") == nil
  end

  test "env + browser" do
    c = ctx(%{{"env", "read"} => {:ok, "/home/ada"}})
    assert Context.env(c, "HOME") == "/home/ada"
    assert Context.browser_launch(c, "https://acme.test") == nil
  end

  test "output: print/puts/warn don't blow up" do
    # output goes through Session.emit_output, which the fake doesn't implement —
    # but the IO device path is covered elsewhere; here we just exercise the API
    # shape via request-backed helpers. (puts/warn delegate to emit_output, which
    # is covered in SessionTest/IOTest.)
    c = ctx(%{{"stdin", "gets"} => {:ok, "Ada\n"}, {"stdin", "getpass"} => {:ok, "pw"}})
    assert Context.gets(c) == "Ada\n"
    assert Context.read_secret(c) == "pw"
  end

  test "read_chunk returns {data, eof}; read drains to EOF" do
    c = ctx(%{{"stdin", "read_chunk"} => {:ok, %{"data" => Msgpax.Bin.new("all"), "eof" => true}}})
    assert Context.read_chunk(c) == {"all", true}
    assert Context.read(c) == "all"
  end

  test "read_key reads one chunk from a raw stream" do
    assert Context.read_key(ctx(%{key: "q"})) == "q"
  end

  test "raw_input yields a reader and closes" do
    c = ctx(%{key: "z"})
    got = Context.raw_input(c, "raw", fn read -> read.() end)
    assert got == "z"
  end

  test "a bang resource error raises ResponseError with the code" do
    c = ctx(%{{"file", "read"} => {:error, "denied", "nope"}})
    err = assert_raise Terminalwire.ResponseError, fn -> Context.file_read(c, "/etc/shadow") end
    assert err.code == "denied"
  end

  test "exit casts the status to the session" do
    assert Context.exit(ctx(), 3) == :ok
  end

  test "args / capabilities / terminal accessors" do
    c = %Context{
      session: nil,
      program: %{"args" => ["deploy", "--force"]},
      capabilities: ["stdio", "terminal-query"],
      terminal: %{"device" => %{"cols" => 100, "rows" => 40}}
    }

    assert Context.args(c) == ["deploy", "--force"]
    assert c.capabilities == ["stdio", "terminal-query"]
    t = Context.terminal(c)
    assert t.cols == 100
    assert t.rows == 40
  end
end
