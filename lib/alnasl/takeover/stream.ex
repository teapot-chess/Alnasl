defmodule Alnasl.Takeover.Stream do
  @moduledoc """
  What an active box streams to the cloud, and the queue it waits in.

  `game_saved/2` is told every change of a game (`Alnasl.Games` calls it
  after each save) and turns the difference into events:

  | kind | when | data |
  |---|---|---|
  | `start` | the first move of a game | `white`, `black`, `start_fen` |
  | `ply` | a move, numbered from 1 (`ply`) | `san`, `clock`, `at`, `flags` |
  | `truncate` | a correction or a restart took moves back | `keep`, `start_fen` |
  | `result` | the result, the suggestion or the state changed | `status`, `result`, `suggestion` |
  | `end` | the game was finished | `result` |

  Every event also says where the game is (`where`: tournament, round,
  board, game number), names the game (`game`: the box's uid and the
  game's id), and the board's serial when the box knows which board plays
  it. Corrections are later events, not rewritten ones: a ply number seen
  twice is the later one.

  ## The queue

  Written before anything is sent, in the box's own database on the data
  partition (`takeover_queue`), and deleted only when the cloud has
  acknowledged it. The row's id is the event's number for good, so a
  restart neither loses nor renumbers anything, and sending a batch twice
  is harmless: the cloud keeps one copy of each event id.

  It is bounded (`Alnasl.Takeover.queue_cap/0`, 50,000). At the cap the box
  stops queueing, says so on its status line and in the log, and when the
  line is back it sends its whole state once more instead: the games are
  in the box's database either way, and that state is what a box taking
  over starts from.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Alnasl.{Log, Repo, Takeover}
  alias Alnasl.Boards.Board
  alias Alnasl.Games.Game
  alias Alnasl.Takeover.Queued

  @kinds ~w(start ply truncate result end)

  def kinds, do: @kinds

  @doc """
  A game was saved: `before` as it was, `game` as it is now. Queues the
  events in between when this box is the active one, and does nothing
  otherwise. Never raises into the caller: a stream that cannot be written
  must not cost a move.
  """
  def game_saved(%Game{} = before, %Game{} = game) do
    case Takeover.config() do
      %{"uid" => uid} = config when is_binary(uid) ->
        if Takeover.phase(config) == :active do
          before |> events(game) |> enqueue(game, uid, config)
        end

      _unlinked ->
        :ok
    end

    :ok
  rescue
    error ->
      Logger.warning("takeover: an event was not queued: #{Exception.message(error)}")
      :ok
  end

  @doc false
  # The events between two versions of a game, without their common fields.
  def events(%Game{} = before, %Game{} = game) do
    old = decode(before.plies)
    new = decode(game.plies)
    keep = common(old, new, 0)
    restarted? = before.start_fen != game.start_fen
    cut? = keep < length(old) or restarted?

    start =
      if old == [] and new != [] and not cut?,
        do: [
          {"start", nil,
           %{"white" => game.white, "black" => game.black, "start_fen" => game.start_fen}}
        ],
        else: []

    truncate =
      if cut?, do: [{"truncate", nil, %{"keep" => keep, "start_fen" => game.start_fen}}], else: []

    plies =
      for {ply, n} <- new |> Enum.drop(keep) |> Enum.with_index(keep + 1) do
        {"ply", n, Map.take(ply, ["san", "clock", "at", "flags"])}
      end

    result =
      cond do
        before.status != "finished" and game.status == "finished" ->
          [{"end", nil, %{"result" => game.result}}]

        {before.status, before.result, before.suggestion} !=
            {game.status, game.result, game.suggestion} ->
          [
            {"result", nil,
             %{"status" => game.status, "result" => game.result, "suggestion" => game.suggestion}}
          ]

        true ->
          []
      end

    truncate ++ start ++ plies ++ result
  end

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _other -> []
    end
  end

  defp decode(_none), do: []

  defp common([%{"san" => san} | old], [%{"san" => san} | new], n), do: common(old, new, n + 1)
  defp common(_old, _new, n), do: n

  defp enqueue([], _game, _uid, _config), do: :ok

  defp enqueue(events, game, uid, config) do
    if Takeover.queued() + length(events) > Takeover.queue_cap() do
      full(config)
    else
      where = %{
        "t" => game.tournament_id,
        "r" => game.round,
        "b" => game.board_no,
        "n" => game.game_no
      }

      serial = serial(game)
      at = System.system_time(:millisecond)
      now = DateTime.utc_now(:second)
      key = game_key(uid, game)

      rows =
        for {kind, ply, data} <- events do
          %{
            kind: kind,
            game: key,
            serial: serial,
            ply: ply,
            at: at,
            data: Jason.encode!(Map.put(data, "where", where)),
            inserted_at: now
          }
        end

      Repo.insert_all(Queued, rows)
      # Offline, the status line counts what waits; online it is gone in a moment.
      if Takeover.offline?(), do: Takeover.notify(:queued)
      kick()
    end
  end

  # Said once, not once an event: the warning stays on the status line
  # until the whole state has gone up again.
  defp full(%{"overflow" => true}), do: :ok

  defp full(_config) do
    Takeover.update_config(&Map.put(&1, "overflow", true))

    Log.add(:warn, "takeover.queue_full", %{cap: Takeover.queue_cap()})

    Logger.warning(
      "takeover: the queue is full (#{Takeover.queue_cap()} events); " <>
        "the whole state goes up when the line is back"
    )
  end

  @doc "The game's name in the stream: this box's uid and the game's id here."
  def game_key(uid, %Game{id: id}), do: "#{uid}/#{id}"

  defp serial(%Game{tournament_id: t, round: r, board_no: b}) do
    Repo.one(
      from x in Board,
        where: x.tournament_id == ^t and x.round == ^r and x.board_no == ^b,
        where: not is_nil(x.serial),
        select: x.serial,
        limit: 1
    )
  end

  defp kick do
    if pid = Process.whereis(Alnasl.Takeover.Link), do: send(pid, :kick)
    :ok
  end

  # --- reading and acknowledging the queue -------------------------------------------

  @doc "The oldest `limit` events, as the cloud is sent them."
  def batch(uid, limit \\ 500) do
    for row <- Repo.all(from q in Queued, order_by: q.id, limit: ^limit) do
      %{
        "id" => event_id(uid, row.id),
        "seq" => row.id,
        "kind" => row.kind,
        "game" => row.game,
        "serial" => row.serial,
        "ply" => row.ply,
        "at" => row.at,
        "data" => Jason.decode!(row.data)
      }
    end
  end

  @doc "The event's id in the cloud."
  def event_id(uid, seq), do: "#{uid}-#{seq}"

  @doc "The cloud has everything up to `seq`: those are gone from the queue."
  def acked(seq) when is_integer(seq) do
    {n, _} = Repo.delete_all(from q in Queued, where: q.id <= ^seq)
    n
  end

  @doc "Empties the queue (the box left its hall)."
  def clear do
    Repo.delete_all(Queued)
    :ok
  end
end
