defmodule Terminalwire.CLITest do
  use ExUnit.Case, async: true

  alias Terminalwire.Server.Context

  # A fake Session that forwards streamed output to the test process and answers
  # stdin reads with a canned line, so we can drive a CLI module end to end.
  defmodule FakeSession do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call({:output, stream, bytes}, _from, test) do
      send(test, {:out, stream, bytes})
      {:reply, :ok, test}
    end

    def handle_call({:request, "stdin", "gets", _}, _from, test),
      do: {:reply, {:ok, "yes\n"}, test}

    def handle_call({:request, "stdin", "getpass", _}, _from, test),
      do: {:reply, {:ok, "s3cret\n"}, test}

    def handle_call({:request, "env", "read", _}, _from, test), do: {:reply, {:ok, "VALUE"}, test}

    def handle_call({:request, _, _, _}, _from, test), do: {:reply, {:ok, nil}, test}

    @impl true
    def handle_cast({:exit, _}, test), do: {:noreply, test}
  end

  # The CLI under test: each @desc'd function is a command; `helper` is not.
  defmodule DemoCLI do
    use Terminalwire.CLI, name: "demo"

    @desc "Greet NAME"
    def hello(name), do: puts("Hello, #{name}!")

    @desc "Add A and B"
    def add(a, b), do: puts("#{String.to_integer(a) + String.to_integer(b)}")

    @desc "Exit with a specific code"
    def boom, do: 3

    @desc "Ask a question then echo the answer"
    def confirm, do: puts("got: " <> String.trim(gets("ok? ")))

    @desc "Write to stdout (no newline) and stderr"
    def noisy do
      print("a")
      warn("b")
      puts("c")
    end

    @desc "Read a secret without echo"
    def secret, do: puts("got " <> String.trim(read_secret("pw? ")))

    @desc "Show an environment variable from the client"
    def showenv(name), do: puts("env=" <> to_string(env(name)))

    # No @desc — an ordinary helper, never reachable as a command.
    def helper, do: :not_a_command
  end

  defp run(argv) do
    {:ok, sess} = FakeSession.start_link(self())
    ctx = %Context{session: sess, program: %{"args" => argv}, capabilities: []}
    status = DemoCLI.run(ctx)
    {status, drain()}
  end

  defp drain(acc \\ %{stdout: "", stderr: ""}) do
    receive do
      {:out, :stdout, b} -> drain(%{acc | stdout: acc.stdout <> b})
      {:out, :stderr, b} -> drain(%{acc | stderr: acc.stderr <> b})
    after
      0 -> acc
    end
  end

  describe "dispatch" do
    test "routes a command to the matching function with its arguments" do
      assert {0, %{stdout: "Hello, Ada!\n"}} = run(["hello", "Ada"])
    end

    test "passes multiple positional arguments in order" do
      assert {0, %{stdout: "5\n"}} = run(["add", "2", "3"])
    end

    test "an integer return value becomes the exit code" do
      assert {3, _} = run(["boom"])
    end

    test "a command can read stdin via the imported gets/1 helper" do
      {status, out} = run(["confirm"])
      assert status == 0
      assert out.stdout =~ "ok? "
      assert out.stdout =~ "got: yes"
    end
  end

  describe "help" do
    test "no args prints the generated command list" do
      {status, out} = run([])
      assert status == 0
      assert out.stdout =~ "Commands:"
      assert out.stdout =~ "demo hello NAME"
      assert out.stdout =~ "# Greet NAME"
      assert out.stdout =~ "demo add A B"
      assert out.stdout =~ "demo help"
    end

    test "the explicit help command prints the same list" do
      {0, out} = run(["help"])
      assert out.stdout =~ "Commands:"
      assert out.stdout =~ "demo confirm"
    end
  end

  describe "errors" do
    test "an unknown command exits 1 with a message and the help list" do
      {status, out} = run(["nope"])
      assert status == 1
      assert out.stderr =~ "unknown command: nope"
      assert out.stdout =~ "Commands:"
    end

    test "the wrong number of arguments exits 1 with a usage hint" do
      {status, out} = run(["hello"])
      assert status == 1
      assert out.stderr =~ "usage: demo hello NAME"
    end

    test "a public function without @desc is not a command" do
      {status, out} = run(["helper"])
      assert status == 1
      assert out.stderr =~ "unknown command: helper"
    end
  end

  describe "terminal helpers" do
    test "print writes without a newline, warn goes to stderr, puts adds a newline" do
      {0, out} = run(["noisy"])
      assert out.stdout == "ac\n"
      assert out.stderr == "b\n"
    end

    test "read_secret reads a line (no echo) from stdin" do
      {0, out} = run(["secret"])
      assert out.stdout =~ "got s3cret"
    end

    test "env reads an environment variable from the client" do
      {0, out} = run(["showenv", "HOME"])
      assert out.stdout =~ "env=VALUE"
    end

    test "context/0 raises when called outside a command" do
      parent = self()

      Task.start(fn ->
        msg =
          try do
            Terminalwire.CLI.context()
            :no_raise
          rescue
            e in RuntimeError -> {:raised, e.message}
          end

        send(parent, msg)
      end)

      assert_receive {:raised, message}
      assert message =~ "inside a command"
    end
  end

  describe "introspection" do
    test "__terminalwire_commands__/0 lists only the @desc'd commands" do
      names = DemoCLI.__terminalwire_commands__() |> Enum.map(fn {n, _, _, _} -> n end)
      assert :hello in names
      assert :add in names
      refute :helper in names
    end
  end
end
