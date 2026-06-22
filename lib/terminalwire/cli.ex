defmodule Terminalwire.CLI do
  @moduledoc ~S"""
  A small command router so your CLI reads like the commands themselves — public
  functions become commands, their parameters become arguments, and `@desc`
  becomes help. It's the Elixir analog of Ruby's Thor `desc`/`def`.

      defmodule MyApp.CLI do
        use Terminalwire.CLI, name: "my-app"

        @desc "Greet someone by name"
        def hello(name) do
          puts("Hello, #{name}!")
        end

        @desc "Deploy to an environment"
        def deploy(env) do
          confirm = gets("Deploy to #{env}? [y/N] ")
          if String.trim(confirm) == "y", do: puts("Deploying…"), else: puts("Aborted")
        end
      end

  Mount it like any handler — `use` generates `run/1`:

      WebSockAdapter.upgrade(conn, Terminalwire.WebSock, [handler: &MyApp.CLI.run/1], [])

  Then `my-app hello Ada` calls `hello("Ada")`, `my-app deploy staging` calls
  `deploy("staging")`, and `my-app` (or `my-app help`) prints a generated command
  list. An unknown command or wrong argument count exits non-zero with a usage hint.

  ## How it dispatches

    * The first argument is the command; it's matched to a `@desc`-annotated public
      function with the **same name and the same number of remaining arguments**.
    * Functions **without** a `@desc` are ordinary helpers, not commands.
    * A command's return value sets the exit code when it's an integer; otherwise 0.

  ## Talking to the terminal

  Inside a command, `use Terminalwire.CLI` imports terminal helpers bound to the
  current session — `puts/1`, `print/1`, `warn/1`, `gets/1`, `read_secret/1`,
  `env/1` — so you write `puts("hi")` instead of threading a context around. Bare
  `IO.puts` and any standard-IO library (like Owl) also stream to the user, because
  the handler's group leader is a Terminalwire IO device. For everything else on the
  context (files, directories, the browser, the raw terminal), `context/0` returns
  the `Terminalwire.Server.Context`:

      @desc "Import a CSV from the user's machine"
      def import(path) do
        data = Terminalwire.Server.Context.file_read(context(), path)
        puts("imported #{byte_size(data)} bytes")
      end

  ## Scope

  This is a router, not a full option parser — it handles commands and positional
  arguments. For flags, options, and richer parsing, write a plain `run/1` handler
  and reach for a library like [Optimus](https://hex.pm/packages/optimus); the two
  approaches use the exact same `Context`.
  """

  alias Terminalwire.Server.Context

  @ctx_key :"$terminalwire_cli_ctx"

  defmacro __using__(opts) do
    name = Keyword.get(opts, :name, "app")

    quote do
      import Terminalwire.CLI,
        only: [
          puts: 0,
          puts: 1,
          print: 1,
          warn: 0,
          warn: 1,
          gets: 0,
          gets: 1,
          read_secret: 0,
          read_secret: 1,
          env: 1,
          context: 0
        ]

      Module.register_attribute(__MODULE__, :terminalwire_commands, accumulate: true)
      @terminalwire_cli_name unquote(name)
      @on_definition Terminalwire.CLI
      @before_compile Terminalwire.CLI
    end
  end

  @doc false
  # Collect each @desc-annotated public function as a command (name, arity,
  # description, argument names) and consume the @desc so the next plain def isn't
  # picked up.
  def __on_definition__(env, :def, name, args, _guards, _body) do
    case Module.get_attribute(env.module, :desc) do
      nil ->
        :ok

      desc when is_binary(desc) ->
        arg_names = Enum.map(args, &arg_name/1)

        Module.put_attribute(
          env.module,
          :terminalwire_commands,
          {name, length(args), desc, arg_names}
        )

        Module.delete_attribute(env.module, :desc)
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  defp arg_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: Atom.to_string(name)
  defp arg_name(_), do: "arg"

  defmacro __before_compile__(env) do
    commands = env.module |> Module.get_attribute(:terminalwire_commands) |> Enum.reverse()
    name = Module.get_attribute(env.module, :terminalwire_cli_name)

    quote do
      @doc """
      Generated entry point. Dispatches the client's argv to a command; pass
      `&#{inspect(__MODULE__)}.run/1` to `Terminalwire.WebSock`.
      """
      def run(ctx),
        do:
          Terminalwire.CLI.__run__(
            __MODULE__,
            ctx,
            unquote(name),
            unquote(Macro.escape(commands))
          )

      @doc false
      def __terminalwire_commands__, do: unquote(Macro.escape(commands))
    end
  end

  # --- runtime dispatch -----------------------------------------------------

  @doc false
  def __run__(module, ctx, name, commands) do
    Process.put(@ctx_key, ctx)

    case Context.args(ctx) do
      [] -> help(ctx, name, commands)
      ["help" | _] -> help(ctx, name, commands)
      [command | rest] -> invoke(module, ctx, name, commands, command, rest)
    end
  end

  defp invoke(module, ctx, name, commands, command, args) do
    arity = length(args)

    exact =
      Enum.find(commands, fn {n, a, _, _} -> Atom.to_string(n) == command and a == arity end)

    by_name = Enum.find(commands, fn {n, _, _, _} -> Atom.to_string(n) == command end)

    cond do
      exact ->
        {fun, _, _, _} = exact

        case apply(module, fun, args) do
          status when is_integer(status) -> status
          _ -> 0
        end

      by_name ->
        Context.warn(ctx, "usage: " <> signature(name, by_name))
        1

      true ->
        Context.warn(ctx, "unknown command: #{command}\n")
        help(ctx, name, commands)
        1
    end
  end

  defp help(ctx, name, commands) do
    rows =
      Enum.map(commands, fn {_, _, desc, _} = cmd -> {signature(name, cmd), desc} end) ++
        [{"#{name} help", "List available commands"}]

    width = rows |> Enum.map(fn {sig, _} -> String.length(sig) end) |> Enum.max(fn -> 0 end)

    Context.puts(ctx, "Commands:")

    Enum.each(rows, fn {sig, desc} ->
      Context.puts(ctx, "  #{String.pad_trailing(sig, width)}  # #{desc}")
    end)

    0
  end

  # "my-app deploy ENV" from {name, arity, desc, ["env"]}
  defp signature(name, {command, _arity, _desc, arg_names}) do
    [name, Atom.to_string(command) | Enum.map(arg_names, &String.upcase/1)]
    |> Enum.join(" ")
  end

  # --- context-bound terminal helpers (imported into the CLI module) --------

  @doc "The current command's `Terminalwire.Server.Context` (for files, env, browser, the raw terminal)."
  def context do
    case Process.get(@ctx_key) do
      nil -> raise "Terminalwire.CLI helpers must be called from inside a command"
      ctx -> ctx
    end
  end

  @doc "Write a line to the user's stdout."
  def puts(data \\ ""), do: Context.puts(context(), data)

  @doc "Write to the user's stdout without a trailing newline."
  def print(data), do: Context.print(context(), data)

  @doc "Write a line to the user's stderr."
  def warn(data \\ ""), do: Context.warn(context(), data)

  @doc "Prompt (optional) and read a line from the user's stdin."
  def gets(prompt \\ nil), do: Context.gets(context(), prompt)

  @doc "Prompt (optional) and read a line without echo (passwords)."
  def read_secret(prompt \\ nil), do: Context.read_secret(context(), prompt)

  @doc "Read an environment variable from the user's machine (entitlement-gated)."
  def env(name), do: Context.env(context(), name)
end
