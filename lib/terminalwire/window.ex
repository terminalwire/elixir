defmodule Terminalwire.Window do
  @moduledoc """
  The flow-control credit rule as a pure ledger — no processes, no I/O. Mirrors
  Ruby's `Terminalwire::V2::Window` and the Go `protocol.Window`, and is validated by
  the shared `flow` conformance corpus. The blocking behaviour when credit runs
  out is an implementation concern layered on top (the Session); this is just the
  protocol arithmetic: how much output may be in flight and how `window_adjust`
  extends it.
  """

  @enforce_keys [:available]
  defstruct [:available]

  @type t :: %__MODULE__{available: integer()}

  def new(size) when is_integer(size), do: %__MODULE__{available: size}

  def available(%__MODULE__{available: a}), do: a

  @doc """
  Returns `{taken, window}`: the bytes that may be sent now toward a request for
  `want` — `min(want, available)`, never negative — and the window with that
  amount debited.
  """
  def take(%__MODULE__{available: avail} = w, want) when is_integer(want) do
    taken = want |> min(avail) |> max(0)
    {taken, %{w | available: avail - taken}}
  end

  @doc "Extend the window (a window_adjust arrived)."
  def grant(%__MODULE__{available: avail} = w, bytes) when is_integer(bytes) do
    %{w | available: avail + bytes}
  end
end
