defmodule Alnasl.LiveChessMatch do
  @moduledoc """
  Which pairing a LiveChess game is. A bridge that reads a LiveChess
  export folder sends, with every game, who is playing it
  (`{:game, facts}`, `Arkab.LiveChess.facts/2`): names, FIDE IDs, the
  LiveChess round and game number, the result. Here those players are
  looked up among the pairings of the round in play of every tournament
  from OpenPairings placed in the board's hall, and the board takes the
  place of the one pairing they play.

  ## The same player

  By FIDE ID when both sides have one (and then only by it: two IDs that
  differ are two people, whatever their names). Otherwise by name, with
  case, accents and punctuation set aside and the words in any order:
  "Vermeulen, Wanda", "Wanda VERMEULEN" and "vermeulen wanda" are one
  player. A school event that keeps one name is still a name.

  A pairing fits a game when both its players are the game's two, in the
  same colours or reversed. Reversed is a fit, and said: somebody sat at
  the wrong side of the board, or LiveChess was told the other order.

  ## What happens

    * one pairing fits, nobody else's: the board plays it (the pairing's
      board number in its tournament, names and ratings from
      OpenPairings, as for a DGT board) - `:placed`;
    * none fits (`:none`), more than one does (`:ambiguous`), another
      LiveChess game fits the same one (`:claimed`, both games), or a
      board already plays it (`:taken`): the board is left where it is
      not, and the Boards page says why and offers the pairings to pick
      from, one click each (`choose/4`). A board put on a pairing that way
      stays there until its players change (`:manual`);
    * no tournament from OpenPairings in the hall (`:standalone`): there
      is nothing to match; the board shows the LiveChess names.

  It is asked again whenever the game's players change (the next round's
  game on the same board) and when a round starts or the pairings change
  (`again/0`). A board this module placed and that no longer fits is
  taken off the pairing; a board the arbiter linked by hand is not.

  The lookups of all boards run one at a time: two games that arrive in
  the same second must not each think a pairing is free.
  """

  require Logger

  alias Alnasl.{BoardServer, Boards, Log, Placements, Tournaments}
  alias Alnasl.Boards.Board

  # --- the same player ----------------------------------------------------------

  @doc "A name as words to compare: no case, no accents, no punctuation, in order."
  def words(name) when is_binary(name) do
    name
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.split()
    |> Enum.sort()
  end

  def words(_none), do: []

  @doc "Is the LiveChess player `a` the pairing's player `b`?"
  def same_player?(%{} = a, %{} = b) do
    case {a[:fide_id], b[:fide_id]} do
      {x, y} when is_integer(x) and is_integer(y) -> x == y
      _either_missing -> same_name?(a[:name], b[:name])
    end
  end

  def same_player?(_a, _b), do: false

  defp same_name?(a, b) do
    words = words(a)
    words != [] and words == words(b)
  end

  @doc """
  The pairings that fit the game's players: `[{pairing, :straight |
  :reversed}]`. Pure; the pairings are maps with `:white` and `:black`
  players as `Alnasl.Tournaments.round_players/2` gives them.
  """
  def judge(facts, pairings) do
    white = facts[:white]
    black = facts[:black]

    for p <- pairings, how = fit(white, black, p), do: {p, how}
  end

  defp fit(white, black, p) do
    cond do
      same_player?(white, p.white) and same_player?(black, p.black) -> :straight
      same_player?(white, p.black) and same_player?(black, p.white) -> :reversed
      true -> nil
    end
  end

  # Pairings with one of the two players in them: what a game whose other
  # name is misspelt is most likely to be.
  defp partial(facts, pairings) do
    players = Enum.reject([facts[:white], facts[:black]], &is_nil/1)

    Enum.filter(pairings, fn p ->
      Enum.any?(players, &(same_player?(&1, p.white) or same_player?(&1, p.black)))
    end)
  end

  @doc "What says which game it is: everything but the result."
  def key(facts) when is_map(facts), do: Map.take(facts, [:round, :game, :white, :black])
  def key(_none), do: nil

  # --- the hall's pairings -----------------------------------------------------

  defp linked_here(hall_id) do
    for t <- Tournaments.active(),
        t.kind == "linked",
        not t.gone,
        hall_id in Placements.halls_of(t),
        do: t
  end

  # The pairings of the round in play of every tournament placed here, of
  # the boards this hall plays.
  defp pairings_here(hall_id, tournaments) do
    for t <- tournaments,
        round = t.round || 1,
        placements = Placements.list(t),
        p <- Tournaments.round_players(t.id, round),
        Placements.board_here?(placements, p.board, hall_id),
        do: Map.merge(p, %{tid: t.id, round: round, title: Tournaments.title(t)})
  end

  defp target(p), do: {p.tid, p.round, p.board}

  defp candidate(p) do
    %{
      tid: p.tid,
      round: p.round,
      board: p.board,
      label: p.label,
      title: p.title,
      match: p.match,
      white: p.white && p.white.name,
      black: p.black && p.black.name
    }
  end

  # --- asking ------------------------------------------------------------------

  @doc "Asks for board `id` beside the caller: a board's process must not wait for it."
  def kick(id) do
    Task.Supervisor.start_child(Alnasl.TaskSupervisor, fn -> consider(id) end)
    :ok
  end

  @doc """
  Board `id` was linked to another game: in a hall without OpenPairings
  its LiveChess names go with it. Nothing else is asked - a board linked
  by hand stays where the arbiter put it.
  """
  def linked(id) do
    Task.Supervisor.start_child(Alnasl.TaskSupervisor, fn ->
      :global.trans({__MODULE__, self()}, fn -> name_standalone(id) end, [node()])
    end)

    :ok
  end

  defp name_standalone(id) do
    with %Board{} = board <- Boards.get(id),
         [] <- linked_here(board.hall_id),
         %{livechess: %{facts: _facts} = lc} <- Boards.snapshot(board) do
      apply_outcome(%{status: :standalone}, board, lc)
    end
  rescue
    error -> Logger.warning("livechess match: board #{id}: #{Exception.message(error)}")
  end

  @doc "Asks again for every LiveChess board: a round started, or the pairings changed."
  def again do
    Task.Supervisor.start_child(Alnasl.TaskSupervisor, fn ->
      try do
        for board <- Boards.list(), board.driver == "remote", do: consider(board.id)
      rescue
        error -> Logger.warning("livechess match: #{Exception.message(error)}")
      end
    end)

    :ok
  end

  @doc """
  Puts board `id` on the pairing its players fit, or says why not (see
  the moduledoc). Returns what it decided, `nil` for a board that is not
  a LiveChess board.
  """
  def consider(id) do
    :global.trans({__MODULE__, self()}, fn -> decide_and_apply(id) end, [node()])
  end

  defp decide_and_apply(id) do
    with %Board{} = board <- Boards.get(id),
         %{livechess: %{facts: facts} = lc} <- Boards.snapshot(board) do
      board |> decide(facts, lc) |> apply_outcome(board, lc)
    else
      _not_livechess -> nil
    end
  rescue
    error ->
      Logger.warning("livechess match: board #{id}: #{Exception.message(error)}")
      nil
  end

  defp manual?(%{match: %{status: :manual, key: key}, facts: facts}), do: key == key(facts)
  defp manual?(_lc), do: false

  defp decide(board, facts, lc) do
    hall = board.hall_id
    linked = linked_here(hall)

    cond do
      linked == [] ->
        %{status: :standalone}

      manual?(lc) ->
        :keep

      true ->
        pairings = pairings_here(hall, linked)
        decide_among(board, facts, pairings)
    end
  end

  defp decide_among(_board, _facts, []), do: %{status: :no_pairings}

  defp decide_among(board, facts, pairings) do
    case judge(facts, pairings) do
      [{p, how}] ->
        cond do
          rival = rival(board, p, pairings) ->
            # Both games are someone's mistake: neither gets the pairing.
            claimed = %{status: :claimed, other: board.name, candidates: [candidate(p)]}
            apply_outcome(claimed, rival.board, rival.lc)
            %{status: :claimed, other: rival.board.name, candidates: [candidate(p)]}

          holder = holder(board, p) ->
            %{status: :taken, other: holder.name, candidates: [candidate(p)]}

          true ->
            %{status: :placed, target: target(p), reversed?: how == :reversed, title: p.title}
        end

      [] ->
        partial = partial(facts, pairings)
        free = Enum.reject(pairings, &holder(board, &1))

        %{
          status: :none,
          candidates: Enum.map(if(partial == [], do: free, else: partial), &candidate/1)
        }

      many ->
        %{status: :ambiguous, candidates: Enum.map(many, fn {p, _how} -> candidate(p) end)}
    end
  end

  # Another LiveChess board of the hall whose players fit the same pairing.
  defp rival(board, p, pairings) do
    Enum.find_value(Boards.list(), fn other ->
      with true <- other.id != board.id and other.driver == "remote",
           true <- other.hall_id == board.hall_id,
           %{livechess: %{facts: facts} = lc} <- Boards.snapshot(other),
           [{q, _how}] <- judge(facts, pairings),
           true <- target(q) == target(p) do
        %{board: other, lc: lc}
      else
        _no -> nil
      end
    end)
  end

  # The board that plays the pairing now, if it is another.
  defp holder(board, p) do
    Enum.find(Boards.list(), fn other ->
      other.id != board.id and other.tournament_id == p.tid and other.round == p.round and
        other.board_no == p.board
    end)
  end

  defp apply_outcome(:keep, _board, lc), do: lc.match

  defp apply_outcome(%{status: :placed, target: {tid, round, no}} = outcome, board, lc) do
    before = lc[:match]

    if {board.tournament_id, board.round, board.board_no} != {tid, round, no} do
      Boards.update(board, %{tournament_id: tid, round: round, board_no: no})

      Log.add(
        :info,
        "livechess.placed",
        %{name: board.name, board: no, tournament: outcome.title || ""},
        %{board_id: board.id, round: round, board_no: no}
      )
    end

    if outcome.reversed? and not match?(%{status: :placed, reversed?: true}, before) do
      Log.add(:warn, "livechess.reversed", %{name: board.name, board: no}, %{
        board_id: board.id,
        round: round,
        board_no: no
      })
    end

    outcome = outcome |> Map.put(:placed, {tid, round, no}) |> Map.delete(:title)
    store(board, outcome)
  end

  # Without OpenPairings the box's own tournament has no names but the
  # ones somebody types - or LiveChess's: a board linked there gets them,
  # unless somebody typed some already.
  defp apply_outcome(%{status: :standalone} = outcome, board, lc) do
    with true <- is_integer(board.round) and is_integer(board.board_no),
         %{kind: "local"} = tournament <- Tournaments.get(board.tournament_id),
         nil <- Tournaments.board(tournament.id, board.round, board.board_no),
         white = player_name(lc.facts[:white]),
         black = player_name(lc.facts[:black]),
         true <- white != nil or black != nil,
         {:ok, _tournament} <-
           Tournaments.set_names(tournament, board.round, board.board_no, white, black) do
      if game = Alnasl.Games.current(tournament.id, board.round, board.board_no) do
        game |> Ecto.Changeset.change(%{white: white, black: black}) |> Alnasl.Repo.update!()
      end

      Boards.refresh_games(tournament.id)
    end

    store(board, outcome)
  end

  defp apply_outcome(outcome, board, lc) do
    before = lc[:match]

    # Taken off a pairing it was put on by this module - or off the same
    # board number of the next round, where starting a round carries every
    # board; one the arbiter linked by hand stays.
    case before do
      %{placed: {tid, _round, no}}
      when tid == board.tournament_id and no == board.board_no and board.round != nil ->
        Boards.update(board, %{round: nil, board_no: nil})

      _other ->
        :ok
    end

    if (before || %{})[:status] != outcome.status do
      Log.add(:warn, "livechess.unplaced", %{name: board.name, why: to_string(outcome.status)}, %{
        board_id: board.id
      })
    end

    store(board, outcome)
  end

  defp player_name(%{name: name}) when is_binary(name), do: name
  defp player_name(_none), do: nil

  defp store(board, outcome) do
    GenServer.call(BoardServer.via(board.id), {:livechess_match, outcome})
    outcome
  catch
    :exit, _gone -> outcome
  end

  # --- the arbiter's click ------------------------------------------------------

  @doc """
  The arbiter puts LiveChess board `id` on board `no` of `round` of
  tournament `tid`. A board that played it lets go (`Alnasl.Boards.link/3`).
  `:ok`, or `{:error, :no_pairing}` when the round has no such board.
  """
  def choose(id, tid, round, no) do
    :global.trans({__MODULE__, self()}, fn -> do_choose(id, tid, round, no) end, [node()])
  end

  defp do_choose(id, tid, round, no) do
    with %Board{} = board <- Boards.get(id),
         %{livechess: %{facts: facts}} <- Boards.snapshot(board),
         %{} = p <- Enum.find(Tournaments.round_players(tid, round), &(&1.board == no)) do
      {:ok, board} = Boards.update(board, %{tournament_id: tid})
      Boards.link(board, round, no)

      Log.add(:info, "livechess.chosen", %{name: board.name, board: no}, %{
        board_id: board.id,
        round: round,
        board_no: no
      })

      how = fit(facts[:white], facts[:black], p)

      store(board, %{
        status: :manual,
        key: key(facts),
        placed: {tid, round, no},
        reversed?: how == :reversed
      })

      :ok
    else
      _none -> {:error, :no_pairing}
    end
  end

  @doc "Forgets the arbiter's pick for board `id` and looks again."
  def rematch(id) do
    with %Board{} = board <- Boards.get(id) do
      # Where the pick put it counts as placed here: a board that fits
      # nothing comes off it.
      store(board, %{status: :pending, placed: {board.tournament_id, board.round, board.board_no}})
    end

    consider(id)
  end
end
