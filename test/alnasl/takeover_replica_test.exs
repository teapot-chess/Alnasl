defmodule Alnasl.TakeoverReplicaTest do
  @moduledoc """
  The Litestream replica of a spare taking over (`Alnasl.Takeover.Replica`,
  `Alnasl.Takeover.Replicator`): the configuration Litestream is given, who
  replicates and when it stops, which game a takeover takes from the
  replica and which it leaves as the cloud has it, and a takeover that
  reads a real copy of another box's database. Litestream itself is a
  stand-in (`Alnasl.FakeLitestream`); the copy is a real SQLite file.
  """

  use AlnaslWeb.ConnCase, async: false

  import Alnasl.TakeoverHelpers
  import AlnaslWeb.AccountHelpers, only: [hall_fixture: 1]

  alias Alnasl.{Games, Repo, Takeover, Tournaments}
  alias Alnasl.Games.Game
  alias Alnasl.Takeover.{Cloud, Link, Replica, Replicator, Restore, Stream}

  setup do
    cloud_on()

    if :ets.whereis(Takeover.runtime_table()) == :undefined,
      do: :ets.new(Takeover.runtime_table(), [:named_table, :public])

    put_env(:takeover_replica_runner, Alnasl.FakeLitestream)
    put_env(:fake_litestream_owner, self())
    put_env(:fake_litestream_source, nil)
    put_env(:takeover_replica_retry_ms, 50)

    %{hall: hall_fixture("Cloud hall")}
  end

  defp replica_on(url \\ "s3://alnasl-replicas/club") do
    put_env(:takeover_replica, %{url: url, endpoint: "http://10.0.0.9:9000", region: "eu-1"})
  end

  defp plies(sans), do: Jason.encode!(Enum.map(sans, &%{"san" => &1}))
  defp game(sans, status \\ "live"), do: %{"plies" => plies(sans), "status" => status}

  # A database file of another box, made with this Alnasl's own migrations.
  defp replica_db(fun) do
    dir = Path.join(System.tmp_dir!(), "alnasl-replica-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "box.db")

    {:ok, pid} =
      Alnasl.Repo.start_link(
        name: nil,
        database: path,
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        log: false
      )

    previous = Alnasl.Repo.put_dynamic_repo(pid)

    try do
      Replica.migrate(pid)
      {path, fun.()}
    after
      Alnasl.Repo.put_dynamic_repo(previous)
      Supervisor.stop(pid)
    end
  end

  describe "the configuration" do
    test "one database, its replica under the box's uid, and no credentials" do
      replica_on("s3://alnasl-replicas/club/")
      yaml = Replica.yaml(Replica.config(), "/var/lib/alnasl/alnasl.db", "s3://b/club/BOX1")

      assert yaml =~ ~s(  - path: "/var/lib/alnasl/alnasl.db")
      assert yaml =~ ~s(        url: "s3://b/club/BOX1")
      assert yaml =~ ~s(        endpoint: "http://10.0.0.9:9000")
      assert yaml =~ "        force-path-style: true"
      assert yaml =~ ~s(        region: "eu-1")
      assert yaml =~ ~s(        sync-interval: "1s")
      refute yaml =~ ~r/secret|access-key|password/i

      assert Replica.url_for(Replica.config(), "BOX_1-a") ==
               "s3://alnasl-replicas/club/BOX_1-a"

      # A uid is a path segment: nothing that could climb out of it.
      assert Replica.url_for(Replica.config(), "../other") == nil
      assert Replica.url_for(Replica.config(), "") == nil
    end

    test "an SFTP or a directory replica has no S3 settings; an http one is not a replica" do
      put_env(:takeover_replica, %{url: "file:///srv/replicas", endpoint: "http://x", region: nil})

      yaml = Replica.yaml(Replica.config(), "/d/alnasl.db", "file:///srv/replicas/BOX")
      refute yaml =~ "endpoint"
      refute yaml =~ "region"

      put_env(:takeover_replica, %{url: "https://example.org/replicas"})
      assert Replica.config() == nil
      refute Replica.enabled?()
    end

    test "the box whose copy a takeover reads: the newest event's, else the state's" do
      events = [%{"game" => "OLD/1"}, %{"game" => "NEWER/7"}]
      assert Replica.source_uid(%{"box" => "STATE"}, events) == "NEWER"
      assert Replica.source_uid(%{"box" => "STATE"}, []) == "STATE"
      assert Replica.source_uid(nil, []) == nil
      assert Replica.source_uid(%{"box" => "../x"}, []) == nil
    end
  end

  describe "which copy of a game a takeover keeps" do
    test "the replica's where it is plainly further on, the cloud's otherwise" do
      cloud = %{
        "prefix" => game(~w(e4 e5)),
        "ahead" => game(~w(d4 d5 c4)),
        "takeback" => game(~w(c4 e5)),
        "ended" => game(~w(f4)),
        "results" => game(~w(g3), "finished") |> Map.put("result", "1-0")
      }

      replica = %{
        "prefix" => game(~w(e4 e5 Nf3)),
        "ahead" => game(~w(d4 d5)),
        "takeback" => game(~w(c4 c5 Nc3)),
        "ended" => game(~w(f4), "finished"),
        "results" => game(~w(g3), "finished") |> Map.put("result", "0-1"),
        "new" => game(~w(Nf3))
      }

      {games, n} = Restore.top_up(cloud, replica)

      assert games["prefix"] == replica["prefix"]
      assert games["ahead"] == cloud["ahead"]
      assert games["takeback"] == cloud["takeback"]
      assert games["ended"] == replica["ended"]
      assert games["results"] == cloud["results"]
      assert games["new"] == replica["new"]
      assert n == 3
    end
  end

  describe "who replicates" do
    test "an active paired box, until it stands by; a crashed Litestream comes back", %{
      hall: hall
    } do
      replica_on()
      start_supervised!(Replicator)
      Replicator.check()
      refute_received {:litestream, :start, _path, _handle}

      pair_this_box(hall)
      uid = Takeover.config()["uid"]
      Replicator.check()
      assert_receive {:litestream, :start, path, handle}, 1_000
      assert File.read!(path) =~ ~s(url: "s3://alnasl-replicas/club/#{uid}")
      assert Replicator.status().state == :running

      # Litestream exits: started again, not at once.
      send(Process.whereis(Replicator), {handle, {:exit_status, 1}})
      assert_receive {:litestream, :start, _path, handle}, 1_000

      :ok = Link.stand_by()
      Replicator.check()
      assert_receive {:litestream, :stop, ^handle}, 1_000
      assert Replicator.status().state == :off
    end

    test "nothing without Litestream on the box", %{hall: hall} do
      replica_on()
      put_env(:fake_litestream_available, false)
      start_supervised!(Replicator)
      pair_this_box(hall)
      Replicator.check()
      refute_received {:litestream, :start, _path, _handle}
      assert Replicator.status().state == :off
    end
  end

  describe "a takeover with a replica" do
    setup %{hall: hall} do
      %{box: active} = other_box(hall, "Active")
      {:granted, _lease, :none} = Cloud.claim(active, nil)

      {path, {own, board5, board6}} =
        replica_db(fn ->
          t = Tournaments.default() |> Ecto.Changeset.change(round: 3) |> Repo.update!()

          a =
            Repo.insert!(%Game{
              tournament_id: t.id,
              round: 3,
              board_no: 5,
              white: "White player",
              black: "Black player",
              plies: plies(~w(e4 c5 Nf3 d6)),
              status: "live"
            })

          b =
            Repo.insert!(%Game{
              tournament_id: t.id,
              round: 3,
              board_no: 6,
              plies: plies(~w(d4)),
              status: "live"
            })

          {t.id, a.id, b.id}
        end)

      :ok =
        Cloud.put_state(active, 1, %{
          "v" => 1,
          "box" => active.uid,
          "own_tournament" => own,
          "tournaments" => [%{"id" => own, "kind" => "local", "name" => "Club", "round" => 3}],
          "games" => [],
          "boards" => [],
          "placements" => []
        })

      # The cloud heard the first two moves of board 5, and nothing of board 6.
      events =
        [
          {"start", nil, %{"white" => "White player", "black" => "Black player"}},
          {"ply", 1, %{"san" => "e4"}},
          {"ply", 2, %{"san" => "c5"}}
        ]
        |> Enum.with_index(1)
        |> Enum.map(fn {{kind, ply, data}, seq} ->
          %{
            "id" => Stream.event_id(active.uid, seq),
            "seq" => seq,
            "kind" => kind,
            "game" => "#{active.uid}/#{board5}",
            "ply" => ply,
            "at" => seq,
            "data" => Map.put(data, "where", %{"t" => own, "r" => 3, "b" => 5, "n" => 1})
          }
        end)

      {:ok, 3} = Cloud.put_events(active, 1, events)
      _ = board6

      %{active: active, path: path}
    end

    test "gets the moves the cloud never heard of", %{hall: hall, active: active, path: path} do
      replica_on("file:///srv/replicas/club")
      put_env(:fake_litestream_source, path)
      Phoenix.PubSub.subscribe(Alnasl.PubSub, "takeover")

      pair_this_box(hall, "spare")
      silence(hall.id)
      assert :ok = Link.step_now()
      assert Takeover.phase() == :active

      assert_received {:litestream, :restore, yaml}
      assert yaml =~ ~s(url: "file:///srv/replicas/club/#{active.uid}")

      tid = Tournaments.default_id()
      board5 = Games.current(tid, 3, 5)
      assert Games.sans(board5) == ~w(e4 c5 Nf3 d6)
      assert board5.white == "White player"
      assert Games.sans(Games.current(tid, 3, 6)) == ~w(d4)
      assert_received {:takeover, {:took_over, %{from_replica: 2}}}
    end

    test "a replica that cannot be read changes nothing but the count", %{hall: hall} do
      replica_on("file:///srv/replicas/club")
      put_env(:fake_litestream_source, {:error, "no such bucket"})
      Phoenix.PubSub.subscribe(Alnasl.PubSub, "takeover")

      pair_this_box(hall, "spare")
      silence(hall.id)
      assert :ok = Link.step_now()
      assert Takeover.phase() == :active

      tid = Tournaments.default_id()
      assert Games.sans(Games.current(tid, 3, 5)) == ~w(e4 c5)
      assert Games.current(tid, 3, 6) == nil
      assert_received {:takeover, {:took_over, %{from_replica: 0}}}
    end
  end
end
