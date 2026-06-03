defmodule Terminalwire.WebSockTest do
  @moduledoc """
  Covers the WebSock adapter callbacks directly (no real socket needed): init
  starts a session, handle_in forwards binary frames, handle_info pushes outbound
  frames as binary, text frames are ignored, terminate closes the session.
  """
  use ExUnit.Case

  alias Terminalwire.{Codec, Frames}
  alias Terminalwire.WebSock, as: WS

  test "init starts a session and handshake produces an outbound welcome" do
    {:ok, state} = WS.init(handler: fn _ctx -> 0 end)
    assert is_pid(state.session)

    # Feed a hello as a binary frame; the session should push a welcome back to us.
    {:ok, ^state} = WS.handle_in({Codec.encode(hello()), [opcode: :binary]}, state)

    assert_receive {:tw_push, bytes}, 1000
    assert Codec.decode(bytes)["t"] == "welcome"
  end

  test "handle_info pushes a queued outbound frame as a binary ws frame" do
    {:ok, state} = WS.init(handler: fn _ctx -> 0 end)
    assert {:push, {:binary, "abc"}, ^state} = WS.handle_info({:tw_push, "abc"}, state)
  end

  test "text frames are ignored" do
    {:ok, state} = WS.init(handler: fn _ctx -> 0 end)
    assert {:ok, ^state} = WS.handle_in({"ignored", [opcode: :text]}, state)
  end

  test "unknown info messages are ignored" do
    {:ok, state} = WS.init(handler: fn _ctx -> 0 end)
    assert {:ok, ^state} = WS.handle_info(:whatever, state)
  end

  test "terminate closes the session" do
    {:ok, state} = WS.init(handler: fn _ctx -> 0 end)
    assert :ok = WS.terminate(:normal, state)
    refute Process.alive?(state.session)
  end

  test "missing handler raises (KeyError) at init" do
    assert_raise KeyError, fn -> WS.init([]) end
  end

  defp hello do
    %{
      "t" => "hello",
      "sid" => 0,
      "protocol" => 2,
      "capabilities" => ["stdio"],
      "program" => %{"name" => "acme", "args" => []},
      "entitlement" => %{"authority" => "acme.test"}
    }
  end
end
