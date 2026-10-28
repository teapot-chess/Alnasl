defmodule Alnasl.Takeover.Restore do
  @moduledoc """
  A box that takes over a hall writes what the cloud had into its own
  database: the last state the active box sent (`Alnasl.Takeover.Snapshot`)
  with the events after it folded in (`Alnasl.Takeover.Stream`).

  Everything is matched, not copied by id - the ids were the other box's:

  * the other box's own tournament is this box's own tournament; a linked
    one is the one here with the same id in the pairing program and the
    same name, or a new linked row without a connect code;
  * a game is the one here at the same tournament, round, board and game
    number, or a new one;
  * a board is the row here with the same serial. A serial this box has no
    row for gets one on the other box's port and address, with its table
    number and its game, waiting: when that board answers here, on any
    port, it is recognised by its serial (`Alnasl.Tables.recognise/4`) and
    the row comes to it. A row whose port and address are taken here is
    not made; the board is numbered again when it turns up.

  One transaction: a takeover that fails half way leaves this box as it
  was, and says why.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Alnasl.{Halls, Repo, Settings, Tournaments}
  alias Alnasl.Boards.Board
  alias Alnasl.Games.Game
  alias Alnasl.Tournaments.{Placement, Tournament}

  @doc """
  Applies `state` (a map, or `nil` when the cloud has none) and `events`.
  `{:ok, %{games, boards, tournaments}}` - counts, and the serials of the
  boards restored, for whatever runs after a takeover - or `{:error, why}`.
  """
  def apply(state, events) do
    state = state || %{}

    Repo.transaction(fn ->
      tmap = tournaments(state)
      games = state |> Map.get("games", []) |> fold(events, state)
      written = write_games(games, tmap)
      boards = write_boards(Map.get(state, "boards", []), tmap)
      placements(Map.get(state, "placements", []), tmap)
      settings(Map.get(state, "settings", %{}))

      for {_from, id} <- tmap, do: Tournaments.notify(id)

      %{games: written, boards: boards, tournaments: map_size(tmap)}
    end)
  rescue
    error ->
      Logger.error("takeover: restoring failed: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end

  # --- tournaments -------------------------------------------------------------------

  @fields Map.new(
            ~w(name label state version document round remote_round auto_start keep_matches
               server_url slug)a,
            &{Atom.to_string(&1), &1}
          )

  # The other box's tournament ids to this box's.
  defp tournaments(state) do
    own = state["own_tournament"]

    for t <- Map.get(state, "tournaments", []), is_map(t), into: %{} do
      local = if t["id"] == own, do: Tournaments.default(), else: match(t)

      changes =
        for {field, atom} <- @fields, Map.has_key?(t, field), into: %{} do
          {atom, t[field]}
        end
        |> Map.put(:document_at, at(t["document_at"]))
        |> Map.update(:server_url, "", &(&1 || ""))
        |> Map.update(:slug, "", &(&1 || ""))
        |> Map.update(:round, local.round, &(&1 || local.round))

      updated = local |> Ecto.Changeset.change(changes) |> Repo.update!()
      {t["id"], updated.id}
    end
  end

  defp match(%{"kind" => "linked", "remote_id" => remote_id} = t) when is_integer(remote_id) do
    Repo.one(
      from x in Tournament,
        where: x.kind == "linked" and x.remote_id == ^t["remote_id"] and x.name == ^t["name"],
        order_by: x.id,
        limit: 1
    ) ||
      Repo.insert!(%Tournament{
        kind: "linked",
        remote_id: t["remote_id"],
        name: t["name"],
        hall_id: Halls.own_id()
      })
  end

  defp match(%{"kind" => "linked"} = t),
    do: Repo.insert!(%Tournament{kind: "linked", name: t["name"], hall_id: Halls.own_id()})

  defp match(t) do
    name = t["name"] || ""

    Repo.one(
      from x in Tournament,
        where: x.kind == "local" and x.name == ^name and x.hall_id == ^Halls.own_id(),
        order_by: x.id,
        limit: 1
    ) || Repo.insert!(%Tournament{kind: "local", name: t["name"], hall_id: Halls.own_id()})
  end

  # --- games -------------------------------------------------------------------------

  @doc false
  # The state's games with the events folded in, by the stream's key.
  def fold(games, events, state \\ %{}) do
    base = for g <- games, is_map(g), is_binary(g["key"]), into: %{}, do: {g["key"], g}
    Enum.reduce(events, base, &event(&1, &2, state))
  end

  defp event(%{"game" => key, "kind" => kind} = event, games, _state) when is_binary(key) do
    data = event["data"] || %{}

    game =
      Map.get_lazy(games, key, fn ->
        where = data["where"] || %{}

        %{
          "key" => key,
          "tournament_id" => where["t"],
          "round" => where["r"],
          "board_no" => where["b"],
          "game_no" => where["n"] || 1,
          "plies" => "[]",
          "status" => "live"
        }
      end)

    Map.put(games, key, apply_event(kind, event["ply"], data, game))
  end

  defp event(_event, games, _state), do: games

  defp apply_event("start", _ply, data, game) do
    game
    |> Map.put("white", game["white"] || data["white"])
    |> Map.put("black", game["black"] || data["black"])
    |> Map.put("start_fen", data["start_fen"] || game["start_fen"])
  end

  defp apply_event("ply", n, data, game) when is_integer(n) and n > 0 do
    plies = plies(game)
    ply = Map.take(data, ["san", "clock", "at", "flags"])

    plies =
      if length(plies) >= n,
        do: List.replace_at(plies, n - 1, ply) |> Enum.take(n),
        else: plies ++ [ply]

    Map.put(game, "plies", Jason.encode!(plies))
  end

  defp apply_event("truncate", _ply, data, game) do
    keep = if is_integer(data["keep"]), do: max(data["keep"], 0), else: 0

    game
    |> Map.put("plies", Jason.encode!(Enum.take(plies(game), keep)))
    |> Map.put("start_fen", data["start_fen"])
  end

  defp apply_event("end", _ply, data, game) do
    game
    |> Map.put("status", "finished")
    |> Map.put("result", data["result"])
    |> Map.put("suggestion", nil)
    |> Map.put(
      "finished_at",
      game["finished_at"] || DateTime.to_iso8601(DateTime.utc_now(:second))
    )
  end

  defp apply_event("result", _ply, data, game) do
    status = if data["status"] in ~w(live finished), do: data["status"], else: game["status"]

    game
    |> Map.put("status", status)
    |> Map.put("result", data["result"])
    |> Map.put("suggestion", data["suggestion"])
    |> Map.put("finished_at", if(status == "finished", do: game["finished_at"]))
  end

  defp apply_event(_kind, _ply, _data, game), do: game

  defp plies(game) do
    case Jason.decode(game["plies"] || "[]") do
      {:ok, list} when is_list(list) -> list
      _other -> []
    end
  end

  @game_fields Map.new(
                 ~w(white black start_fen plies status result suggestion paused source clock seq
                    remote_game remote_white remote_black pairing_flag local)a,
                 &{Atom.to_string(&1), &1}
               )

  defp write_games(games, tmap) do
    for {_key, g} <- games,
        tid = tmap[g["tournament_id"]],
        is_integer(tid) and is_integer(g["round"]) and is_integer(g["board_no"]),
        reduce: 0 do
      n ->
        number = g["game_no"] || 1

        changes =
          for {field, atom} <- @game_fields, Map.has_key?(g, field), into: %{} do
            {atom, g[field]}
          end
          |> Map.put(:finished_at, at(g["finished_at"]))
          |> Map.update(:status, "live", &(&1 || "live"))
          |> Map.update(:plies, "[]", &(&1 || "[]"))

        game =
          Repo.get_by(Game,
            tournament_id: tid,
            round: g["round"],
            board_no: g["board_no"],
            game_no: number
          ) ||
            %Game{tournament_id: tid, round: g["round"], board_no: g["board_no"], game_no: number}

        game |> Ecto.Changeset.change(changes) |> Repo.insert_or_update!()
        n + 1
    end
  end

  # --- boards ------------------------------------------------------------------------

  @dgt ~w(dgt_serial dgt_bus)

  defp write_boards(boards, tmap) do
    own = Halls.own_id()
    rows = Repo.all(from b in Board, where: b.driver != "remote")

    for b <- boards, is_map(b), is_binary(b["serial"]), b["serial"] != "", reduce: [] do
      done ->
        place = %{
          tournament_id: tmap[b["tournament_id"]],
          round: b["round"],
          board_no: b["board_no"],
          table_no: b["table_no"],
          flipped: b["flipped"] == true
        }

        case Enum.find(rows, &(&1.serial == b["serial"] and Halls.of(&1) == own)) do
          %Board{} = row ->
            row |> Ecto.Changeset.change(place) |> Repo.update!()
            [b["serial"] | done]

          nil ->
            if b["driver"] in @dgt and free?(rows, b["port"], b["address"]) do
              %Board{
                name: b["name"] || "Board",
                driver: b["driver"],
                port: b["port"],
                address: b["address"],
                options: b["options"],
                serial: b["serial"],
                firmware: b["firmware"],
                enabled: true,
                hall_id: own
              }
              |> Ecto.Changeset.change(place)
              |> Repo.insert!()

              [b["serial"] | done]
            else
              done
            end
        end
    end
    |> Enum.reverse()
  end

  defp free?(rows, port, address),
    do: is_binary(port) and not Enum.any?(rows, &(&1.port == port and &1.address == address))

  # --- placements and settings -----------------------------------------------------

  defp placements(placements, tmap) do
    own = Halls.own_id()
    ids = for {_from, id} <- tmap, do: id
    Repo.delete_all(from p in Placement, where: p.tournament_id in ^ids and p.hall_id == ^own)

    for p <- placements, is_map(p), tid = tmap[p["tournament_id"]], is_integer(tid) do
      Repo.insert!(%Placement{
        tournament_id: tid,
        hall_id: own,
        table_from: p["table_from"],
        table_to: p["table_to"],
        first_board: p["first_board"] || 1
      })
    end

    :ok
  end

  defp settings(%{} = settings) do
    for key <- Alnasl.Takeover.Snapshot.settings(), Map.has_key?(settings, key) do
      Settings.put(key, settings[key])
    end

    :ok
  end

  defp settings(_other), do: :ok

  defp at(nil), do: nil

  defp at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      _bad -> nil
    end
  end

  defp at(_other), do: nil
end
