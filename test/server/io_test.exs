defmodule Terminalwire.Server.IOTest do
  @moduledoc """
  Unit tests for the Erlang I/O-protocol device, driven directly with raw
  `{:io_request, ...}` messages against a fake session — so we cover every
  protocol branch deterministically. The end-to-end "standard IO over a real
  session" path is in SessionTest; the live "real Go client" path is conformance.
  """
  use ExUnit.Case

  alias Terminalwire.Server.IO, as: Device

  # A minimal stand-in for the Session GenServer: answers the two calls the device
  # makes — {:output, ...} (put_chars) and {:request, "stdin", "gets", ...} (reads).
  defmodule FakeSession do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))
    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:output, _stream, bytes}, _from, state) do
      if pid = state[:sink], do: send(pid, {:out, bytes})
      {:reply, :ok, state}
    end

    def handle_call({:request, "stdin", "gets", _params}, _from, state) do
      {:reply, Map.get(state, :gets, {:ok, "line\n"}), state}
    end
  end

  defp device(opts \\ []) do
    {:ok, sess} = FakeSession.start_link(opts)
    {:ok, io} = Device.start_link(sess, 100, 40)
    io
  end

  defp request(io, req) do
    ref = make_ref()
    send(io, {:io_request, self(), ref, req})
    assert_receive {:io_reply, ^ref, reply}, 1000
    reply
  end

  test "put_chars writes to the session's stdout" do
    io = device(sink: self())
    assert :ok == request(io, {:put_chars, :unicode, "hello"})
    assert_receive {:out, "hello"}
  end

  test "put_chars via {M, F, A}" do
    io = device(sink: self())
    assert :ok == request(io, {:put_chars, :unicode, String, :duplicate, ["x", 3]})
    assert_receive {:out, "xxx"}
  end

  test "legacy put_chars forms (no explicit encoding)" do
    io = device(sink: self())
    assert :ok == request(io, {:put_chars, "legacy"})
    assert_receive {:out, "legacy"}
    assert :ok == request(io, {:put_chars, String, :upcase, ["hi"]})
    assert_receive {:out, "HI"}
  end

  test "get_line / get_until / get_chars all return a client line" do
    io = device(gets: {:ok, "Ada\n"})
    assert "Ada\n" == request(io, {:get_line, :unicode, "name? "})
    assert "Ada\n" == request(io, {:get_until, :unicode, "? ", :mod, :fun, []})
    assert "Ada\n" == request(io, {:get_chars, :unicode, "", 10})
  end

  test "get_* unwraps a Msgpax.Bin line" do
    io = device(gets: {:ok, Msgpax.Bin.new("raw\n")})
    assert "raw\n" == request(io, {:get_line, :unicode, ""})
  end

  test "get_* returns :eof when the client errors" do
    io = device(gets: {:error, "io", "closed"})
    assert :eof == request(io, {:get_line, :unicode, ""})
  end

  test "get_geometry reports seeded size and tracks resize" do
    io = device()
    assert 100 == request(io, {:get_geometry, :columns})
    assert 40 == request(io, {:get_geometry, :rows})

    Device.resized(io, 120, 50)
    assert 120 == request(io, {:get_geometry, :columns})
    assert 50 == request(io, {:get_geometry, :rows})

    assert {:error, :enotsup} == request(io, {:get_geometry, :depth})
  end

  test "getopts and setopts" do
    io = device()
    assert Keyword.keyword?(request(io, :getopts))
    assert :ok == request(io, {:setopts, encoding: :unicode})
  end

  test "batched :requests run in order" do
    io = device(sink: self())
    reply = request(io, {:requests, [{:put_chars, :unicode, "a"}, {:put_chars, :unicode, "b"}]})
    assert reply == :ok
    assert_receive {:out, "a"}
    assert_receive {:out, "b"}
  end

  test "an unknown request is rejected" do
    io = device()
    assert {:error, :request} == request(io, {:totally_bogus})
  end
end
