defmodule Terminalwire.ProtocolTest do
  use ExUnit.Case, async: true

  alias Terminalwire.Protocol

  # These values are part of the cross-language wire contract (Ruby, Go, Elixir all
  # agree). Pinning them here guards against an accidental change that would silently
  # break interop; a deliberate change must move in lockstep with the corpus.
  describe "version constants" do
    test "speaks protocol version 2, with min == max == 2" do
      assert Protocol.version() == 2
      assert Protocol.min_version() == 2
      assert Protocol.max_version() == 2
    end

    test "the control stream id is 0" do
      assert Protocol.control_sid() == 0
    end
  end

  describe "flow-control windows" do
    test "default per-stream window is 256 KiB" do
      assert Protocol.default_window() == 256 * 1024
    end

    test "max window ceiling is 16 MiB and is 64x the default offer" do
      assert Protocol.max_window() == 16 * 1024 * 1024
      assert Protocol.max_window() == Protocol.default_window() * 64
    end
  end

  describe "capabilities" do
    test "advertises the full v2 capability set" do
      assert Protocol.capabilities() == ~w(
               stdio file directory browser env signal flow raw-input terminal-query
             )
    end
  end

  describe "frame type tokens" do
    test "covers all eleven frame types with their wire spelling" do
      alias Protocol.Type

      assert {Type.hello(), Type.welcome(), Type.incompatible()} ==
               {"hello", "welcome", "incompatible"}

      assert {Type.exit(), Type.open(), Type.data(), Type.close()} ==
               {"exit", "open", "data", "close"}

      assert {Type.request(), Type.response(), Type.signal(), Type.window_adjust()} ==
               {"request", "response", "signal", "window_adjust"}
    end
  end

  describe "signal names" do
    test "carries resize and interrupt" do
      assert Protocol.Signal.resize() == "resize"
      assert Protocol.Signal.interrupt() == "interrupt"
    end
  end

  describe "error codes" do
    test "covers every error code carried on a failed response" do
      alias Protocol.ErrorCode

      assert ErrorCode.denied() == "denied"
      assert ErrorCode.not_found() == "not_found"
      assert ErrorCode.io() == "io"
      assert ErrorCode.protocol() == "protocol"
      assert ErrorCode.internal() == "internal"
    end
  end
end
