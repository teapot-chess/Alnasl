defmodule Alnasl.MemoryDrafts do
  @moduledoc """
  Games out of a board's memory that the box would not take by itself
  (`Alnasl.BoardHistory`): kept beside the game, shown to the arbiter on the
  game page, and accepted or dismissed there. Nothing here changes a game;
  accepting is the board's process playing the draft into it
  (`Alnasl.BoardServer`).

  A memory is read every time its board comes back, so the same draft is
  offered again and again: it is one row, keyed by the game and what it
  says. One dismissed stays dismissed; a different one is a new draft.
  """

  import Ecto.Query

  alias Alnasl.MemoryDrafts.Draft
  alias Alnasl.Repo

  @doc """
  Keeps a draft for `game_id`. `{:new, draft}` the first time,
  `{:known, draft}` when the same one is there already (in any status).
  """
  def offer(game_id, serial, reason, %{start_fen: fen, from_ply: from, plies: plies})
      when is_integer(game_id) do
    stored = encode(plies)
    reason = Atom.to_string(reason)
    digest = digest(fen, stored)

    case Repo.get_by(Draft, game_id: game_id, digest: digest) do
      %Draft{} = known ->
        {:known, known}

      nil ->
        %Draft{
          game_id: game_id,
          board_serial: serial,
          reason: reason,
          start_fen: fen,
          from_ply: from,
          plies: Jason.encode!(stored),
          digest: digest
        }
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:game_id, :digest])
        |> case do
          {:ok, %Draft{id: nil}} ->
            {:known, Repo.get_by!(Draft, game_id: game_id, digest: digest)}

          {:ok, draft} ->
            {:new, draft}
        end
    end
  end

  @doc "The draft waiting for the arbiter on `game_id`, the newest; `nil` when none is."
  def pending(game_id) when is_integer(game_id) do
    Draft
    |> where([d], d.game_id == ^game_id and d.status == "pending")
    |> order_by([d], desc: d.id)
    |> limit(1)
    |> Repo.one()
  end

  def pending(_no_game), do: nil

  @doc "The game ids that have a draft waiting, of those given."
  def pending_games(game_ids) do
    Draft
    |> where([d], d.game_id in ^game_ids and d.status == "pending")
    |> select([d], d.game_id)
    |> distinct(true)
    |> Repo.all()
    |> MapSet.new()
  end

  def get(id), do: Repo.get(Draft, id)

  @doc "Marks a draft `\"accepted\"` or `\"dismissed\"`."
  def settle(%Draft{} = draft, status) when status in ["accepted", "dismissed"] do
    draft |> Ecto.Changeset.change(status: status) |> Repo.update!()
  end

  @doc "The plies of a draft, as the tracker and `Alnasl.Games` take them."
  def plies(%Draft{plies: json}) do
    json
    |> Jason.decode!()
    |> Enum.map(fn ply ->
      %{
        san: ply["san"],
        flags: flags(ply["flags"]),
        clock:
          case ply["clock"] do
            %{} = clock -> %{white_ms: clock["white_ms"], black_ms: clock["black_ms"]}
            _none -> nil
          end
      }
    end)
  end

  @doc "A summary for the pages: `%{id, reason, from_ply, total, moves}`, `moves` the SANs after the game's own."
  def summary(nil), do: nil

  def summary(%Draft{} = draft) do
    sans = draft |> plies() |> Enum.map(& &1.san)

    %{
      id: draft.id,
      reason: draft.reason,
      from_ply: draft.from_ply,
      total: length(sans),
      start_fen: draft.start_fen,
      moves: Enum.drop(sans, draft.from_ply)
    }
  end

  # Only flags the games know: a draft's plies end up in one.
  defp flags(list) when is_list(list) do
    for flag <- list,
        flag in ~w(memory guessed rewritten assumed unseen recovered),
        do: String.to_existing_atom(flag)
  end

  defp flags(_none), do: []

  defp encode(plies) do
    Enum.map(plies, fn ply ->
      %{
        "san" => ply.san,
        "flags" => Enum.map(ply[:flags] || [], &Atom.to_string/1),
        "clock" => ply[:clock]
      }
    end)
  end

  defp digest(fen, stored) do
    sans = Enum.map(stored, & &1["san"])
    :crypto.hash(:sha256, [fen, 0, Enum.intersperse(sans, " ")]) |> Base.encode16(case: :lower)
  end
end
