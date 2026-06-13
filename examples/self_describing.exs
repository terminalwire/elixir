# self_describing.exs — a tiny Terminalwire CLI, served from Elixir, that can print
# its OWN source code. The whole program (CLI + the server that streams it) is this
# one file, and `source` streams this file back to you — the CLI describing itself.
#
#   1. Run the server:   elixir examples/self_describing.exs
#   2. Make a launcher pointing at it (one-time):
#        printf '#!/usr/bin/env terminalwire-exec\nurl: "ws://localhost:8080/terminal"\n' > demo
#        chmod +x demo
#   3. Use it:
#        ./demo            # help
#        ./demo hello      # interactive (reads your name)
#        ./demo source     # prints THIS file — the source that defines the CLI
#        ./demo whoami     # your terminal details
#
# No entitlement grants needed: it only uses stdout/stdin/terminal (the session
# itself), never the client's files/env/browser — File.read! below reads the
# SERVER's own file, then streams the text to your terminal.

Mix.install([
  {:terminalwire, path: Path.expand("..", __DIR__)}, # the lib in this repo
  {:bandit, "~> 1.5"},
  {:plug, "~> 1.16"},
  {:websock_adapter, "~> 0.5"}
])

defmodule SelfDescribing.CLI do
  @moduledoc "A Terminalwire CLI that runs in Elixir and can show its own code."
  alias Terminalwire.Server.Context

  # Captured at COMPILE time: the absolute path to this very script.
  @source __ENV__.file

  # The handler. Terminalwire hands you a Context once the handshake completes; your
  # code is plain Elixir. `Context.puts/gets` (and bare `IO.puts`, via the group
  # leader Terminalwire sets on this process) stream over the wire to the user.
  def run(ctx) do
    case Context.args(ctx) do
      [] -> help(ctx)
      ["hello" | _] -> hello(ctx)
      ["source" | _] -> source(ctx)
      ["whoami" | _] -> whoami(ctx)
      [other | _] -> Context.warn(ctx, "unknown command: #{other}"); 1
    end
  end

  defp help(ctx) do
    # Bare IO.* works too — Terminalwire sets this process's group leader to an IO
    # device that streams standard IO to the client (IO.ANSI colors and all).
    IO.puts([IO.ANSI.cyan(), "self-describing-cli", IO.ANSI.reset()])

    Context.puts(ctx, """

      hello     greet you (reads your name from stdin)
      source    print THIS program's own source code
      whoami    show your terminal details

    Try:  demo source
    """)

    0
  end

  defp hello(ctx) do
    name = ctx |> Context.gets("your name? ") |> to_string() |> String.trim()
    name = if name == "", do: "stranger", else: name
    Context.puts(ctx, "Hello, #{name}! 👋  (this ran on the server, in Elixir)")
    0
  end

  # The self-describing part: read my own source file and stream it to the user.
  defp source(ctx) do
    Context.puts(ctx, "# I'm defined by #{Path.basename(@source)}, served from Elixir:\n")
    Context.puts(ctx, File.read!(@source))
    0
  end

  defp whoami(ctx) do
    t = Context.terminal(ctx)
    Context.puts(ctx, "terminal: #{t.cols}x#{t.rows}  color=#{t.color}  stdout_tty=#{t.stdout_tty}")
    0
  end
end

defmodule SelfDescribing.Router do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  # Upgrade /terminal to the ready-made Terminalwire WebSock adapter, wired to our
  # handler. This is the entire integration — one route.
  get "/terminal" do
    WebSockAdapter.upgrade(conn, Terminalwire.WebSock, [handler: &SelfDescribing.CLI.run/1], timeout: :infinity)
  end

  match(_, do: send_resp(conn, 404, "not here"))
end

port = 8080
IO.puts("Terminalwire self-describing CLI → ws://localhost:#{port}/terminal  (Ctrl-C to stop)")
{:ok, _} = Bandit.start_link(plug: SelfDescribing.Router, port: port)
Process.sleep(:infinity)
