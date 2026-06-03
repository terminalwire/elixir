defmodule Terminalwire.ConformanceTest do
  @moduledoc """
  Drives the language-neutral conformance corpus (the SAME vectors the Ruby and
  Go implementations run) against the Elixir codec + negotiator. This is the
  cross-implementation contract: pass here and the Elixir server interoperates
  on the wire. Corpus path comes from TERMINALWIRE_CORPUS (set by the workspace
  Makefile) or a local fallback.
  """
  use ExUnit.Case

  alias Terminalwire.{Codec, Negotiator, Window}

  @corpus System.get_env("TERMINALWIRE_CORPUS") ||
            Path.expand("../../../conformance", __DIR__)

  # Every category the corpus ships. The completeness gate below fails the build
  # if this list ever drifts from what the corpus actually contains OR from what
  # this suite exercises — so an implementation can't silently skip a category
  # (which is exactly how this suite previously ran only 3 of 5).
  @covered_categories ~w(negotiate roundtrip golden validate flow)

  defp load(category) do
    Path.wildcard(Path.join([@corpus, "vectors", category, "*.yml"]))
    |> Enum.flat_map(&parse_yaml_list/1)
  end

  # Minimal YAML reader for the corpus (avoids a yaml dep): the corpus is a flat
  # list of flow-mapping entries. We shell to ruby -ryaml -rjson for fidelity.
  defp parse_yaml_list(path) do
    json =
      System.cmd("ruby", [
        "-ryaml",
        "-rjson",
        "-e",
        "print JSON.generate(YAML.safe_load_file(ARGV[0]))",
        path
      ])
      |> elem(0)

    :json.decode(json)
  end

  defp hex_to_bytes(hex) do
    hex |> String.split() |> Enum.map(&String.to_integer(&1, 16)) |> :erlang.list_to_binary()
  end

  describe "negotiate corpus" do
    test "every vector" do
      for v <- load("negotiate") do
        c = v["client"]
        s = v["server"]
        exp = v["expect"]

        result =
          Negotiator.negotiate(
            c["protocol"],
            c["capabilities"],
            s["min"],
            s["max"],
            s["capabilities"]
          )

        case exp["decision"] do
          "welcome" ->
            assert {:welcome, exp["protocol"], exp["capabilities"]} == result,
                   "negotiate/#{v["name"]}"

          "incompatible" ->
            assert {:incompatible, exp["supported"]["min"], exp["supported"]["max"]} == result,
                   "negotiate/#{v["name"]}"
        end
      end
    end
  end

  describe "golden corpus (exact wire bytes)" do
    test "decode golden bytes to the expected frame" do
      for v <- load("golden") do
        bytes = hex_to_bytes(v["bytes_hex"])
        decoded = Codec.decode(bytes)
        # Compare on the JSON-ish shape: the corpus frame uses string keys and
        # $bin sentinels for binary; normalize both sides.
        assert normalize(decoded) == normalize(resolve_bin(v["frame"])),
               "golden/#{v["name"]} decode"
      end
    end

    # msgpack map key order is unspecified, so we do NOT require byte-identical
    # re-encoding across languages. The real guarantee: what we encode, we (and
    # any conformant impl) decode back to the same frame.
    test "encode then decode round-trips to the same frame" do
      for v <- load("golden") do
        frame = Codec.decode(hex_to_bytes(v["bytes_hex"]))
        assert Codec.decode(Codec.encode(frame)) == frame, "golden/#{v["name"]} round-trip"
      end
    end

    test "encode returns a binary (not iodata) for transport" do
      frame = Codec.decode(hex_to_bytes(List.first(load("golden"))["bytes_hex"]))
      assert is_binary(Codec.encode(frame))
    end
  end

  describe "validate corpus (malformed input)" do
    test "every malformed vector raises ProtocolError" do
      for v <- load("validate") do
        bytes = hex_to_bytes(v["bytes_hex"])
        assert_raise Terminalwire.ProtocolError, fn -> Codec.decode(bytes) end
      end
    end
  end

  describe "roundtrip corpus (decode . encode == identity)" do
    test "every frame round-trips" do
      vectors = load("roundtrip")
      assert length(vectors) > 0, "roundtrip corpus is empty — wrong corpus path?"

      for v <- vectors do
        frame = normalize(resolve_bin(v["frame"]))
        assert normalize(Codec.decode(Codec.encode(frame))) == frame,
               "roundtrip/#{v["name"]}"
      end
    end
  end

  describe "flow corpus (credit accounting)" do
    test "every flow vector accounts identically + never overflows" do
      vectors = load("flow")
      assert length(vectors) > 0, "flow corpus is empty — wrong corpus path?"

      for v <- vectors do
        initial = v["window"]

        {window, _granted, _taken} =
          Enum.reduce(v["ops"], {Window.new(initial), 0, 0}, fn op, {w, granted, taken} ->
            {w, granted} =
              if Map.has_key?(op, "grant"),
                do: {Window.grant(w, op["grant"]), granted + op["grant"]},
                else: {w, granted}

            if Map.has_key?(op, "take") do
              {got, w} = Window.take(w, op["take"])
              assert got == op["got"], "flow/#{v["name"]}: take(#{op["take"]}) = #{got}, want #{op["got"]}"
              taken = taken + got
              assert taken <= initial + granted, "flow/#{v["name"]}: overflow"
              {w, granted, taken}
            else
              {w, granted, taken}
            end
          end)

        assert Window.available(window) == v["final_available"], "flow/#{v["name"]} final"
      end
    end
  end

  # Completeness gate: assert this suite exercises EVERY category the corpus
  # ships — no silent drift. If the corpus gains a category, this fails until the
  # implementation adds a runner for it.
  describe "corpus completeness" do
    test "this implementation exercises every corpus category" do
      on_disk =
        Path.wildcard(Path.join([@corpus, "vectors", "*"]))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&Path.basename/1)
        |> MapSet.new()

      covered = MapSet.new(@covered_categories)

      missing = MapSet.difference(on_disk, covered)
      stale = MapSet.difference(covered, on_disk)

      assert MapSet.size(missing) == 0,
             "corpus categories NOT exercised by this implementation: #{inspect(MapSet.to_list(missing))}"

      assert MapSet.size(stale) == 0,
             "categories claimed-covered but absent from corpus: #{inspect(MapSet.to_list(stale))}"
    end
  end

  # Msgpax decodes `bin` to a plain binary; the corpus represents binary as
  # {"$bin" => base64}. Resolve those so comparisons line up.
  defp resolve_bin(%{"$bin" => b64}), do: Base.decode64!(b64)
  defp resolve_bin(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, resolve_bin(v)} end)
  defp resolve_bin(list) when is_list(list), do: Enum.map(list, &resolve_bin/1)
  defp resolve_bin(other), do: other

  # Msgpax may return Msgpax.Bin structs on encode side; normalize to raw binary
  # and stringify nothing else.
  defp normalize(%Msgpax.Bin{data: d}), do: d
  defp normalize(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, normalize(v)} end)
  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other
end
