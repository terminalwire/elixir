defmodule Terminalwire.Server.TerminalTest do
  use ExUnit.Case

  alias Terminalwire.Server.{Context, Terminal}

  @raw %{
    "stdin" => %{"kind" => "tty"},
    "stdout" => %{"kind" => "tty"},
    "stderr" => %{"kind" => "pipe"},
    "device" => %{"cols" => 100, "rows" => 30, "term" => "xterm-256color", "color" => "truecolor"}
  }

  test "from_map reads device + per-stream tty flags" do
    t = Terminal.from_map(@raw)
    assert t.cols == 100
    assert t.rows == 30
    assert t.term == "xterm-256color"
    assert t.stdin_tty and t.stdout_tty
    refute t.stderr_tty
    assert Terminal.tty?(t)
  end

  test "from_map is nil-safe with sane defaults" do
    t = Terminal.from_map(nil)
    assert t.cols == 80 and t.rows == 24
    refute Terminal.tty?(t)
  end

  # Regression: Context.terminal/1 must exist and return a Terminal (it was
  # :undef, crashing any server that read the terminal — caught by the pty test).
  test "Context.terminal returns a Terminal struct" do
    ctx = Context.new(self(), %{terminal: @raw, program: %{"args" => []}})
    t = Context.terminal(ctx)
    assert %Terminal{} = t
    assert t.cols == 100
  end
end
