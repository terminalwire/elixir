defmodule Terminalwire.CodecTest do
  use ExUnit.Case, async: true

  alias Terminalwire.{Codec, Frames, ProtocolError}

  describe "encode/1" do
    test "encodes a frame map to a MessagePack binary" do
      bytes = Codec.encode(%{"t" => "hello", "sid" => 0})
      assert is_binary(bytes)
    end

    test "raises for a non-map frame" do
      assert_raise ProtocolError, ~r/frame must be a map/, fn -> Codec.encode([1, 2, 3]) end
      assert_raise ProtocolError, ~r/frame must be a map/, fn -> Codec.encode("nope") end
    end
  end

  describe "round-trip" do
    test "encode then decode returns an equivalent frame (string keys)" do
      frame = %{"t" => "request", "sid" => 7, "resource" => "file", "method" => "read"}
      assert frame |> Codec.encode() |> Codec.decode() == frame
    end

    test "binary payloads decode as Msgpax.Bin so a re-encode keeps them MessagePack bin" do
      raw = <<0, 255, 1, 2, 254>>
      decoded = Frames.data(3, raw) |> Codec.encode() |> Codec.decode()
      # Decoding keeps `bin` wrapped in Msgpax.Bin (binary: true) so re-encoding a
      # decoded frame preserves the bin type instead of degrading to str. Consumers
      # (the Session) unwrap it before handing bytes to the CLI. The bytes are intact.
      assert %Msgpax.Bin{data: ^raw} = decoded["bytes"]
    end

    test "the control stream id (0) round-trips" do
      assert %{"t" => "signal", "sid" => 0} |> Codec.encode() |> Codec.decode() == %{
               "t" => "signal",
               "sid" => 0
             }
    end

    test "the maximum signed-64-bit sid round-trips" do
      max = 0x7FFFFFFFFFFFFFFF

      assert %{"t" => "data", "sid" => max} |> Codec.encode() |> Codec.decode() == %{
               "t" => "data",
               "sid" => max
             }
    end
  end

  describe "decode/1 rejects malformed input" do
    test "non-map MessagePack" do
      bytes = Msgpax.pack!(123, iodata: false)
      assert_raise ProtocolError, ~r/frame must be a map/, fn -> Codec.decode(bytes) end
    end

    test "corrupt MessagePack bytes" do
      # 0xC1 is the one byte MessagePack never assigns — a clean 'malformed' probe.
      assert_raise ProtocolError, ~r/malformed msgpack/, fn -> Codec.decode(<<0xC1>>) end
    end

    test "missing 't'" do
      bytes = Codec.encode(%{"sid" => 1})
      assert_raise ProtocolError, ~r/missing string 't'/, fn -> Codec.decode(bytes) end
    end

    test "empty 't'" do
      bytes = Codec.encode(%{"t" => "", "sid" => 1})
      assert_raise ProtocolError, ~r/missing string 't'/, fn -> Codec.decode(bytes) end
    end

    test "non-string 't'" do
      bytes = Codec.encode(%{"t" => 5, "sid" => 1})
      assert_raise ProtocolError, ~r/missing string 't'/, fn -> Codec.decode(bytes) end
    end

    test "missing 'sid'" do
      bytes = Codec.encode(%{"t" => "data"})
      assert_raise ProtocolError, ~r/missing integer 'sid'/, fn -> Codec.decode(bytes) end
    end

    test "non-integer 'sid'" do
      bytes = Codec.encode(%{"t" => "data", "sid" => "1"})
      assert_raise ProtocolError, ~r/missing integer 'sid'/, fn -> Codec.decode(bytes) end
    end

    test "negative 'sid'" do
      bytes = Codec.encode(%{"t" => "data", "sid" => -1})
      assert_raise ProtocolError, ~r/missing integer 'sid'/, fn -> Codec.decode(bytes) end
    end

    test "'sid' beyond the signed 64-bit range (would wrap negative in Go)" do
      bytes = Codec.encode(%{"t" => "data", "sid" => 0x8000000000000000})
      assert_raise ProtocolError, ~r/missing integer 'sid'/, fn -> Codec.decode(bytes) end
    end
  end
end
