defmodule Terminalwire.Server.ConnectionTest do
  @moduledoc """
  Integration of the sans-IO server state machine — the implementation side, not
  just the codec. Mirrors the Ruby `connection_spec`: handshake, request/response
  correlation, signals, and the malformed-frame guards. No transport needed.
  """
  use ExUnit.Case

  alias Terminalwire.Server.Connection
  alias Terminalwire.{Frames, ProtocolError}

  defp hello(opts \\ []) do
    %{
      "t" => "hello",
      "sid" => 0,
      "protocol" => Keyword.get(opts, :protocol, 2),
      "capabilities" => Keyword.get(opts, :capabilities, ["stdio", "file"]),
      "program" => %{"name" => "acme", "args" => ["deploy"]},
      "entitlement" => %{"authority" => "acme.test"}
    }
  end

  describe "handshake" do
    test "welcomes a compatible client and becomes ready" do
      {conn, directives} = Connection.receive_frame(Connection.new(), hello())

      assert Connection.ready?(conn)
      assert {:send, %{"t" => "welcome", "protocol" => 2}} = List.keyfind(directives, :send, 0)
      assert {:event, :ready, payload} = List.keyfind(directives, :event, 0)
      assert payload.program == %{"name" => "acme", "args" => ["deploy"]}
    end

    test "rejects an incompatible (too-old) client without becoming ready" do
      {conn, directives} = Connection.receive_frame(Connection.new(), hello(protocol: 1))

      refute Connection.ready?(conn)
      assert {:send, %{"t" => "incompatible", "supported" => %{"min" => 2, "max" => 2}}} =
               List.keyfind(directives, :send, 0)
    end

    test "raises if the first frame is not a hello" do
      assert_raise ProtocolError, ~r/expected hello/, fn ->
        Connection.receive_frame(Connection.new(), Frames.exit(0))
      end
    end

    test "rejects a hello with non-integer protocol / non-list capabilities" do
      assert_raise ProtocolError, ~r/protocol must be an integer/, fn ->
        Connection.receive_frame(Connection.new(), %{hello() | "protocol" => "2"})
      end

      assert_raise ProtocolError, ~r/capabilities must be an array/, fn ->
        Connection.receive_frame(Connection.new(), %{hello() | "capabilities" => "stdio"})
      end
    end
  end

  describe "after handshake" do
    setup do
      {conn, _} = Connection.receive_frame(Connection.new(), hello())
      %{conn: conn}
    end

    test "correlates a request to its response (and carries context)", %{conn: conn} do
      {conn, sid, req} = Connection.call(conn, "stdin", "gets")
      assert req["t"] == "request"

      {_conn, directives} =
        Connection.receive_frame(conn, Frames.response_ok(sid, "yes\n"))

      assert [{:event, :response, payload}] = directives
      assert payload.sid == sid
      assert payload.ok == true
      assert payload.value == "yes\n"
      assert payload.context == %{resource: "stdin", method: "gets"}
    end

    test "surfaces a failed response without leaving ready state", %{conn: conn} do
      {conn, sid, _} = Connection.call(conn, "file", "read", %{"path" => "/etc/passwd"})
      {conn, directives} = Connection.receive_frame(conn, Frames.response_error(sid, "denied", "no"))

      assert [{:event, :response, %{ok: false, error: %{"code" => "denied"}}}] = directives
      assert Connection.ready?(conn)
    end

    test "ignores a response for an unknown stream (no crash)", %{conn: conn} do
      {conn, directives} = Connection.receive_frame(conn, Frames.response_ok(9999, "stray"))
      assert directives == []
      assert Connection.ready?(conn)
    end

    test "surfaces resize and interrupt signals", %{conn: conn} do
      {_, dirs} = Connection.receive_frame(conn, Frames.resize(120, 40))
      assert [{:event, :resize, %{cols: 120, rows: 40}}] = dirs

      {_, dirs} = Connection.receive_frame(conn, Frames.interrupt())
      assert [{:event, :interrupt, %{}}] = dirs
    end

    test "ignores an unknown signal name (forward compatibility)", %{conn: conn} do
      {_, dirs} = Connection.receive_frame(conn, Frames.signal("future-signal"))
      assert dirs == []
    end

    test "surfaces inbound data as :input and window_adjust", %{conn: conn} do
      # Inbound frames reach the Connection already decoded (bin -> plain binary),
      # so feed a decoded data frame rather than the Msgpax.Bin-wrapped builder.
      inbound_data = %{"t" => "data", "sid" => 7, "bytes" => "k"}
      {_, dirs} = Connection.receive_frame(conn, inbound_data)
      assert [{:event, :input, %{sid: 7, bytes: "k"}}] = dirs

      {_, dirs} = Connection.receive_frame(conn, Frames.window_adjust(7, 4096))
      assert [{:event, :window_adjust, %{sid: 7, bytes: 4096}}] = dirs
    end

    test "raises on an unexpected frame type while ready", %{conn: conn} do
      assert_raise ProtocolError, ~r/unexpected .* while ready/, fn ->
        Connection.receive_frame(conn, hello())
      end
    end

    test "allocates monotonically increasing stream ids", %{conn: conn} do
      {conn, sid1, _} = Connection.open_stream(conn, "stdout")
      {_conn, sid2, _} = Connection.open_stream(conn, "stderr")
      assert sid2 > sid1
    end
  end

  test "refuses work before the handshake" do
    assert_raise ProtocolError, ~r/not ready/, fn ->
      Connection.open_stream(Connection.new(), "stdout")
    end
  end
end
