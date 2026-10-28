defmodule Alnasl.TakeoverCloudTest do
  @moduledoc """
  The cloud's end of a spare box taking over (`Alnasl.Takeover.Cloud`,
  `AlnaslWeb.TakeoverController`): pairing, the lease (grant, renewal,
  expiry, takeover), fencing by epoch, replays that change nothing, and a
  box that only ever reaches its own hall.
  """

  use AlnaslWeb.ConnCase, async: false

  import Alnasl.TakeoverHelpers
  import AlnaslWeb.AccountHelpers, only: [hall_fixture: 1]

  alias Alnasl.Repo
  alias Alnasl.Takeover.{Box, Cloud, Event, RateLimit}

  setup do
    cloud_on()
    %{a: hall_fixture("Hall A"), b: hall_fixture("Hall B")}
  end

  defp event(box, seq, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "#{box.uid}-#{seq}",
        "seq" => seq,
        "kind" => "ply",
        "game" => "#{box.uid}/1",
        "serial" => "12345",
        "ply" => seq,
        "at" => 1_000 + seq,
        "data" => %{"san" => "e4", "where" => %{"t" => 1, "r" => 1, "b" => 1, "n" => 1}}
      },
      extra
    )
  end

  defp api(conn, key), do: put_req_header(conn, "authorization", "Bearer " <> key)

  describe "pairing" do
    test "a code is good once, and the key is kept only as a hash", %{a: a} do
      {:ok, join} = Cloud.create_join(a.id)
      identity = %{"uid" => "box-one-uid", "name" => "Box one", "software" => "Alnasl"}

      assert {:ok, %{key: key, box: box, hall: hall}} = Cloud.redeem(join.code, identity)
      assert hall.id == a.id
      assert String.starts_with?(key, "box-one-uid.")
      refute Repo.get!(Box, box.id).key_hash =~ key
      assert {:ok, %Box{id: id}} = Cloud.authenticate(key)
      assert id == box.id

      assert {:error, :used_or_expired} = Cloud.redeem(join.code, identity)
    end

    test "an expired code is refused, and so is a uid that is not one", %{a: a} do
      {:ok, join} = Cloud.create_join(a.id, DateTime.add(DateTime.utc_now(:second), -3600))
      assert {:error, :used_or_expired} = Cloud.redeem(join.code, %{"uid" => "box-two-uid"})

      {:ok, join} = Cloud.create_join(a.id)
      assert {:error, :bad_request} = Cloud.redeem(join.code, %{"uid" => "<script>"})
    end

    test "a box still in one hall cannot be paired with another", %{a: a, b: b} do
      %{box: box} = other_box(a, "Box")
      {:ok, join} = Cloud.create_join(b.id)
      assert {:error, :elsewhere} = Cloud.redeem(join.code, %{"uid" => box.uid})

      Cloud.revoke(box)
      {:ok, join} = Cloud.create_join(b.id)
      assert {:ok, %{box: moved}} = Cloud.redeem(join.code, %{"uid" => box.uid})
      assert moved.hall_id == b.id
    end

    test "over the wire: the link pairs, a used one is a 410, guessing is rate-limited",
         %{conn: conn, a: a} do
      {:ok, join} = Cloud.create_join(a.id)
      body = %{"uid" => "wire-box-uid", "name" => "Wire"}

      conn1 = post(conn, "/takeover/join/" <> join.code, body)
      assert %{"key" => key, "hall" => "Hall A", "hall_id" => hall_id} = json_response(conn1, 200)
      assert hall_id == a.id
      assert is_binary(key)

      assert json_response(post(build_conn(), "/takeover/join/" <> join.code, body), 410)

      RateLimit.reset()

      statuses =
        for _ <- 1..11,
            do: post(build_conn(), "/takeover/join/AAA-BBBB", body).status

      assert Enum.take(statuses, 10) |> Enum.all?(&(&1 == 410))
      assert List.last(statuses) == 429
    end

    test "not a cloud: every address is a 404 and nothing is read", %{conn: conn, a: a} do
      put_env(:takeover_cloud, false)
      {:ok, join} = Cloud.create_join(a.id)

      assert json_response(
               post(conn, "/takeover/join/" <> join.code, %{"uid" => "abcdefgh"}),
               404
             )

      assert Repo.aggregate(Box, :count) == 0
    end
  end

  describe "the lease" do
    test "granted to the first box, renewed by it, refused to the next while it speaks",
         %{a: a} do
      %{box: one} = other_box(a, "One")
      %{box: two} = other_box(a, "Two")

      assert {:granted, lease, :none} = Cloud.claim(one, nil)
      assert lease.epoch == 1
      assert {:granted, renewed, :self} = Cloud.claim(one, 1)
      assert renewed.epoch == 1
      assert DateTime.compare(renewed.expires_at, lease.expires_at) in [:gt, :eq]

      assert {:denied, held, :held} = Cloud.claim(two, nil)
      assert held.box_id == one.id
    end

    test "a silent holder loses it: the next box gets a new epoch", %{a: a} do
      %{box: one} = other_box(a, "One")
      %{box: two} = other_box(a, "Two")
      {:granted, _lease, :none} = Cloud.claim(one, nil)

      later = DateTime.add(DateTime.utc_now(), 46, :second)
      assert {:granted, lease, :other} = Cloud.claim(two, nil, later)
      assert lease.epoch == 2
      assert lease.box_id == two.id
    end

    test "the holder keeps its lease while nobody took it, even after it ran out", %{a: a} do
      %{box: one} = other_box(a, "One")
      {:granted, _lease, :none} = Cloud.claim(one, nil)
      silence(a.id)
      assert {:granted, lease, :self} = Cloud.claim(one, 1)
      assert lease.epoch == 1
    end

    test "Take over on a spare, and in the cloud, grant at once", %{a: a} do
      %{box: one} = other_box(a, "One")
      %{box: two} = other_box(a, "Two")
      {:granted, _lease, :none} = Cloud.claim(one, nil)

      assert {:granted, lease, :other} = Cloud.take_over(two)
      assert {lease.box_id, lease.epoch} == {two.id, 2}

      assert {:granted, lease, :other} = Cloud.hand_over(a.id, one.id)
      assert {lease.box_id, lease.epoch} == {one.id, 3}
    end

    test "an old epoch is not given back, even when the lease is free", %{a: a} do
      %{box: one} = other_box(a, "One")
      %{box: two} = other_box(a, "Two")
      {:granted, _lease, :none} = Cloud.claim(one, nil)
      {:granted, _lease, :other} = Cloud.take_over(two)
      silence(a.id)

      assert {:denied, _lease, :stale} = Cloud.claim(one, 1)
    end

    test "a removed box loses its lease and its key", %{a: a, conn: conn} do
      %{box: one, key: key} = other_box(a, "One")
      {:granted, _lease, :none} = Cloud.claim(one, nil)
      Cloud.revoke(one)

      assert Cloud.lease(a.id).box_id == nil
      assert {:error, :revoked} = Cloud.authenticate(key)

      conn = conn |> api(key) |> post("/takeover/lease", %{"action" => "claim"})
      assert json_response(conn, 401) == %{"error" => "revoked"}
    end
  end

  describe "the stream" do
    test "a replayed batch is kept once", %{a: a} do
      %{box: one} = other_box(a, "One")
      {:granted, _lease, :none} = Cloud.claim(one, nil)
      batch = for seq <- 1..5, do: event(one, seq)

      assert {:ok, 5} = Cloud.put_events(one, 1, batch)
      assert {:ok, 5} = Cloud.put_events(one, 1, batch)

      assert {:ok, 7} =
               Cloud.put_events(one, 1, Enum.drop(batch, 3) ++ [event(one, 6), event(one, 7)])

      assert Repo.aggregate(Event, :count) == 7

      {:ok, page} = Cloud.restore(one, 1)
      assert Enum.map(page.events, & &1["id"]) == for(seq <- 1..7, do: "#{one.uid}-#{seq}")
    end

    test "a write with a stale epoch is refused, and nothing of it is kept", %{a: a} do
      %{box: one} = other_box(a, "One")
      %{box: two} = other_box(a, "Two")
      {:granted, _lease, :none} = Cloud.claim(one, nil)
      {:granted, _lease, :other} = Cloud.take_over(two)

      assert {:error, :stale} = Cloud.put_events(one, 1, [event(one, 1)])
      assert {:error, :stale} = Cloud.put_state(one, 1, %{"games" => []})
      assert {:error, :stale} = Cloud.restore(one, 1)
      assert Repo.aggregate(Event, :count) == 0

      # The holder in its epoch is fine; in another, not.
      assert {:ok, 1} = Cloud.put_events(two, 2, [event(two, 1)])
      assert {:error, :stale} = Cloud.put_events(two, 3, [event(two, 2)])
    end

    test "over the wire a stale write is a 409 with the lease as it is", %{a: a, conn: conn} do
      %{box: one, key: key} = other_box(a, "One")
      %{box: two} = other_box(a, "Two")
      {:granted, _lease, :none} = Cloud.claim(one, nil)
      {:granted, _lease, :other} = Cloud.take_over(two)

      conn =
        conn |> api(key) |> post("/takeover/events", %{"epoch" => 1, "events" => [event(one, 1)]})

      assert %{"error" => "stale", "lease" => lease} = json_response(conn, 409)
      assert lease["holder"] == "other"
      assert lease["holder_name"] == "Two"
      assert lease["epoch"] == 2
    end

    test "events are validated: a bad one refuses the whole batch", %{a: a} do
      %{box: one} = other_box(a, "One")
      {:granted, _lease, :none} = Cloud.claim(one, nil)

      bad = [
        event(one, 1, %{"kind" => "drop_tables"}),
        event(one, 1, %{"id" => "someone-else-1"}),
        event(one, 1, %{"data" => "not a map"}),
        event(one, 1, %{"ply" => -3}),
        event(one, 1, %{"data" => %{"san" => String.duplicate("x", 20_000)}})
      ]

      for one_bad <- bad do
        assert {:error, :invalid} = Cloud.put_events(one, 1, [event(one, 2), one_bad])
      end

      assert {:error, :invalid} = Cloud.put_events(one, 1, for(s <- 1..501, do: event(one, s)))
      assert Repo.aggregate(Event, :count) == 0
    end

    test "the state marks where the events after it start", %{a: a} do
      %{box: one} = other_box(a, "One")
      {:granted, _lease, :none} = Cloud.claim(one, nil)
      {:ok, 2} = Cloud.put_events(one, 1, [event(one, 1), event(one, 2)])
      :ok = Cloud.put_state(one, 1, %{"games" => [%{"key" => "g"}]})
      {:ok, 3} = Cloud.put_events(one, 1, [event(one, 3)])

      {:ok, page} = Cloud.restore(one, 1)
      assert page.state == %{"games" => [%{"key" => "g"}]}
      assert Enum.map(page.events, & &1["id"]) == ["#{one.uid}-3"]
      assert page.next == nil
    end

    test "event payloads stay data on the way back out", %{a: a} do
      %{box: one} = other_box(a, "One")
      {:granted, _lease, :none} = Cloud.claim(one, nil)
      script = "<script>alert(1)</script>"
      {:ok, 1} = Cloud.put_events(one, 1, [event(one, 1, %{"data" => %{"san" => script}})])
      {:ok, page} = Cloud.restore(one, 1)
      assert [%{"data" => %{"san" => ^script}}] = page.events
    end
  end

  describe "scoping" do
    test "a box of hall A never touches hall B", %{a: a, b: b, conn: conn} do
      %{box: in_a, key: key_a} = other_box(a, "A box")
      %{box: in_b} = other_box(b, "B box")
      {:granted, _lease, :none} = Cloud.claim(in_b, nil)
      {:ok, 1} = Cloud.put_events(in_b, 1, [event(in_b, 1)])
      :ok = Cloud.put_state(in_b, 1, %{"secret" => "hall B's"})

      # Hall A's lease is its own: B's holder does not stop A's box from getting it.
      conn1 = conn |> api(key_a) |> post("/takeover/lease", %{"action" => "claim"})
      assert %{"granted" => true, "lease" => %{"epoch" => 1}} = json_response(conn1, 200)

      # Restoring gives hall A's nothing of hall B's.
      conn2 = build_conn() |> api(key_a) |> get("/takeover/restore", %{"epoch" => "1"})
      assert %{"state" => nil, "events" => []} = json_response(conn2, 200)

      # Writing with B's epoch from A's key writes into A, or nowhere.
      conn3 =
        build_conn()
        |> api(key_a)
        |> post("/takeover/events", %{"epoch" => 1, "events" => [event(in_b, 2)]})

      assert json_response(conn3, 422)
      assert Repo.aggregate(Event, :count) == 1

      # The cloud's "Take over" for hall A cannot name hall B's box.
      assert {:error, :not_found} = Cloud.hand_over(a.id, in_b.id)
      assert Cloud.lease(b.id).box_id == in_b.id
      assert in_a.hall_id == a.id
    end

    test "no key, a wrong key, a key in the URL: 401", %{conn: conn, a: a} do
      %{key: key} = other_box(a, "One")

      assert json_response(post(conn, "/takeover/lease", %{"action" => "claim"}), 401)

      assert build_conn()
             |> api(key <> "x")
             |> post("/takeover/lease", %{"action" => "claim"})
             |> json_response(401)

      assert build_conn()
             |> post("/takeover/lease", %{"action" => "claim", "key" => key})
             |> json_response(401)
    end

    test "one box asking too often is told to wait", %{conn: conn, a: a} do
      %{key: key} = other_box(a, "One")

      statuses =
        for _ <- 1..241 do
          build_conn()
          |> api(key)
          |> post("/takeover/lease", %{"action" => "standby"})
          |> Map.get(:status)
        end

      assert Enum.count(statuses, &(&1 == 200)) == 240
      assert List.last(statuses) == 429
      _ = conn
    end
  end
end
