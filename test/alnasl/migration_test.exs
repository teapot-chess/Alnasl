defmodule Alnasl.MigrationTest do
  @moduledoc """
  A box that is upgraded keeps working: the settings of the one tournament
  it had become its own tournament's row, and every board, game and queued
  message goes with it. Run against a database of its own, made as the
  version before would have left it.
  """

  use ExUnit.Case, async: false

  alias Alnasl.{Repo, Tournaments}

  @tournaments 20_261_012_200_000
  @ui_mode 20_261_028_064_807
  @path Path.expand("../../priv/repo/migrations", __DIR__)
  @now "2026-10-12T09:00:00Z"

  setup do
    file =
      Path.join(
        System.tmp_dir!(),
        # The time as well: on Windows a file the pool still holds is not
        # removed, and the next run's counter starts where this one did.
        "alnasl-migration-#{System.os_time()}-#{System.unique_integer([:positive])}.db"
      )

    {:ok, pid} =
      Repo.start_link(
        name: nil,
        database: file,
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        log: false
      )

    # This process talks to that database; nobody else does.
    Repo.put_dynamic_repo(pid)

    # The migrator compiles the migration files every time it is asked;
    # that they were compiled before is not news.
    Code.put_compiler_option(:ignore_module_conflict, true)

    on_exit(fn ->
      Code.put_compiler_option(:ignore_module_conflict, false)
      for suffix <- ["", "-wal", "-shm"], do: File.rm(file <> suffix)
    end)

    Ecto.Migrator.run(Repo, @path, :up, to_exclusive: @tournaments, dynamic_repo: pid, log: false)
    {:ok, pid: pid}
  end

  defp upgrade(pid),
    do: Ecto.Migrator.run(Repo, @path, :up, all: true, dynamic_repo: pid, log: false)

  defp setting(key, value),
    do:
      Repo.query!("INSERT INTO settings (key, value) VALUES (?, ?)", [key, Jason.encode!(value)])

  defp settings, do: Repo.query!("SELECT key FROM settings").rows |> List.flatten() |> Enum.sort()

  # A key shaped like the real thing only as far as its first letters.
  defp key, do: "orrk" <> "_" <> String.duplicate("m", 20)

  test "the old settings become the box's own tournament, and everything it had goes with it",
       %{pid: pid} do
    setting("server_url", "https://results.example.org")
    setting("slug", "summer-open")
    setting("relay_key", key())
    setting("round", 3)
    setting("box_name", "Hall A")
    setting("lichess_round_id", "AbCd1234")
    setting("lichess_token", "lip" <> "_" <> String.duplicate("t", 20))
    setting("lichess_round", 2)
    setting("snapshot_at", "2026-10-11T18:00:00.123456Z")

    setting("snapshot", %{
      "tournament" => %{"name" => "Summer Open", "city" => "Ghent"},
      "players" => [
        %{
          "no" => 1,
          "name" => "Player One",
          "title" => "IM",
          "rating" => 2410,
          "fide_id" => 200_001
        },
        %{"no" => 2, "name" => "Player Two", "rating" => 2195}
      ],
      "rounds" => [
        %{
          "number" => 3,
          "boards" => [
            %{"board" => 1, "white" => 1, "black" => 2, "result" => nil},
            %{"board" => 2, "white" => "A Late Entry", "black" => nil}
          ]
        }
      ]
    })

    Repo.query!(
      """
      INSERT INTO boards (name, driver, port, flipped, enabled, round, board_no, table_no, inserted_at, updated_at)
      VALUES ('DGT 1', 'dgt_serial', 'COM7', 0, 0, 3, 1, 1, ?, ?)
      """,
      [@now, @now]
    )

    for game_no <- [1, 2] do
      Repo.query!(
        """
        INSERT INTO games (round, board_no, game_no, white, black, plies, status, paused, source, seq, inserted_at, updated_at)
        VALUES (3, 1, ?, 'IM Player One', 'Player Two', '[]', 'live', 0, 'board', 1, ?, ?)
        """,
        [game_no, @now, @now]
      )
    end

    Repo.query!(
      """
      INSERT INTO outbox (game_id, round, board_no, seq, plies, replace, body, state, attempts, inserted_at)
      VALUES (1, 3, 1, 1, 0, 0, '{"round":3,"board":1,"moves":[]}', 'pending', 0, ?)
      """,
      [@now]
    )

    upgrade(pid)

    assert [own] = Tournaments.list()
    assert own.id == Tournaments.default_id()
    assert own.kind == "local" and own.name == "Summer Open"
    assert own.round == 3

    assert {own.server_url, own.slug, own.relay_key} ==
             {"https://results.example.org", "summer-open", key()}

    assert Tournaments.openresults_configured?(own)
    assert own.lichess_round_id == "AbCd1234" and own.lichess_round == 2
    assert Tournaments.lichess_configured?(own)
    assert %DateTime{} = own.document_at

    # The pairings it knew are still known: nothing is fetched again.
    assert [%{board: 1, white: "IM Player One", black: "Player Two", white_rating: 2410}, two] =
             Tournaments.boards(own.id, 3)

    assert two.white == "A Late Entry" and two.black == nil
    assert Tournaments.info(own.id).city == "Ghent"
    assert %{white: %{fide_id: 200_001, title: "IM"}} = Tournaments.players(own.id, 3, 1)

    # What was the box's is the box's own tournament's.
    assert [board] = Alnasl.Boards.list()
    assert {board.tournament_id, board.round, board.board_no, board.table_no} == {own.id, 3, 1, 1}

    assert [%{game_no: 1, local: false}, %{game_no: 2, local: true}] =
             Alnasl.Games.history(own.id, 3, 1)

    assert Alnasl.Outbox.pending_by_tournament() == %{own.id => 1}

    # The settings that moved are gone from where they were; the rest stay,
    # and a box that was in use keeps every page (`AlnaslWeb.Mode`).
    assert settings() == ["box_name", "ui_mode"]

    assert %{rows: [[~s("full")]]} =
             Repo.query!("SELECT value FROM settings WHERE key = 'ui_mode'")
  end

  test "a box that only had a results page, and one that had nothing, each get their own tournament",
       %{pid: pid} do
    setting("server_url", "http://192.168.1.20:4031")
    setting("slug", "club-night")
    setting("relay_key", key())
    upgrade(pid)

    assert [%{kind: "local", round: 1, document: nil, name: nil} = own] = Tournaments.list()
    assert Tournaments.openresults_configured?(own)
    assert Tournaments.boards(own.id, 1) == []
    refute Tournaments.lichess_configured?(own)
    assert Tournaments.links() == []
  end

  test "a new box starts with its own tournament and nothing set", %{pid: pid} do
    upgrade(pid)

    assert [%{kind: "local", round: 1, server_url: "", slug: "", relay_key: ""} = own] =
             Tournaments.list()

    refute Tournaments.openresults_configured?(own)
    assert Tournaments.active() == [own]

    # Nothing was in use, so nothing is kept: a new box starts in simple mode.
    assert settings() == []
  end

  test "a box that was only in use for its boards keeps every page after the upgrade",
       %{pid: pid} do
    Ecto.Migrator.run(Repo, @path, :up,
      to_exclusive: @ui_mode,
      dynamic_repo: pid,
      log: false
    )

    Repo.query!(
      "INSERT INTO boards (name, driver, inserted_at, updated_at) VALUES (?, ?, ?, ?)",
      ["Board 1", "simulator", @now, @now]
    )

    upgrade(pid)

    assert %{rows: [[~s("full")]]} =
             Repo.query!("SELECT value FROM settings WHERE key = 'ui_mode'")

    # An account's own choice starts empty: the installation's word counts.
    assert %{rows: []} = Repo.query!("SELECT ui_mode FROM users")
  end

  test "going back puts the settings where the version before looks for them", %{pid: pid} do
    setting("server_url", "https://results.example.org")
    setting("slug", "summer-open")
    setting("relay_key", key())
    setting("round", 4)
    upgrade(pid)

    Ecto.Migrator.run(Repo, @path, :down, to: @tournaments, dynamic_repo: pid, log: false)

    assert %{rows: [[url]]} = Repo.query!("SELECT value FROM settings WHERE key = 'server_url'")
    assert Jason.decode!(url) == "https://results.example.org"
    assert %{rows: [[round]]} = Repo.query!("SELECT value FROM settings WHERE key = 'round'")
    assert Jason.decode!(round) == 4
    assert %{rows: []} = Repo.query!("SELECT name FROM sqlite_master WHERE name = 'tournaments'")
  end

  describe "advanced features already in use" do
    @advanced_in_use 20_261_030_120_000

    defp before_advanced(pid) do
      Ecto.Migrator.run(Repo, @path, :up,
        to_exclusive: @advanced_in_use,
        dynamic_repo: pid,
        log: false
      )
    end

    defp ui_mode_rows, do: Repo.query!("SELECT value FROM settings WHERE key = 'ui_mode'").rows

    test "a box that moved a fine-tuning knob is given advanced features", %{pid: pid} do
      before_advanced(pid)
      setting("capture_cap_mb", 900)
      upgrade(pid)

      assert ui_mode_rows() == [[~s("full")]]
    end

    test "a box with fair play switched on is given advanced features", %{pid: pid} do
      before_advanced(pid)

      Repo.query!(
        "INSERT INTO fair_play_settings (hall_id, enabled, nodes, inserted_at, updated_at) VALUES (1, 1, 1000000, ?, ?)",
        [@now, @now]
      )

      upgrade(pid)

      assert ui_mode_rows() == [[~s("full")]]
    end

    test "settings saved at their defaults do not count", %{pid: pid} do
      before_advanced(pid)
      setting("capture_cap_mb", 500)
      setting("clock_heartbeat_s", 20)
      setting("auto_suggest", false)
      setting("new_game_on_setup", "unpaired")
      setting("tracker", %{})
      upgrade(pid)

      assert ui_mode_rows() == []
    end

    test "a box that chose simple mode keeps its choice", %{pid: pid} do
      before_advanced(pid)
      setting("ui_mode", "simple")
      setting("capture_cap_mb", 900)
      upgrade(pid)

      assert ui_mode_rows() == [[~s("simple")]]
    end
  end
end
