defmodule Terminalwire.Codec do
  @moduledoc """
  Pure bytes <-> frame conversion. A frame is a map with string keys (the wire
  shape). No I/O, no transport — the sans-IO seam the conformance corpus
  exercises directly. Mirrors `Terminalwire2::Codec`.

  Wire format is MessagePack. One subtlety that matters for cross-language
  interop: binary payloads (e.g. `data.bytes`) must be encoded as MessagePack
  `bin`, not `str`, or the Go client's `[]byte` decode fails. Callers pass such
  fields wrapped in `Msgpax.Bin` (see `Terminalwire.Frames.data/2`).
  """

  alias Terminalwire.ProtocolError

  @doc """
  Encode a frame map to MessagePack bytes (a binary).

  Note: msgpack map key order is unspecified, so the exact byte sequence may
  differ from another implementation's encoding of the same frame — that is fine
  and fully interoperable. The contract is that every implementation *decodes* the
  canonical golden bytes identically, and that what one encodes another decodes
  correctly. We do not promise byte-identical encoding across languages.
  """
  def encode(frame) when is_map(frame) do
    # iodata: false → return a binary (transports want a binary frame).
    Msgpax.pack!(frame, iodata: false)
  end

  def encode(other),
    do: raise(ProtocolError, message: "frame must be a map, got #{inspect(other)}")

  @doc """
  Decode MessagePack bytes for exactly one frame. Returns the frame map (string
  keys). Raises `ProtocolError` for anything that isn't a well-formed frame.
  `bin` values come back as plain binaries (unpack with binary: true).
  """
  def decode(bytes) when is_binary(bytes) do
    frame =
      case Msgpax.unpack(bytes, binary: true) do
        {:ok, map} when is_map(map) -> map
        {:ok, _} -> raise ProtocolError, message: "frame must be a map"
        {:error, e} -> raise ProtocolError, message: "malformed msgpack: #{inspect(e)}"
      end

    unless is_binary(Map.get(frame, "t")) and Map.get(frame, "t") != "" do
      raise ProtocolError, message: "frame missing string 't'"
    end

    unless is_integer(Map.get(frame, "sid")) do
      raise ProtocolError, message: "frame missing integer 'sid'"
    end

    frame
  end
end
