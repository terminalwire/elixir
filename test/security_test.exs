defmodule Terminalwire.SecurityTest do
  use ExUnit.Case, async: true

  # A mechanical security floor. This server runs untrusted input: a hostile client
  # can send arbitrary frames, and the CLI it serves runs argv the client controls.
  # None of the primitives below — code execution, shell-out, unsafe deserialization,
  # or untrusted-string→atom conversion (atom-table exhaustion) — may be even one grep
  # away in the library. If you ever need one deliberately, you have to delete it from
  # this list on purpose, which is the point: it can't creep in silently.
  @forbidden [
    # arbitrary code execution
    "Code.eval",
    "eval_string",
    "eval_quoted",
    "EEx.",
    # shell / OS command execution
    "System.cmd",
    ":os.cmd",
    "Port.open",
    "open_port",
    # unsafe deserialization (RCE + atom creation from bytes)
    "binary_to_term",
    # atom-table exhaustion from untrusted strings (note: the *_to_existing_atom
    # variants are bounded and intentionally NOT forbidden)
    "String.to_atom",
    "binary_to_atom",
    "list_to_atom"
  ]

  test "the library never reaches for code-exec, shell-out, unsafe deserialization, or atom creation" do
    files = Path.wildcard("lib/**/*.ex")
    assert files != [], "expected to find library sources under lib/"

    offenders =
      for path <- files,
          source = File.read!(path),
          token <- @forbidden,
          String.contains?(source, token),
          do: "  #{path}: #{token}"

    assert offenders == [],
           "Forbidden security-sensitive primitives found in lib/:\n" <>
             Enum.join(offenders, "\n")
  end
end
