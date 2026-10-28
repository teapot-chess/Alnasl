defmodule Alnasl.BoardHistoryTest do
  @moduledoc """
  A board's memory held up against the game the box has: what is added,
  what is offered to the arbiter instead, and what is left alone. The
  memories are written here the way a DGT board writes them (Arkab's
  `Arkab.Dgt.Bus.history/1` gives these events), plus the real one of
  2026-10-12.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{BoardHistory, BoardMemory, Chess}

  defp memory(sans, fen \\ Chess.start_fen()), do: BoardMemory.moves(sans, fen)
  defp scan(fen), do: BoardMemory.scan(fen)

  def plies(sans), do: Enum.map(sans, &%{san: &1, flags: [], clock: nil})

  defp merge(events, known, opts \\ []),
    do: BoardHistory.merge(events, Keyword.merge([plies: plies(known)], opts))

  defp sans({:extend, plies}), do: Enum.map(plies, & &1.san)

  @opening ~w(e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7)

  describe "from the starting position" do
    test "a memory with more moves than the box adds the rest, marked and with their clocks" do
      events = [:start_mark, :start_position | memory(@opening)]
      assert {:extend, plies} = merge(events, Enum.take(@opening, 4))
      assert Enum.map(plies, & &1.san) == Enum.drop(@opening, 4)
      assert Enum.all?(plies, &(:memory in &1.flags))
      # The castle is found as a castle, not as a king walking two squares.
      assert List.last(Enum.drop(plies, 3)).san == "Be7"
      assert Enum.at(plies, 4).san == "O-O"
      assert %{white_ms: 5_391_000, black_ms: 5_392_000} = Enum.at(plies, 4).clock
    end

    test "a game the box has from move one is recovered whole" do
      events = [:start_mark, :start_position | memory(@opening)]
      assert {:extend, plies} = merge(events, [])
      assert Enum.map(plies, & &1.san) == @opening
    end

    test "the same moves: nothing" do
      events = [:start_mark, :start_position | memory(@opening)]
      assert merge(events, @opening) == :nothing
    end

    test "fewer moves than the box has: nothing" do
      events = [:start_mark, :start_position | memory(Enum.take(@opening, 3))]
      assert merge(events, @opening) == :nothing
    end

    test "other moves: a draft, the box's game left as it is" do
      events = [:start_mark, :start_position | memory(~w(e4 e5 Nf3 Nf6 Nxe5 d6))]

      assert {:draft, :conflict, %{from_ply: 3, plies: plies, start_fen: fen}} =
               merge(events, ~w(e4 e5 Nf3 Nc6))

      assert fen == Chess.start_fen()
      assert Enum.map(plies, & &1.san) == ~w(e4 e5 Nf3 Nf6 Nxe5 d6)
    end

    test "merged, then merged again: the second time there is nothing to do" do
      events = [:start_mark, :start_position | memory(@opening)]
      {:extend, added} = merge(events, Enum.take(@opening, 2))
      known = Enum.take(@opening, 2) ++ Enum.map(added, & &1.san)
      assert known == @opening
      assert merge(events, known) == :nothing
    end

    test "the newest game is the one compared; an older one is not taken for it" do
      old = memory(~w(d4 d5 c4 e6))
      events = [:start_mark, :start_position | old] ++ [:start_position | memory(@opening)]
      assert sans(merge(events, ~w(e4 e5))) == Enum.drop(@opening, 2)
    end

    test "an older game that fits as well: not clear which, a draft" do
      events =
        [:start_mark, :start_position | memory(~w(e4 e5 Nf3 Nc6 Bc4))] ++
          [:start_position | memory(@opening)]

      assert {:draft, :ambiguous, %{from_ply: 4}} = merge(events, ~w(e4 e5 Nf3 Nc6))
    end

    test "the pieces set up again since: an older game that goes on is only offered" do
      events =
        [:start_mark, :start_position | memory(@opening)] ++
          [:start_position | memory(~w(e4))]

      assert {:draft, :earlier_game, %{from_ply: 4, plies: plies}} =
               merge(events, Enum.take(@opening, 4))

      assert Enum.map(plies, & &1.san) == @opening
    end

    test "a board plugged in turned round is read turned round" do
      raw =
        [:start_mark, :start_position_rotated | memory(@opening)]
        |> Enum.map(fn
          {:field, sq, piece} -> {:field, 63 - sq, piece}
          other -> other
        end)

      assert sans(merge(raw, ~w(e4), flipped?: true)) == Enum.drop(@opening, 1)
    end
  end

  describe "from where the box stands" do
    @fen "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3"

    test "a game set up from a position: the memory takes over where the box stands" do
      events = [:start_mark | memory(~w(Bb5 a6 Ba4), @fen)]
      # Nothing told the board where the pieces stood: a power-up does.
      events = [:power_up | scan(@fen)] ++ events

      assert sans(merge(events, ~w(Bb5), start_fen: @fen)) == ~w(a6 Ba4)
    end

    test "a memory that went round and lost the start: from the box's last position" do
      full = memory(@opening)
      # Only the second half is still in the memory, after a power-up at the
      # position after move four.
      {:ok, pos} = Chess.replay(Chess.start_fen(), Enum.take(@opening, 4))
      fen4 = List.last(pos).fen
      events = [:power_up | scan(fen4)] ++ drop_moves(full, 4)

      assert sans(merge(events, Enum.take(@opening, 6))) == Enum.drop(@opening, 6)
    end

    test "no position the box knows, no starting position: unmatched" do
      events = [:power_up | scan("8/8/8/4k3/8/8/8/4K3 w - - 0 1")]
      assert {:unmatched, _why} = merge(events, ~w(e4))
    end

    test "the start unknown to the box: what the board played is offered" do
      fen = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"
      events = [:start_mark, :start_position | memory(~w(e4 e5))]
      assert {:draft, :unknown_start, %{plies: plies}} = merge(events, ~w(e4), start_fen: fen)
      assert Enum.map(plies, & &1.san) == ~w(e4 e5)
    end
  end

  describe "memories that are not what they should be" do
    test "nothing, or only marks: nothing" do
      assert {:unmatched, _} = merge([], ~w(e4))
      assert {:unmatched, _} = merge([:start_mark, :end_of_data], ~w(e4))
      assert {:unmatched, :not_a_history} = BoardHistory.merge(:garbage, plies: [])
    end

    test "garbage never crashes it" do
      :rand.seed(:exsss, {10, 28, 26})

      for _ <- 1..60 do
        events =
          for _ <- 1..:rand.uniform(200) do
            case :rand.uniform(4) do
              1 -> {:field, :rand.uniform(64) - 1, Enum.random([nil, {:w, :p}, {:b, :q}])}
              2 -> {:clock, Enum.random([:white, :black]), :rand.uniform(9_000_000)}
              3 -> Enum.random([:power_up, :start_position, :restarted, :empty_board])
              4 -> Enum.random([{:field, 99, nil}, {:clock, :green, -1}, "x", nil])
            end
          end

        assert merge(events, ~w(e4 e5)) |> valid?()
      end
    end
  end

  defp valid?(:nothing), do: true
  defp valid?({:extend, plies}) when is_list(plies), do: true
  defp valid?({:draft, _reason, %{plies: plies}}) when is_list(plies), do: true
  defp valid?({:unmatched, _why}), do: true
  defp valid?(_other), do: false

  # The memory after its first `n` moves: everything after the n-th clock time.
  defp drop_moves(events, n) do
    events
    |> Enum.reduce({n, []}, fn
      event, {0, acc} -> {0, [event | acc]}
      {:clock, _, _}, {k, acc} -> {k - 1, acc}
      _event, {k, acc} -> {k, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  describe "the real memories of 2026-10-12" do
    # `Arkab.Dgt.Bus.changes/1` reads the memory as `history/1` does, less
    # the marks this capture does not have.
    defp real(address) do
      bytes =
        "test/fixtures/captures/real-loop-06-ignore-ping-all-d.jsonl"
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.flat_map(fn
          %{"k" => "rx", "h" => hex} -> [Base.decode16!(hex, case: :lower)]
          _other -> []
        end)
        |> IO.iodata_to_binary()

      {answers, _rest} = Arkab.Dgt.Bus.parse(bytes)
      [data] = for {^address, {:from_start, data}} <- answers, do: data
      Arkab.Dgt.Bus.changes(data)
    end

    test "12799's game comes back whole, 80 plies, and is legal" do
      assert {:extend, plies} = merge(real(12_799), [])
      sans = Enum.map(plies, & &1.san)
      assert length(sans) == 80
      assert Enum.take(sans, 4) == ~w(e4 c5 Nf3 d6)
      assert {:ok, _played} = Chess.replay(Chess.start_fen(), sans)
      assert Enum.count(plies, & &1.clock) > 70

      # Half of it known: the other half is added. All of it: nothing.
      assert sans(merge(real(12_799), Enum.take(sans, 40))) == Enum.drop(sans, 40)
      assert merge(real(12_799), sans) == :nothing
    end

    test "6310's six games and two power-ups: the newest game is the one read" do
      assert sans(merge(real(6310), [])) == ~w(d4 d5)
      assert merge(real(6310), ~w(d4 d5)) == :nothing
    end
  end
end
