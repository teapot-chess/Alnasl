defmodule Alnasl.TakeoverBoxTest do
  @moduledoc """
  The box's end of a spare taking over (`Alnasl.Takeover.Stream`,
  `Alnasl.Takeover.Link`), against a cloud in the same test run: what a
  saved game queues, a queue that keeps its order through a restart and
  stops at its cap, a spare that takes a silent hall with its games, and
  an active box that comes back to find its hall gone and steps down.
  """

  use AlnaslWeb.ConnCase, async: false

  import Alnasl.TakeoverHelpers
  import Ecto.Query, only: [from: 2]
  import AlnaslWeb.AccountHelpers, only: [hall_fixture: 1]

  alias Alnasl.{Games, Repo, Takeover, Tournaments}
  alias Alnasl.Takeover.{Cloud, Event, Link, Queued, Stream}

  setup do
    cloud_on()

    if :ets.whereis(Takeover.runtime_table()) == :undefined,
      do: :ets.new(Takeover.runtime_table(), [:named_table, :public])

    %{hall: hall_fixture("Cloud hall")}
  end

  defp play(game, sans),
    do: game |> Games.apply_event({:moves, Enum.map(sans, &%{san: &1})}, 1_000) |> elem(0)

  defp queued_rows, do: Repo.all(from q in Queued, order_by: q.id)

  defp offline do
    put_env(:takeover_req_options,
      plug: fn conn -> Req.Test.transport_error(conn, :econnrefused) end
    )
  end

  describe "what a saved game queues" do
    test "nothing on a box that is not paired, or is a spare", %{hall: hall} do
      game = Games.ensure(1, 1)
      play(game, ~w(e4))
      assert queued_rows() == []

      # Another box runs the hall: a spare paired now stays a spare.
      %{box: active} = other_box(hall, "Active")
      {:granted, _lease, :none} = Cloud.claim(active, nil)
      pair_this_box(hall, "spare")
      assert Takeover.phase() == :spare
      play(Games.get(1, 1), ~w(e5))
      assert queued_rows() == []
    end

    test "moves, a take-back and a result, in that order", %{hall: hall} do
      pair_this_box(hall)
      offline()

      game = Games.ensure(1, 1) |> play(~w(e4 e5 Nf3))

      game =
        Games.apply_event(game, {:correction, 2, [%{san: "Nc3"}], :misread}, 2_000) |> elem(0)

      Games.finish(game, "1-0")

      kinds = Enum.map(queued_rows(), &{&1.kind, &1.ply})

      assert kinds == [
               {"start", nil},
               {"ply", 1},
               {"ply", 2},
               {"ply", 3},
               {"truncate", nil},
               {"ply", 3},
               {"end", nil}
             ]

      uid = Takeover.config()["uid"]
      assert [first | _] = Stream.batch(uid)
      assert first["id"] == "#{uid}-#{first["seq"]}"
      assert first["data"]["where"] == %{"t" => game.tournament_id, "r" => 1, "b" => 1, "n" => 1}
    end
  end

  describe "the queue" do
    test "offline it waits, counted; online it goes, once, in order", %{hall: hall} do
      box = pair_this_box(hall)
      offline()

      Games.ensure(1, 1) |> play(~w(d4 d5 c4))
      assert {:error, :unreachable} = Link.step_now()
      assert Takeover.status().online? == false
      assert Takeover.status().queued == 4
      assert AlnaslWeb.TakeoverWords.line().text == "Offline, 4 events queued"

      cloud_on_again()
      assert :ok = Link.step_now()
      assert Takeover.queued() == 0

      sent = Repo.all(from e in Event, where: e.box_id == ^box.id, order_by: e.id)
      assert Enum.map(sent, & &1.kind) == ~w(start ply ply ply)
      assert Enum.map(sent, & &1.ply) == [nil, 1, 2, 3]

      # A step with nothing new sends nothing twice.
      assert :ok = Link.step_now()
      assert Repo.aggregate(Event, :count) == 4
    end

    test "survives the box restarting, ids and order and all", %{hall: hall} do
      pair_this_box(hall)
      offline()
      start_supervised!({Link, tick: false})

      Games.ensure(1, 2) |> play(~w(e4 c5))
      before = Enum.map(queued_rows(), &{&1.id, &1.kind, &1.ply})

      :ok = stop_supervised(Link)
      start_supervised!({Link, tick: false})

      assert Enum.map(queued_rows(), &{&1.id, &1.kind, &1.ply}) == before

      Games.get(1, 2) |> play(~w(Nf3))
      ids = Enum.map(queued_rows(), & &1.id)
      assert ids == Enum.sort(ids)
      assert length(ids) == 4

      cloud_on_again()
      assert :ok = Link.step_now()
      assert Repo.all(from e in Event, order_by: e.id, select: e.ply) == [nil, 1, 2, 3]
    end

    test "never numbers an event twice, even once the queue was emptied", %{hall: hall} do
      pair_this_box(hall)
      offline()
      Games.ensure(1, 1) |> play(~w(e4))
      last = queued_rows() |> List.last() |> Map.fetch!(:id)
      Stream.acked(last)
      assert queued_rows() == []

      play(Games.get(1, 1), ~w(e5))
      assert [%{id: next}] = queued_rows()
      assert next > last

      [%{"sql" => sql}] =
        Repo.query!("select sql from sqlite_master where name = 'takeover_queue'")
        |> then(fn r -> Enum.map(r.rows, &Map.new(Enum.zip(r.columns, &1))) end)

      assert sql =~ "AUTOINCREMENT"
    end

    test "stops at its cap, says so once, and sends the whole state when it can", %{hall: hall} do
      box = pair_this_box(hall)
      offline()
      put_env(:takeover_queue_cap, 3)

      game = Games.ensure(1, 1) |> play(~w(e4 e5))
      assert Takeover.queued() == 3
      game = play(game, ~w(Nf3))
      play(game, ~w(Nc6))

      assert Takeover.queued() == 3
      assert Takeover.status().full?
      assert Enum.count(Alnasl.Log.list(), &(&1.kind == "takeover.queue_full")) == 1

      cloud_on_again()
      assert :ok = Link.step_now()
      refute Takeover.status().full?

      state = Repo.get_by!(Alnasl.Takeover.State, hall_id: hall.id)
      assert state.box_id == box.id
      games = Jason.decode!(state.data)["games"]
      assert Enum.any?(games, &(Jason.decode!(&1["plies"]) |> length() == 4))
    end
  end

  describe "two boxes, one hall" do
    test "a spare takes over a silent hall, with its games", %{hall: hall} do
      %{box: active} = other_box(hall, "Active")
      {:granted, _lease, :none} = Cloud.claim(active, nil)
      own = 900

      :ok =
        Cloud.put_state(active, 1, %{
          "v" => 1,
          "own_tournament" => own,
          "tournaments" => [%{"id" => own, "kind" => "local", "name" => "Club", "round" => 3}],
          "games" => [],
          "boards" => [],
          "placements" => []
        })

      events =
        [
          {"start", nil, %{"white" => "White player", "black" => "Black player"}},
          {"ply", 1, %{"san" => "e4"}},
          {"ply", 2, %{"san" => "c5"}},
          {"ply", 3, %{"san" => "Nf3"}},
          {"end", nil, %{"result" => "1-0"}}
        ]
        |> Enum.with_index(1)
        |> Enum.map(fn {{kind, ply, data}, seq} ->
          %{
            "id" => Stream.event_id(active.uid, seq),
            "seq" => seq,
            "kind" => kind,
            "game" => "#{active.uid}/77",
            "ply" => ply,
            "at" => seq,
            "data" => Map.put(data, "where", %{"t" => own, "r" => 3, "b" => 5, "n" => 1})
          }
        end)

      {:ok, 5} = Cloud.put_events(active, 1, events)
      # Sent twice, as a box that lost an answer would: kept once.
      {:ok, 5} = Cloud.put_events(active, 1, events)

      Phoenix.PubSub.subscribe(Alnasl.PubSub, "takeover")
      spare = pair_this_box(hall, "spare")
      assert Takeover.phase() == :spare
      assert :ok = Link.step_now()
      assert Takeover.phase() == :spare

      silence(hall.id)
      assert :ok = Link.step_now()

      assert Takeover.phase() == :active
      assert Takeover.config()["epoch"] == 2
      assert Cloud.lease(hall.id).box_id == spare.id

      game = Games.current(Tournaments.default_id(), 3, 5)
      assert Games.sans(game) == ~w(e4 c5 Nf3)
      assert {game.white, game.status, game.result} == {"White player", "finished", "1-0"}
      assert_received {:takeover, {:took_over, %{games: 1, epoch: 2}}}

      # The box that went silent comes back: refused, and told by whom.
      assert {:error, :stale} = Cloud.put_events(active, 1, [Map.put(hd(events), "seq", 6)])
      assert {:denied, _lease, :stale} = Cloud.claim(active, 1)
    end

    test "Take over in the cloud: the box that ran the hall steps down and stops", %{hall: hall} do
      pair_this_box(hall)
      assert :ok = Link.step_now()
      assert Takeover.config()["epoch"] == 1
      assert Takeover.driving?()

      %{box: spare} = other_box(hall, "Spare")
      {:granted, _lease, :other} = Cloud.hand_over(hall.id, spare.id)

      Games.ensure(1, 1) |> play(~w(e4))
      assert {:error, :superseded} = Link.step_now()

      assert Takeover.phase() == :superseded
      refute Takeover.driving?()
      assert Takeover.config()["holder"] == "Spare"

      assert {:error, :standing_by} =
               Alnasl.Boards.start(%Alnasl.Boards.Board{id: -1, driver: "remote"})

      # A box that stepped down queues nothing more: the hall is the other box's.
      before = Takeover.queued()
      play(Games.get(1, 1), ~w(e5))
      assert Takeover.queued() == before
      assert Repo.aggregate(from(e in Event, where: e.box_id != ^spare.id), :count) == 0

      # It may stand by as the spare of the box that has the hall.
      assert :ok = Link.stand_by()
      assert Takeover.phase() == :spare
      assert :ok = Link.step_now()
    end

    test "a spare pressed to take over gets the hall at once", %{hall: hall} do
      %{box: active} = other_box(hall, "Active")
      {:granted, _lease, :none} = Cloud.claim(active, nil)
      pair_this_box(hall, "spare")

      assert :ok = Link.take_over()
      assert Takeover.phase() == :active
      assert {:denied, _lease, :held} = Cloud.claim(active, nil)
    end

    test "a removed box forgets its hall at its next word", %{hall: hall} do
      box = pair_this_box(hall)
      Cloud.revoke(box)
      Link.step_now()
      assert Takeover.phase() == :unlinked
      assert Takeover.key() == nil
    end
  end

  defp cloud_on_again, do: put_env(:takeover_req_options, plug: AlnaslWeb.Endpoint)
end
