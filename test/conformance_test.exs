defmodule Terminalwire.ConformanceTest do
  @moduledoc """
  Drives the language-neutral conformance corpus (the SAME vectors the Ruby and
  Go implementations run) against the Elixir codec + negotiator. This is the
  cross-implementation contract: pass here and the Elixir server interoperates
  on the wire. Corpus path comes from TERMINALWIRE_CORPUS (set by the workspace
  Makefile) or a local fallback.
  """
  use ExUnit.Case

  # Tagged so this repo's own fast CI can skip it (no corpus); the protocol
  # interop matrix sets TERMINALWIRE_CORPUS and runs it. See test_helper.exs.
  @moduletag :corpus

  alias Terminalwire.{Codec, Negotiator, Window}
  alias Terminalwire.Server.Connection

  @corpus System.get_env("TERMINALWIRE_CORPUS") ||
            Path.expand("../../../conformance", __DIR__)

  # Every category the corpus ships. The completeness gate below fails the build
  # if this list ever drifts from what the corpus actually contains OR from what
  # this suite exercises — so an implementation can't silently skip a category
  # (which is exactly how this suite previously ran only 3 of 5).
  @covered_categories ~w(negotiate roundtrip golden validate flow session)

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

  # Session tapes: recorded client<->server interactions replayed through the SERVER
  # state machine (Connection). The Ruby runner drives the SAME tapes, pinning the
  # two server Connections to emit identical directives and reject the same frames
  # at the same points. Only server-role tapes run here (Go is the other role).
  describe "session corpus (server state machine)" do
    test "every server tape plays identically" do
      vectors = load_session()
      assert length(vectors) > 0, "session corpus is empty — wrong corpus path?"

      for tape <- vectors, tape["role"] == "server" do
        cfg = tape["config"]

        conn =
          Connection.new(
            server_min: cfg["min"],
            server_max: cfg["max"],
            server_capabilities: cfg["capabilities"]
          )

        play_tape(conn, tape["tape"], tape["name"])
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

  # --- session tape playback ---

  defp play_tape(_conn, [], _name), do: :ok

  defp play_tape(conn, [%{"reject" => true} = step | _rest], name) do
    frame = step["recv"]

    try do
      Connection.receive_frame(conn, frame)
      flunk("session/#{name}: expected the server to REJECT #{inspect(frame["t"])}, but it did not")
    rescue
      Terminalwire.ProtocolError -> :ok
    end
  end

  defp play_tape(conn, [%{"do" => action} = step | rest], name) do
    {conn, frame} = do_action(conn, action)
    assert_session_directives([{:send, frame}], step["emit"], name)
    play_tape(conn, rest, name)
  end

  defp play_tape(conn, [step | rest], name) do
    {conn, directives} = Connection.receive_frame(conn, step["recv"])
    assert_session_directives(directives, step["emit"], name)
    play_tape(conn, rest, name)
  end

  # Server-initiated actions: invoke the Connection and return {conn, emitted frame}.
  defp do_action(conn, %{"open_stream" => spec}) do
    {stream, mode} =
      case spec do
        %{"stream" => s} = m -> {s, m["mode"]}
        s -> {s, nil}
      end

    {conn, _sid, frame} = Connection.open_stream(conn, stream, mode)
    {conn, frame}
  end

  defp do_action(conn, %{"call" => c}) do
    {conn, _sid, frame} = Connection.call(conn, c["resource"], c["method"], c["params"] || %{})
    {conn, frame}
  end

  defp assert_session_directives(directives, expected, name) do
    assert length(directives) == length(expected),
           "session/#{name}: expected #{length(expected)} directive(s), got #{inspect(directives)}"

    directives
    |> Enum.zip(expected)
    |> Enum.each(fn {actual, exp} -> assert_session_directive(actual, exp, name) end)
  end

  defp assert_session_directive({:send, frame}, %{"send" => want}, name) do
    assert tape_subset?(tape_stringify(want), tape_stringify(frame)),
           "session/#{name}: send #{inspect(frame)} does not contain #{inspect(want)}"
  end

  defp assert_session_directive({:event, evname, payload}, %{"event" => want} = exp, name) do
    assert to_string(evname) == want, "session/#{name}: event #{evname} != #{want}"

    case exp do
      %{"data" => data} ->
        assert tape_subset?(tape_stringify(data), tape_stringify(payload)),
               "session/#{name}: event payload #{inspect(payload)} missing #{inspect(data)}"

      _ ->
        :ok
    end
  end

  defp assert_session_directive(actual, exp, name) do
    flunk("session/#{name}: directive #{inspect(actual)} does not match #{inspect(exp)}")
  end

  # Deep-convert atom/string keys to strings so impl payloads compare against the
  # corpus's string keys; match a corpus map as a SUBSET of the actual.
  defp tape_stringify(m) when is_map(m) and not is_struct(m),
    do: Map.new(m, fn {k, v} -> {to_string(k), tape_stringify(v)} end)

  defp tape_stringify(l) when is_list(l), do: Enum.map(l, &tape_stringify/1)
  defp tape_stringify(other), do: other

  defp tape_subset?(exp, act) when is_map(exp) and is_map(act),
    do: Enum.all?(exp, fn {k, v} -> Map.has_key?(act, k) and tape_subset?(v, Map.get(act, k)) end)

  defp tape_subset?(exp, act), do: exp == act

  # --- session tapes are S-expressions (a tiny reader, shared grammar with Ruby/Go) ---

  defp load_session do
    Path.wildcard(Path.join([@corpus, "vectors", "session", "*.sexp"]))
    |> Enum.flat_map(fn path ->
      path |> File.read!() |> sexp_read_all() |> Enum.map(&sexp_interpret/1)
    end)
  end

  defp sexp_interpret([_tape, name, [role | conf] | transcript]) do
    if role == "client" do
      # Go runs client tapes; here we only need enough to skip them by role.
      %{"name" => name, "role" => role}
    else
      %{"name" => name, "role" => role, "config" => sexp_map(conf), "tape" => sexp_group(transcript)}
    end
  end

  defp sexp_group(forms) do
    forms
    |> Enum.reduce([], fn f, acc ->
      case f do
        ["recv", frame] -> [%{"recv" => sexp_value(frame), "emit" => []} | acc]
        ["do", action] -> [%{"do" => sexp_action(action), "emit" => []} | acc]
        ["send", frame] -> update_last(acc, &Map.update!(&1, "emit", fn e -> e ++ [%{"send" => sexp_value(frame)}] end))
        ["reject"] -> update_last(acc, &Map.put(&1, "reject", true))
        ["event", name | data] ->
          ev = if data == [], do: %{"event" => to_string(name)}, else: %{"event" => to_string(name), "data" => sexp_map(data)}
          update_last(acc, &Map.update!(&1, "emit", fn e -> e ++ [ev] end))
      end
    end)
    |> Enum.reverse()
  end

  defp update_last([last | rest], fun), do: [fun.(last) | rest]

  defp sexp_action([head | rest]) do
    case rest do
      [v] when not is_tuple(v) and not is_list(v) -> %{head => sexp_value(v)}
      _ -> %{head => sexp_map(rest)}
    end
  end

  # form -> frame/map/list/bytes
  defp sexp_value(form) when is_list(form) do
    case form do
      [] -> []
      [{:kw, _} | _] -> sexp_map(form)
      ["bin", b64 | _] -> Base.decode64!(b64)
      [head | rest] ->
        if Enum.any?(rest, &match?({:kw, _}, &1)),
          do: Map.put(sexp_map(rest), "t", head),
          else: Enum.map(form, &sexp_value/1)
    end
  end

  defp sexp_value(other), do: other

  defp sexp_map(pairs) do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn [{:kw, k}, v], acc -> Map.put(acc, k, sexp_value(v)) end)
  end

  # reader: text -> forms
  defp sexp_read_all(text), do: text |> sexp_tokenize([]) |> sexp_read_forms([])

  defp sexp_read_forms([], acc), do: Enum.reverse(acc)
  defp sexp_read_forms(toks, acc) do
    {form, rest} = sexp_read_form(toks)
    sexp_read_forms(rest, [form | acc])
  end

  defp sexp_read_form([:open | rest]), do: sexp_read_list(rest, [])
  defp sexp_read_form([{:str, s} | rest]), do: {s, rest}
  defp sexp_read_form([{:atom, a} | rest]), do: {sexp_atom(a), rest}

  defp sexp_read_list([:close | rest], acc), do: {Enum.reverse(acc), rest}
  defp sexp_read_list(toks, acc) do
    {form, rest} = sexp_read_form(toks)
    sexp_read_list(rest, [form | acc])
  end

  defp sexp_atom("true"), do: true
  defp sexp_atom("false"), do: false
  defp sexp_atom("nil"), do: nil
  defp sexp_atom(":" <> name), do: {:kw, name}
  defp sexp_atom(a) do
    cond do
      Regex.match?(~r/\A-?\d+\z/, a) -> String.to_integer(a)
      Regex.match?(~r/\A-?\d+\.\d+\z/, a) -> String.to_float(a)
      true -> a
    end
  end

  defp sexp_tokenize(<<>>, acc), do: Enum.reverse(acc)
  defp sexp_tokenize(<<";", rest::binary>>, acc), do: sexp_tokenize(sexp_skip_line(rest), acc)
  defp sexp_tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\r, ?\n], do: sexp_tokenize(rest, acc)
  defp sexp_tokenize(<<"(", rest::binary>>, acc), do: sexp_tokenize(rest, [:open | acc])
  defp sexp_tokenize(<<")", rest::binary>>, acc), do: sexp_tokenize(rest, [:close | acc])
  defp sexp_tokenize(<<"\"", rest::binary>>, acc) do
    {s, rest2} = sexp_read_string(rest, <<>>)
    sexp_tokenize(rest2, [{:str, s} | acc])
  end
  defp sexp_tokenize(text, acc) do
    {a, rest} = sexp_read_atom(text, <<>>)
    sexp_tokenize(rest, [{:atom, a} | acc])
  end

  defp sexp_skip_line(<<>>), do: <<>>
  defp sexp_skip_line(<<"\n", rest::binary>>), do: rest
  defp sexp_skip_line(<<_, rest::binary>>), do: sexp_skip_line(rest)

  defp sexp_read_string(<<"\"", rest::binary>>, acc), do: {acc, rest}
  defp sexp_read_string(<<"\\", c, rest::binary>>, acc) do
    ch = case c do
      ?n -> "\n"
      ?t -> "\t"
      ?r -> "\r"
      _ -> <<c>>
    end
    sexp_read_string(rest, acc <> ch)
  end
  defp sexp_read_string(<<c, rest::binary>>, acc), do: sexp_read_string(rest, acc <> <<c>>)

  defp sexp_read_atom(<<c, _::binary>> = text, acc) when c in [?(, ?), ?\s, ?\t, ?\r, ?\n, ?;, ?"], do: {acc, text}
  defp sexp_read_atom(<<>>, acc), do: {acc, <<>>}
  defp sexp_read_atom(<<c, rest::binary>>, acc), do: sexp_read_atom(rest, acc <> <<c>>)

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
