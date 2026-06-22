# Terminalwire (Elixir)

**Ship a CLI for your web app. No API required.**

Terminalwire streams a command-line app straight from your Phoenix/Plug server to
your users' machines over a single WebSocket. You write your CLI *in your app* —
calling your contexts, Ecto, and business logic directly — and it runs on the
user's workstation with their terminal, files, and browser.

A CLI usually costs you three things to build: a **REST API** to back it, an **SDK
or client binary** to ship, and a **release-and-auto-update pipeline** to keep that
client current. Terminalwire is all three. Users install one small, self-updating
client with a single `curl … | bash`; you ship features by deploying your server.

```
 Terminalwire client ⇄ WebSocket endpoint ⇄ Terminalwire.WebSock
                                            ⇄ Server.Session (protocol)
                                            ⇄ Server.Context ⇄ your CLI handler
```

## Why this is nice

- **No API to build or version.** Your CLI calls your app's code directly — no
  serializers, no SDK, no client/server version skew.
- **Nothing to distribute or update.** Users install one small client
  (`curl <app>.terminalwire.sh | bash`) that self-updates through a signed channel.
  You ship a change by deploying your server — no per-release client build, no
  app-store round trip.
- **It feels local.** Output streams in real time, prompts and passwords work,
  it's color/TTY-aware, resizes with the window, `Ctrl-C` interrupts the
  server-side command, and you can pipe into it (`cat data.csv | your-app import`).
- **Secure by construction.** The client is the trust boundary: the server
  *requests* access to a file/env var/the browser and the client enforces a
  per-app entitlement policy. Your server never touches the user's machine.
- **One BEAM process per session.** Each connection is a supervised process; the
  CLI handler runs in its own task. Natural fit for Phoenix.
- **Same protocol, any client.** This server speaks the exact wire protocol the
  Go client and the Ruby server do — proven by a shared conformance corpus.

## Install

```elixir
def deps do
  [
    {:terminalwire, "~> 0.1"},
    {:websock_adapter, "~> 0.5"}   # to upgrade a Plug/Phoenix conn to a socket
  ]
end
```

## Use

Define your CLI as a module. Public functions are commands, their parameters are
the command's arguments, and `@desc` is the help text — like Ruby's Thor:

```elixir
defmodule MyApp.CLI do
  use Terminalwire.CLI, name: "my-app"

  @desc "Greet someone by name"
  def hello(name) do
    puts("Hello, #{name}!")
  end

  @desc "Deploy to an environment"
  def deploy(env) do
    if String.trim(gets("Deploy to #{env}? [y/N] ")) == "y" do
      puts("Deploying #{env}…")          # call your app's code right here
    else
      puts("Aborted")
    end
  end
end
```

Mount it on a WebSocket route — `use` generated `run/1` for you:

```elixir
# Plug / Bandit / Cowboy
WebSockAdapter.upgrade(conn, Terminalwire.WebSock, [handler: &MyApp.CLI.run/1], [])
```

That's a working CLI: `my-app hello Ada` runs `hello("Ada")`, `my-app deploy staging`
runs `deploy("staging")`, and `my-app` (or `my-app help`) prints a generated command
list. Inside a command, `puts`/`print`/`warn`/`gets`/`read_secret`/`env` talk to the
user's terminal; `context/0` reaches files, the browser, and the rest.

Want flags, options, or your own parsing? `Terminalwire.CLI` is a thin layer over a
plain `run/1` handler — drop down to it and use any parser. That's the next section.

## The handler API

`Terminalwire.CLI` is a thin layer over a plain handler: a one-argument function
that takes a `Terminalwire.Server.Context`. Use it directly when you want full
control over parsing. It's called once the handshake completes, in its own BEAM task
whose **group leader** is a Terminalwire IO device, so plain `IO.puts`/`IO.gets`,
`IO.ANSI`, and any library that writes to standard IO (like
[Owl](https://hexdocs.pm/owl)) stream straight to the user's terminal. The `Context`
covers everything that *isn't* standard IO: args, prompts, the client's terminal,
files, env, the browser.

```elixir
def run(ctx) do
  case Context.args(ctx) do
    ["deploy", env] -> deploy(ctx, env)
    _ -> Context.warn(ctx, "unknown command"); 1
  end
end
```

### The Context API

| | |
|---|---|
| **args** | `Context.args(ctx)` → the argv list you parse |
| **stdout** | `Context.puts/print` — or just `IO.puts` / `Owl.IO.puts` (group leader) |
| **stderr** | `Context.warn(ctx, msg)` (see the stderr rule below) |
| **input** | `Context.gets(ctx, prompt)`, `Context.read_secret(ctx, prompt)` |
| **piped stdin** | `Context.read(ctx)` (drain to EOF), `Context.read_chunk(ctx)` |
| **terminal** | `Context.terminal(ctx)` → `%{cols, rows, color, *_tty}` |
| **files** | `Context.file_read/file_write/file_append/file_delete` |
| **dirs** | `Context.dir_list/dir_create/dir_delete` |
| **env** | `Context.env(ctx, "NAME")` |
| **browser** | `Context.browser_launch(ctx, url)` |
| **raw input** | `Context.raw_input(ctx, fun)`, `Context.read_key(ctx)` — REPL/TUI |
| **exit code** | return an integer from `run/1` (or `Context.exit(ctx, n)`) |

Files / env / browser are **requests the client enforces** against its per-app
entitlement policy — your server can't touch the user's machine unless they grant it.

### Parsing args — pick any style

Terminalwire hands you raw argv (`Context.args/1`); parsing is pure, so use whatever
you like. All three below work unmodified.

**Raw / stdlib.** Pattern-match, or use stdlib `OptionParser` for flags:

```elixir
{opts, args, _} = OptionParser.parse(Context.args(ctx), strict: [verbose: :boolean])
```

**[Optimus](https://hexdocs.pm/optimus)** — subcommands, typed args, generated
`--help`. **Use `Optimus.parse`, never `Optimus.parse!`**: the bang version calls
`System.halt` on `--help`/errors, which would take down your server. Handle the
result and render it yourself:

```elixir
case Optimus.parse(spec(), Context.args(ctx)) do
  {:ok, [:deploy], %{args: %{env: env}}} -> deploy(ctx, env)
  :help          -> Context.puts(ctx, Optimus.help(spec())); 0
  {:error, errs} -> Enum.each(errs, &Context.warn(ctx, &1)); 1
end
```

**[Owl](https://hexdocs.pm/owl)** — rich UI (tables, color, prompts, spinners,
progress). It writes to the group leader, so it streams over the wire for free —
and it's width-aware: it asks the group leader for `:io.columns`, which Terminalwire
answers with the *client's* terminal width.

```elixir
Owl.IO.puts(Owl.Table.new(rows))                    # a table, rendered on the client
Owl.IO.puts(Owl.Data.tag("done ✓", :green))         # color
Owl.Spinner.run(fn -> deploy() end, labels: [...])  # live spinner
```

The standard "nice Elixir CLI" stack — **Optimus to parse + Owl to render** — works
as-is over the wire.

### Two rules (both about output, not parsing)

1. **Never `System.halt` (or `Optimus.parse!`, or escript-style exits).** Your
   handler runs *inside the server*; halting kills the BEAM. Return an exit code
   from `run/1` instead.
2. **stdout is the group leader; stderr is not.** `IO.puts` / `Owl.*` /
   `Context.puts` reach the client (stdout). Bare `IO.puts(:stderr, …)` goes to the
   *server's* console — use `Context.warn/2` for the client's stderr. (This is just
   Erlang's IO model: `:stderr` is a separate device from the group leader, not a
   Terminalwire quirk.)

### Runnable examples

- [`examples/self_describing.exs`](examples/self_describing.exs) — a tiny CLI that
  streams its own source (raw `Context.args` + `IO.ANSI`).
- [`examples/owl_cli.exs`](examples/owl_cli.exs) — the full stack: Optimus
  subcommands + Owl tables/color/spinner.

Run either, then point a launcher at it:

```sh
elixir examples/owl_cli.exs
printf '#!/usr/bin/env terminalwire-exec\nurl: "ws://localhost:8081/terminal"\n' > app && chmod +x app
./app apps        # an Owl table, streamed from Elixir to your terminal
```

## Architecture

| layer | module |
|-------|--------|
| sans-IO protocol core | `Terminalwire.Protocol`, `Terminalwire.Codec`, `Terminalwire.Negotiator`, `Terminalwire.Frames` |
| sans-IO server state machine | `Terminalwire.Server.Connection` |
| process that drives it | `Terminalwire.Server.Session` |
| CLI-facing API | `Terminalwire.Server.Context` |
| command router (Thor-style) | `Terminalwire.CLI` |
| WebSocket adapter | `Terminalwire.WebSock` |

The protocol core mirrors the Ruby Terminalwire server and the Go client,
and is validated against the **same language-neutral conformance corpus** in
`terminalwire/protocol` — run `mix test` with `TERMINALWIRE_CORPUS` pointed at it.
That corpus is the cross-implementation contract: pass it and this server
interoperates on the wire with the client and every other server.

## License

Apache-2.0 (source-available — safe to install on your own servers).
