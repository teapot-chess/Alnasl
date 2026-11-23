defmodule AlnaslWeb.BridgesTest do
  @moduledoc """
  Bridges from this end: a code that works once and not for long, a key
  that is only ever a hash here, the Setup panel with its link and QR code,
  commands down the link, and Remove from either side ending it for both.
  The bridge is a real Arkab bridge over a real socket; its boards are
  replays, never a serial port.
  """

  use AlnaslWeb.SiteCase, async: false

  # A bridge stopped at the end of a test aborts its socket, and the web
  # server says so in red. It is not news.
  @moduletag :capture_log

  alias Alnasl.Bridges
  alias Alnasl.Bridges.Bridge

  @identity %{"v" => 1, "bridge" => "uid-1", "name" => "hall", "software" => "arkab 0.1.0"}

  defp serve do
    {:ok, pid} =
      Bandit.start_link(plug: AlnaslWeb.Endpoint, port: 0, ip: :loopback, startup_log: false)

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp bridge_joined do
    dir = Path.join(System.tmp_dir!(), "alnasl-bridges-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    port = serve()
    start_supervised!({Arkab.Bridge, data_dir: dir, name: "hall", sources: [], web: false})
    {:ok, code} = Bridges.create_join()
    {:ok, server_id} = Arkab.Bridge.join("http://127.0.0.1:#{port}/join/#{code.code}")
    [bridge] = Bridges.list()
    eventually(fn -> Bridges.live(bridge.id) end)
    {bridge, server_id}
  end

  defp linked_tournament do
    Repo.insert!(%Alnasl.Tournaments.Tournament{
      kind: "linked",
      name: "Interclubs",
      hall_id: Alnasl.Halls.own_id(),
      remote_id: 1
    })
  end

  # The game on board `board` of round 1, `sans` already played.
  defp played(tournament, board, sans) do
    game = Alnasl.Games.ensure(tournament.id, 1, board, %{})
    plies = Enum.map(sans, &%{san: &1, flags: [], clock: nil})
    {game, false} = Alnasl.Games.apply_event(game, {:moves, plies}, 1_000)
    game
  end

  defp joined(identity \\ @identity, now \\ DateTime.utc_now(:second)) do
    {:ok, join} = Bridges.create_join(now)
    {:ok, %{bridge: bridge}} = Bridges.redeem(join.code, identity, now)
    bridge
  end

  describe "a bridge that comes back" do
    # Hall 5, 2026-11-23, 17:58: a laptop's eight LiveChess boards at tables
    # 1-8 of a linked tournament; the bridge leaves, joins again five
    # seconds later and reports its boards. They came back as eight new
    # boards in the hall's own tournament without a table between them.
    test "keeps its boards' tables, tournament, round and board, and the games carry on" do
      t = linked_tournament()
      bridge = joined()

      for n <- 1..8 do
        {:ok, row} = Bridges.board_row(bridge, "LiveChess##{n}")

        {:ok, _row} =
          Boards.update(row, %{
            tournament_id: t.id,
            table_no: n,
            round: 1,
            board_no: n,
            flipped: n == 5
          })
      end

      played(t, 5, ~w(e4 c5 Nf3 d6))

      # It said `leave` (what the socket does with it), and came back.
      Bridges.forget(Repo.get!(Bridge, bridge.id))
      assert Bridges.rows(bridge) == []
      again = joined()
      assert again.id == bridge.id

      rows =
        for n <- 1..8 do
          {:ok, row} = Bridges.board_row(again, "LiveChess##{n}")
          row
        end

      for {row, n} <- Enum.with_index(rows, 1) do
        assert row.port == "bridge-#{bridge.id}:LiveChess##{n}"
        assert {row.tournament_id, row.table_no, row.round, row.board_no} == {t.id, n, 1, n}
        assert row.flipped == (n == 5)
      end

      five = Enum.at(rows, 4)
      eventually(fn -> length(List.wrap(Boards.snapshot(five.id)[:plies])) == 4 end)
      assert Enum.map(Boards.snapshot(five.id).plies, & &1.san) == ~w(e4 c5 Nf3 d6)

      # Taken once: a board removed by hand and reported again is a new one.
      Boards.delete(five)
      {:ok, fresh} = Bridges.board_row(again, "LiveChess#5")
      assert fresh.table_no == nil
    end

    test "a table or game taken meanwhile stays with the board that took it" do
      t = linked_tournament()
      bridge = joined()
      {:ok, row} = Bridges.board_row(bridge, "LiveChess#1")
      {:ok, _row} = Boards.update(row, %{tournament_id: t.id, table_no: 1, round: 1, board_no: 1})

      Bridges.forget(Repo.get!(Bridge, bridge.id))

      {:ok, other} =
        Boards.create(%{name: "spare", driver: "remote", port: "elsewhere", tournament_id: t.id})

      {:ok, _other} = Boards.update(other, %{table_no: 1, round: 1, board_no: 1})

      {:ok, back} = Bridges.board_row(joined(), "LiveChess#1")
      assert back.tournament_id == t.id
      assert {back.table_no, back.round, back.board_no} == {nil, nil, nil}
    end

    test "after half a day, or in another hall, it starts afresh" do
      t = linked_tournament()
      now = DateTime.utc_now(:second)
      bridge = joined(@identity, now)
      {:ok, row} = Bridges.board_row(bridge, "LiveChess#1")
      {:ok, _row} = Boards.update(row, %{tournament_id: t.id, table_no: 1, round: 1, board_no: 1})

      Bridges.forget(Repo.get!(Bridge, bridge.id))
      late = joined(@identity, DateTime.add(now, 13 * 3600))
      {:ok, back} = Bridges.board_row(late, "LiveChess#1")
      assert {back.table_no, back.round, back.board_no} == {nil, nil, nil}
    end

    test "Remove on the server still takes its boards away" do
      bridge = joined()
      {:ok, _row} = Bridges.board_row(bridge, "LiveChess#1")
      Bridges.remove(Repo.get!(Bridge, bridge.id))
      assert Bridges.list() == []
      assert Bridges.rows(bridge) == []
    end
  end

  describe "the code" do
    test "works once, for fifteen minutes, and only the key's hash is kept" do
      now = ~U[2026-10-16 12:00:00Z]
      {:ok, join} = Bridges.create_join(now)
      assert join.code =~ ~r/^[2-9A-HJKMNP-Z]{3}-[2-9A-HJKMNP-Z]{4}$/

      assert {:ok, %{key: key, bridge: %Bridge{} = bridge}} =
               Bridges.redeem(join.code, @identity, DateTime.add(now, 60))

      refute bridge.key_hash =~ key
      assert {:ok, %Bridge{id: id}} = Bridges.authenticate("uid-1", key)
      assert id == bridge.id
      assert Bridges.authenticate("uid-1", "not the key") == {:error, :key}
      assert Bridges.authenticate("someone", key) == {:error, :key}

      assert Bridges.redeem(join.code, @identity, DateTime.add(now, 61)) ==
               {:error, :used_or_expired}

      {:ok, late} = Bridges.create_join(now)

      assert Bridges.redeem(late.code, @identity, DateTime.add(now, 15 * 60)) ==
               {:error, :used_or_expired}

      {:ok, other} = Bridges.create_join(now)
      assert Bridges.redeem(other.code, %{@identity | "v" => 99}, now) == {:error, :version}
    end

    test "a bridge removed here and joined again is the same row, with a new key" do
      {:ok, one} = Bridges.create_join()
      {:ok, %{key: old, bridge: bridge}} = Bridges.redeem(one.code, @identity)
      Bridges.remove(bridge)
      assert Bridges.list() == []
      assert Bridges.authenticate("uid-1", old) == {:error, :revoked}

      {:ok, two} = Bridges.create_join()
      {:ok, %{key: new, bridge: again}} = Bridges.redeem(two.code, @identity)
      assert again.id == bridge.id
      assert {:ok, _} = Bridges.authenticate("uid-1", new)
      assert Bridges.authenticate("uid-1", old) == {:error, :key}
    end

    test "the link answers a bridge in JSON and a browser in words", %{conn: conn} do
      {:ok, join} = Bridges.create_join()

      page = conn |> get("/join/#{join.code}") |> html_response(200)
      assert page =~ join.code

      answer =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/join/#{join.code}", Jason.encode!(@identity))
        |> json_response(200)

      assert %{"key" => _key, "socket" => "/bridge/link", "owner" => true} = answer

      assert build_conn()
             |> put_req_header("content-type", "application/json")
             |> post("/join/#{join.code}", Jason.encode!(@identity))
             |> json_response(410)
    end

    test "an address guessing codes is made to wait; join codes come from strong randomness" do
      Alnasl.Takeover.RateLimit.reset()
      on_exit(&Alnasl.Takeover.RateLimit.reset/0)

      guess = fn code ->
        %{build_conn() | remote_ip: {192, 0, 2, 77}}
        |> put_req_header("content-type", "application/json")
        |> post("/join/" <> code, Jason.encode!(@identity))
      end

      for _ <- 1..20, do: assert(guess.("AAA-BBBB").status == 410)

      {:ok, join} = Bridges.create_join()
      limited = guess.(join.code)
      assert limited.status == 429
      assert [_seconds] = get_resp_header(limited, "retry-after")

      # Another address is not held up by this one.
      assert build_conn()
             |> put_req_header("content-type", "application/json")
             |> post("/join/" <> join.code, Jason.encode!(@identity))
             |> json_response(200)

      assert join.code =~ ~r/^[2-9A-HJKMNP-Z]{3}-[2-9A-HJKMNP-Z]{4}$/
    end
  end

  describe "The Bridges tab of the hall page" do
    test "Add a bridge shows the link and its QR code; a bridge that joins is listed", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/halls/#{Alnasl.Halls.own_id()}/bridges")
      assert has_element?(view, "#bridge-none")

      view |> element("#bridge-add") |> render_click()
      assert has_element?(view, "#bridge-join-qr svg")
      link = view |> element("#bridge-join-link") |> render()
      assert link =~ "/join/"

      {bridge, _server_id} = bridge_joined()
      eventually_html(view, &(&1 =~ "bridge-#{bridge.id}-up"))
      assert has_element?(view, "#bridge-#{bridge.id}-remove")
    end
  end

  describe "the link" do
    test "a command goes down and its answer comes back" do
      {bridge, _server_id} = bridge_joined()
      Bridges.subscribe()
      assert Arkab.Bridge.recording?()

      {:ok, id} = Bridges.command(bridge.id, "record", %{on: false})
      assert_receive {:bridges, {:reply, _bridge, ^id, true, nil}}, 5_000
      refute Arkab.Bridge.recording?()

      assert Bridges.command(bridge.id, "launch_rockets") == {:error, :unknown_command}
    end

    test "a board the bridge reads gets a row of its own, named after where it is" do
      {bridge, _server_id} = bridge_joined()

      :ok =
        Arkab.Bridge.Ports.add(%{
          "replay" => "test/fixtures/captures/real-06310-knight-moves.jsonl",
          "name" => "COM9",
          "speed" => 50
        })

      row = eventually(fn -> Enum.find(Bridges.rows(bridge), &(&1.port =~ "COM9")) end)
      assert row.driver == "remote" and row.name == "hall COM9"
      eventually(fn -> Boards.snapshot(row.id).raw end)
    end

    test "Remove on the server ends it on the bridge" do
      {bridge, _server_id} = bridge_joined()
      Bridges.remove(Repo.get!(Bridge, bridge.id))
      eventually(fn -> Arkab.Bridge.Store.servers() == [] end)
    end

    test "a bridge removed and joined again on the spot keeps its tables, and the game carries on" do
      {bridge, server_id} = bridge_joined()
      t = linked_tournament()
      {:ok, row} = Bridges.board_row(bridge, "LiveChess#3")
      {:ok, _row} = Boards.update(row, %{tournament_id: t.id, table_no: 3, round: 1, board_no: 3})
      played(t, 3, ~w(d4 d5 c4))

      [%{url: url}] = Arkab.Bridge.Store.servers()
      Arkab.Bridge.remove(server_id)
      eventually(fn -> Bridges.rows(bridge) == [] end)

      {:ok, code} = Bridges.create_join()

      {:ok, _server} =
        Arkab.Bridge.join("http://127.0.0.1:#{URI.parse(url).port}/join/#{code.code}")

      [again] = Bridges.list()
      assert again.id == bridge.id
      eventually(fn -> Bridges.live(again.id) end)

      {:ok, back} = Bridges.board_row(again, "LiveChess#3")
      assert {back.tournament_id, back.table_no, back.round, back.board_no} == {t.id, 3, 1, 3}
      eventually(fn -> Boards.snapshot(back.id)[:plies] |> List.wrap() |> length() == 3 end)
    end

    test "Remove on the bridge ends it here, boards and all" do
      {bridge, server_id} = bridge_joined()
      {:ok, _row} = Bridges.board_row(bridge, "COM3")
      Arkab.Bridge.remove(server_id)
      eventually(fn -> Bridges.list() == [] end)
      eventually(fn -> Bridges.rows(bridge) == [] end)
    end
  end
end
