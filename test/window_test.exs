defmodule Terminalwire.WindowTest do
  use ExUnit.Case, async: true

  alias Terminalwire.{Protocol, Window}

  @max Protocol.max_window()

  describe "new/1" do
    test "stores the offered size as available credit" do
      assert Window.available(Window.new(1024)) == 1024
    end

    test "a zero window starts with no credit" do
      assert Window.available(Window.new(0)) == 0
    end

    test "clamps an offer above the protocol ceiling to max_window" do
      assert Window.available(Window.new(@max + 1)) == @max
      assert Window.available(Window.new(@max * 10)) == @max
    end

    test "an offer at exactly the ceiling is kept" do
      assert Window.available(Window.new(@max)) == @max
    end
  end

  describe "take/2" do
    test "takes the full amount when credit covers it and debits the window" do
      {taken, w} = Window.take(Window.new(1000), 400)
      assert taken == 400
      assert Window.available(w) == 600
    end

    test "takes only what's available when the request exceeds credit" do
      {taken, w} = Window.take(Window.new(300), 1000)
      assert taken == 300
      assert Window.available(w) == 0
    end

    test "takes nothing from an empty window" do
      {taken, w} = Window.take(Window.new(0), 500)
      assert taken == 0
      assert Window.available(w) == 0
    end

    test "taking zero is a no-op" do
      {taken, w} = Window.take(Window.new(500), 0)
      assert taken == 0
      assert Window.available(w) == 500
    end

    test "a negative request never returns negative or grows the window" do
      {taken, w} = Window.take(Window.new(500), -100)
      assert taken == 0
      assert Window.available(w) == 500
    end

    test "successive takes drain the window exactly" do
      w = Window.new(100)
      {a, w} = Window.take(w, 60)
      {b, w} = Window.take(w, 60)
      {c, w} = Window.take(w, 60)
      assert {a, b, c} == {60, 40, 0}
      assert Window.available(w) == 0
    end
  end

  describe "grant/2" do
    test "extends available credit when a window_adjust arrives" do
      w = Window.new(100) |> Window.grant(250)
      assert Window.available(w) == 350
    end

    test "clamps the total to the protocol ceiling so a peer can't grow it unbounded" do
      w = Window.new(@max) |> Window.grant(1)
      assert Window.available(w) == @max
    end

    test "a single oversized grant is clamped to the ceiling" do
      w = Window.new(0) |> Window.grant(@max * 5)
      assert Window.available(w) == @max
    end

    test "granting zero leaves the window unchanged" do
      assert Window.available(Window.grant(Window.new(100), 0)) == 100
    end
  end

  describe "take/grant interplay" do
    test "a drained window refills on grant and can be taken from again" do
      w = Window.new(100)
      {100, w} = Window.take(w, 100)
      assert Window.available(w) == 0

      w = Window.grant(w, 50)
      {taken, w} = Window.take(w, 80)
      assert taken == 50
      assert Window.available(w) == 0
    end
  end
end
