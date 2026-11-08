defmodule Alnasl.OpenPairings.TablesReporter do
  @moduledoc """
  Tells each pairing program what the boards of its tournaments show now
  (board link revision 2, `POST /tournaments/:id/tables`): the arbiter sees
  them in OpenPairings and in Manubrium, the phone app, and steers them
  from there (`Alnasl.OpenPairings.Commands`).

  Per linked tournament, the whole list of the boards the box gave it,
  every time (`tables/1`). Sent when something changed - coalesced to one
  request every two seconds at most per tournament - and every thirty
  seconds whatever happened: that heartbeat is how the arbiter sees the box
  is alive. A clock that merely ran down is not a change; the heartbeat
  carries it, and the phone counts down from it.

  Asleep on a box with no linked tournament, and for a pairing program from
  before revision 2 (`Alnasl.OpenPairings.controls?/1`), which is never
  sent any. Everything that talks to a board or the network runs in a task,
  one at a time, so a board or a line that hangs holds up nothing else.
  """

  use GenServer

  alias Alnasl.{Boards, Chess, Games, OpenPairings, Position, Repo, Tournaments}
  alias Alnasl.OpenPairings.Client

  @tick 1_000
  @gap 2_000
  @heartbeat 30_000
  # After a failure, tried again this long after - not every two seconds.
  @retry 10_000
  @max_tables 256

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Sends every linked tournament's tables now (tests, and \"now\"). Returns when done."
  def report_now(server \\ __MODULE__), do: GenServer.call(server, :report_now, 60_000)

  @impl true
  def init(opts) do
    Boards.subscribe()
    if Keyword.get(opts, :tick, true), do: Process.send_after(self(), :tick, @tick)
    # `sent`: tournament id => {monotonic ms, signature | nil}; `dirty`:
    # something changed since (`:all`, or nothing).
    {:ok,
     %{task: nil, sent: %{}, dirty: false, waiting: [], tick?: Keyword.get(opts, :tick, true)}}
  end

  @impl true
  def handle_info({:board, _id}, state), do: {:noreply, %{state | dirty: true}}

  def handle_info(:tick, state) do
    if state.tick?, do: Process.send_after(self(), :tick, @tick)
    {:noreply, run(state, false)}
  end

  def handle_info({ref, results}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    now = System.monotonic_time(:millisecond)

    sent =
      Enum.reduce(results, state.sent, fn
        {id, :sent, signature}, sent -> Map.put(sent, id, {now, signature})
        {id, :same, _signature}, sent -> Map.update(sent, id, {now, nil}, & &1)
        {id, :failed, _signature}, sent -> Map.put(sent, id, {now - @heartbeat + @retry, nil})
      end)

    for from <- state.waiting, do: GenServer.reply(from, :ok)
    {:noreply, %{state | task: nil, sent: sent, waiting: []}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: ref} = state) do
    for from <- state.waiting, do: GenServer.reply(from, :ok)
    {:noreply, %{state | task: nil, waiting: []}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:report_now, from, state) do
    state = if state.task, do: state, else: run(state, true)

    if state.task,
      do: {:noreply, %{state | waiting: [from | state.waiting]}},
      else: {:reply, :ok, state}
  end

  defp run(%{task: task} = state, _force) when task != nil, do: state

  defp run(state, force) do
    now = System.monotonic_time(:millisecond)
    targets = targets()
    ids = MapSet.new(targets, fn {_link, tournament} -> tournament.id end)
    # A tournament no longer reported is forgotten: it starts afresh if it
    # comes back.
    sent = Map.filter(state.sent, fn {id, _} -> MapSet.member?(ids, id) end)

    due =
      for {link, tournament} <- targets,
          {at, _sig} = Map.get(sent, tournament.id, {nil, nil}),
          force or at == nil or now - at >= @heartbeat or (state.dirty and now - at >= @gap),
          do: {link, tournament, force or at == nil or now - at >= @heartbeat}

    # Everything due goes now; a tournament inside its two seconds keeps
    # the change for the next tick.
    still_dirty = state.dirty and length(due) < length(targets)

    case due do
      [] ->
        %{state | sent: sent, dirty: if(targets == [], do: false, else: state.dirty)}

      due ->
        signatures = Map.new(sent, fn {id, {_at, sig}} -> {id, sig} end)

        task =
          Task.Supervisor.async_nolink(Alnasl.TaskSupervisor, fn ->
            Enum.map(due, fn {link, tournament, always?} ->
              send_one(link, tournament, always?, signatures[tournament.id])
            end)
          end)

        %{state | sent: sent, dirty: still_dirty, task: task.ref}
    end
  end

  # `[{link, tournament}]`: every tournament that is linked, not gone, and
  # whose pairing program takes tables.
  defp targets do
    for link <- Tournaments.links(),
        OpenPairings.polled?(link),
        OpenPairings.controls?(link),
        tournament <- Tournaments.of_link(link),
        not tournament.gone,
        do: {link, tournament}
  end

  defp send_one(link, tournament, always?, last) do
    tables = tables(tournament)
    signature = signature(tables)

    if always? or signature != last do
      case Client.tables(link, tournament.remote_id, tables) do
        {:ok, _stored} -> {tournament.id, :sent, signature}
        # An OpenPairings that says revision 2 and has no `/tables` is
        # tried again with the heartbeat, and says nothing to the log.
        {:error, :not_the_api} -> {tournament.id, :sent, signature}
        {:error, _reason} -> {tournament.id, :failed, signature}
      end
    else
      {tournament.id, :same, signature}
    end
  rescue
    _error -> {tournament.id, :failed, nil}
  end

  # What changes the picture, without the clocks running down.
  defp signature(tables) do
    tables
    |> Enum.map(&Map.drop(&1, ["white_ms", "black_ms", "last_seen"]))
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  # --- one tournament's tables -------------------------------------------------

  @doc "What every board given to `tournament` shows now, as the contract's tables."
  def tables(%Tournaments.Tournament{id: id}) do
    Boards.list()
    |> Enum.filter(&(&1.tournament_id == id))
    |> Enum.take(@max_tables)
    |> Enum.map(&table/1)
  end

  @doc "One board, as a table (`POST /tournaments/:id/tables`)."
  def table(%Boards.Board{} = board) do
    s = Boards.snapshot(board)
    linked? = s[:linked?] == true
    plies = s[:plies] || []
    {white_ms, black_ms, running} = clock(s[:clock] || s[:board_clock])
    alarms = alarms(s)

    %{
      "board" => board.id,
      "name" => String.slice(board.name || "Board #{board.id}", 0, 80),
      "table" => board.table_no,
      "serial" => blank(board.serial, 40),
      "game" => remote_game(s),
      "round" => board.round,
      "board_no" => board.board_no,
      "connected" => s[:connected?] == true,
      "last_seen" =>
        s[:last_seen] && DateTime.to_iso8601(DateTime.truncate(s.last_seen, :second)),
      "state" => state(s),
      "flipped" => board.flipped == true,
      "alarms" => Enum.map(alarms, &elem(&1, 0)),
      "alarm_detail" =>
        case alarms do
          [{_, detail} | _] -> detail && String.slice(detail, 0, 200)
          [] -> nil
        end,
      "draft" => draft(s[:draft]),
      "guessed_plies" =>
        for(
          {%{flags: flags}, n} <- Enum.with_index(plies, 1),
          :guessed in (flags || []),
          do: n
        )
        |> Enum.take(-200),
      "fen" => fen(s, linked?),
      "last_move" => last_move(s, plies, linked?),
      "white_ms" => white_ms,
      "black_ms" => black_ms,
      "running" => running
    }
  end

  defp blank(nil, _max), do: nil
  defp blank("", _max), do: nil
  defp blank(text, max), do: String.slice(text, 0, max)

  defp remote_game(%{game_id: id, local: false}) when is_integer(id) do
    case Repo.get(Games.Game, id) do
      %Games.Game{remote_game: game} when is_binary(game) and byte_size(game) <= 64 -> game
      _other -> nil
    end
  end

  defp remote_game(_snapshot), do: nil

  defp state(s) do
    cond do
      s[:status] == :finished ->
        "finished"

      s[:status] in [:no_signal, :unlinked] ->
        Atom.to_string(s.status)

      s[:paused] == true ->
        "paused"

      s[:status] == :recovered ->
        if(guessed_last?(s), do: "guessed", else: "recovered")

      s[:status] in [:waiting_start] ->
        "waiting"

      s[:status] in [:live, :settling] ->
        "live"

      is_atom(s[:status]) and s[:status] != nil ->
        s.status |> Atom.to_string() |> String.slice(0, 32)

      true ->
        "no_signal"
    end
  end

  defp guessed_last?(s) do
    case List.last(s[:plies] || []) do
      %{flags: flags} -> :guessed in (flags || [])
      _none -> false
    end
  end

  # `[{alarm, an English sentence | nil}]`, the most pressing first.
  defp alarms(s) do
    sync =
      case {s[:status], s[:detail]} do
        {:out_of_sync, {:out_of_turn, move}} ->
          [{"out_of_turn", "#{side(move[:colour])} played #{move[:san]} out of turn"}]

        {:out_of_sync, {:illegal, move}} ->
          [{"illegal_move", "Illegal move from #{square(move[:from])} to #{square(move[:to])}"}]

        {:out_of_sync, _other} ->
          [{"out_of_sync", "The board does not match the game"}]

        _fine ->
          []
      end

    clock =
      if s[:clock_alarm] != nil,
        do: [{"clock", "The clock runs for the side that is not to move"}],
        else: []

    setup =
      if (s[:problems] || []) != [],
        do: [{"setup", "The pieces are not set up as the game starts"}],
        else: []

    unseen =
      case s[:unseen] || [] do
        [] -> []
        pieces -> [{"pieces_unseen", "#{length(pieces)} piece(s) not seen on the board"}]
      end

    pairing =
      if s[:pairing_flag] != nil,
        do: [{"pairing_changed", "The pairing changed under this game"}],
        else: []

    Enum.take(sync ++ clock ++ setup ++ unseen ++ pairing, 8)
  end

  defp side(colour) when colour in [:b, "b", :black], do: "Black"
  defp side(_white), do: "White"

  defp square(i) when is_integer(i), do: Position.square_name(i)
  defp square(other), do: to_string(other)

  defp draft(%{id: id, reason: reason, from_ply: from, total: total}) do
    %{
      "id" => id,
      "reason" => String.slice(to_string(reason), 0, 32),
      "from_ply" => from,
      "plies" => total
    }
  end

  defp draft(_none), do: nil

  defp fen(%{fen: fen}, true) when is_binary(fen), do: fen

  defp fen(%{raw: raw}, _linked?) when is_binary(raw) do
    case Position.from_text(raw) do
      {:ok, board} -> Position.fen(board)
      :error -> nil
    end
  end

  defp fen(_snapshot, _linked?), do: nil

  defp last_move(%{last_move: {from, to}}, plies, true)
       when is_integer(from) and is_integer(to) do
    Chess.name(from) <> Chess.name(to) <> promotion(List.last(plies))
  end

  defp last_move(_snapshot, _plies, _linked?), do: nil

  defp promotion(%{san: san}) when is_binary(san) do
    case Regex.run(~r/=([QRBN])/, san) do
      [_, piece] -> String.downcase(piece)
      nil -> ""
    end
  end

  defp promotion(_ply), do: ""

  @max_ms 360_000_000

  defp clock(%{white_ms: white, black_ms: black, running: running}) do
    {ms(white), ms(black),
     case running do
       :white -> "white"
       :black -> "black"
       _none -> "none"
     end}
  end

  defp clock(_none), do: {nil, nil, nil}

  defp ms(n) when is_integer(n), do: n |> max(0) |> min(@max_ms)
  defp ms(_other), do: nil
end
