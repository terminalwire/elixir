# owl_cli.exs — a Terminalwire CLI built the "real app" way: Optimus for parsing
# (subcommands, args, auto --help) and Owl for UI (tables, color, a spinner). It
# proves Owl's rich, width-aware output renders over the wire — Owl writes to the
# group leader Terminalwire installs, so it streams to the user's real terminal.
#
#   elixir examples/owl_cli.exs        # boots ws://localhost:8081/terminal
#   printf '#!/usr/bin/env terminalwire-exec\nurl: "ws://localhost:8081/terminal"\n' > app && chmod +x app
#   ./app --help          # Optimus-generated usage
#   ./app apps            # an Owl table
#   ./app hello Brad      # colored greeting (Owl.Data.tag)
#   ./app deploy staging  # an Owl spinner

Mix.install([
  {:terminalwire, path: Path.expand("..", __DIR__)},
  {:bandit, "~> 1.5"},
  {:plug, "~> 1.16"},
  {:websock_adapter, "~> 0.5"},
  {:optimus, "~> 0.3"},
  {:owl, "~> 0.12"}
])

defmodule OwlCLI do
  alias Terminalwire.Server.Context

  @apps [
    %{name: "tinyzap", lang: "Ruby", url: "https://tinyzap.com/terminal"},
    %{name: "ogplus", lang: "Ruby", url: "https://opengraphplus.com/terminal"},
    %{name: "demo", lang: "Elixir", url: "ws://localhost:8081/terminal"}
  ]

  def run(ctx) do
    # Optimus.parse (NOT parse!) — parse! calls System.halt on --help/errors, which
    # would take down the server. We handle every variant ourselves and just print.
    case Optimus.parse(optimus(), Context.args(ctx)) do
      {:ok, [:apps], _} -> apps()
      {:ok, [:hello], %{args: %{name: name}}} -> hello(name)
      {:ok, [:deploy], %{args: %{env: env}}} -> deploy(env)
      {:ok, _} -> usage(ctx)
      :help -> usage(ctx)
      {:help, _sub} -> usage(ctx)
      :version -> Context.puts(ctx, "owl-demo 1.0"); 0
      {:error, errs} -> errors(ctx, errs)
      {:error, _sub, errs} -> errors(ctx, errs)
    end
  end

  defp optimus do
    Optimus.new!(
      name: "demo",
      description: "Terminalwire + Optimus + Owl demo",
      version: "1.0",
      allow_unknown_args: false,
      subcommands: [
        apps: [name: "apps", about: "List available apps (an Owl table)"],
        hello: [
          name: "hello",
          about: "Greet someone",
          args: [name: [value_name: "NAME", required: true]]
        ],
        deploy: [
          name: "deploy",
          about: "Pretend to deploy (an Owl spinner)",
          args: [env: [value_name: "ENV", required: true]]
        ]
      ]
    )
  end

  defp usage(ctx), do: (Context.puts(ctx, Optimus.help(optimus())); 0)
  defp errors(ctx, errs), do: (Enum.each(List.wrap(errs), &Context.warn(ctx, &1)); 1)

  # These use Owl.IO/Owl.Spinner with no `ctx` — Owl writes to the group leader
  # Terminalwire installed, so its output streams to the client's terminal on its own.
  # (`ctx` is only needed for args + non-IO resources like files/env/browser.)
  defp apps do
    rows = Enum.map(@apps, &%{"App" => &1.name, "Lang" => &1.lang, "URL" => &1.url})
    Owl.IO.puts(Owl.Table.new(rows, padding_x: 1, divide_body_rows: false))
    0
  end

  defp hello(name) do
    Owl.IO.puts(["Hello, ", Owl.Data.tag(name, :green), "! 👋 ", Owl.Data.tag("(Owl, over the wire)", :light_black)])
    0
  end

  defp deploy(env) do
    Owl.Spinner.run(
      fn -> Process.sleep(1200) end,
      labels: [processing: "Deploying to #{env}…", ok: "Deployed to #{Owl.Data.tag(env, :green)} ✓"]
    )
    0
  end
end

defmodule OwlCLI.Router do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  get "/terminal" do
    WebSockAdapter.upgrade(conn, Terminalwire.WebSock, [handler: &OwlCLI.run/1], timeout: :infinity)
  end

  match(_, do: send_resp(conn, 404, "not here"))
end

port = 8081
IO.puts("Owl/Optimus CLI → ws://localhost:#{port}/terminal  (Ctrl-C to stop)")
{:ok, _} = Bandit.start_link(plug: OwlCLI.Router, port: port)
Process.sleep(:infinity)
