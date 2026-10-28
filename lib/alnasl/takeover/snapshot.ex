defmodule Alnasl.Takeover.Snapshot do
  @moduledoc """
  The box's state, as the active box sends it to the cloud and a box taking
  over starts from (`Alnasl.Takeover.Restore`): what is needed to go on
  with the hall, and nothing that is a secret.

  * `tournaments` - every one not gone: names, the round on the boards, the
    pairings document. **Not** the relay key, the Lichess token or the
    connect code's secret: those stay on the box that was given them. A box
    that takes over a linked tournament needs its own connect code to send
    results to the pairing program (docs/takeover.md).
  * `placements` - which tables of the hall play which tournament.
  * `boards` - the hall's own boards (not a bridge's), by serial: the table
    number, the tournament, round and board each one is linked to, flipped.
  * `games` - every game of each tournament's current round, and every game
    still live: the moves with their clocks, the players, the result.
  * `settings` - the few that change how the boards are read.

  Games are named as the stream names them (`Alnasl.Takeover.Stream`), so
  the events after a state can be folded into it.
  """

  import Ecto.Query, only: [from: 2]

  alias Alnasl.{Boards, Halls, Repo, Settings, Tournaments}
  alias Alnasl.Games.Game
  alias Alnasl.Takeover.Stream
  alias Alnasl.Tournaments.Placement

  @version 1
  @settings ~w(tracker clock_heartbeat_s new_game_on_setup auto_suggest)

  @tournament_fields ~w(id kind remote_id name label state version document document_at
                        round remote_round auto_start keep_matches server_url slug gone)a
  @board_fields ~w(id name driver port address options flipped enabled tournament_id round
                   board_no table_no serial firmware)a
  @game_fields ~w(tournament_id round board_no game_no white black start_fen plies status
                  result suggestion paused source clock seq remote_game remote_white
                  remote_black pairing_flag local finished_at)a

  def version, do: @version
  def settings, do: @settings

  @doc "The state of this box, for the box `uid`."
  def build(uid) do
    own = Halls.own_id()
    default = Tournaments.default_id()
    tournaments = Enum.reject(Tournaments.list(), & &1.gone)
    ids = Enum.map(tournaments, & &1.id)

    %{
      "v" => @version,
      "box" => uid,
      "own_tournament" => default,
      "tournaments" => Enum.map(tournaments, &take(&1, @tournament_fields)),
      "placements" =>
        Repo.all(
          from p in Placement,
            where: p.tournament_id in ^ids and p.hall_id == ^own,
            order_by: p.id
        )
        |> Enum.map(&take(&1, ~w(tournament_id table_from table_to first_board)a)),
      "boards" =>
        for(
          b <- Boards.list(),
          b.driver != "remote",
          Halls.of(b) == own,
          do: take(b, @board_fields)
        ),
      "games" => games(tournaments, uid),
      "settings" => Settings.get_many(@settings)
    }
  end

  defp games(tournaments, uid) do
    rounds = Map.new(tournaments, &{&1.id, &1.round || 1})
    ids = Map.keys(rounds)

    Repo.all(from g in Game, where: g.tournament_id in ^ids, order_by: g.id)
    |> Enum.filter(&(&1.status == "live" or &1.round == rounds[&1.tournament_id]))
    |> Enum.map(fn game ->
      game
      |> take(@game_fields)
      |> Map.put("key", Stream.game_key(uid, game))
    end)
  end

  defp take(struct, fields) do
    Map.new(fields, fn field ->
      value =
        case Map.fetch!(struct, field) do
          %DateTime{} = at -> DateTime.to_iso8601(at)
          other -> other
        end

      {Atom.to_string(field), value}
    end)
  end

  @doc "A short fingerprint, to send a state only when it changed."
  def digest(state),
    do: :crypto.hash(:sha256, Jason.encode!(state)) |> Base.encode16(case: :lower)
end
