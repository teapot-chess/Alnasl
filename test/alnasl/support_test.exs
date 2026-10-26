defmodule Alnasl.SupportTest do
  @moduledoc """
  Support uploads as the context keeps them: off until somebody is named,
  text only and at most 2 MB, five an hour from one address, a code nobody
  else alive holds, and gone after thirty days.
  """

  use Alnasl.DataCase, async: false

  import AlnaslWeb.AccountHelpers, only: [support_admins: 1]

  alias Alnasl.Support
  alias Alnasl.Support.Upload

  @t0 ~U[2026-10-26 12:00:00Z]

  setup do
    support_admins(["help@example.org"])
    :ok
  end

  defp send_text(text \\ "log line\n", ip \\ "203.0.113.7", opts \\ []),
    do: Support.receive_upload(text, %{}, ip, Keyword.put_new(opts, :now, @t0))

  # A code generator that says what it is told, in order.
  defp codes(list) do
    {:ok, agent} = Agent.start_link(fn -> list end)
    fn -> Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end) end
  end

  describe "switched on by a name" do
    test "nobody named: every upload refused, nobody an admin" do
      support_admins([])
      refute Support.enabled?()
      assert send_text() == {:error, :disabled}
      refute Support.admin?(%{email: "help@example.org"})
    end

    test "the named address, in any case, and nobody else" do
      assert Support.admin?(%{email: "help@example.org"})
      assert Support.admin?(%{email: "Help@Example.org"})
      assert Support.admin?(%{user: %{email: "help@example.org"}})
      refute Support.admin?(%{email: "help@example.org.evil"})
      refute Support.admin?(%{user: nil})
      refute Support.admin?(nil)
    end
  end

  describe "what is accepted" do
    test "a code of six digits, expiring in thirty days" do
      assert {:ok, %Upload{code: code, expires_at: expires}} = send_text()
      assert code =~ ~r/\A\d{6}\z/
      assert DateTime.diff(expires, @t0, :day) == 30
    end

    test "2 MB is accepted, a byte more is not" do
      assert {:ok, _} = send_text(String.duplicate("a", Support.max_bytes()))
      assert send_text(String.duplicate("a", Support.max_bytes() + 1)) == {:error, :too_large}
    end

    test "text only: no invalid UTF-8, no NUL, nothing empty" do
      assert send_text(<<0xFF, 0xFE, 0x00>>) == {:error, :not_text}
      assert send_text("a\0b") == {:error, :not_text}
      assert send_text("") == {:error, :empty}
    end

    test "what the box says about itself is cut short and cleaned" do
      meta = %{box_id: "box-1\n\e[31m" <> String.duplicate("x", 300), version: "0.11.0"}
      assert {:ok, upload} = Support.receive_upload("x", meta, "203.0.113.7", now: @t0)
      refute upload.box_id =~ "\n"
      assert String.length(upload.box_id) <= 100
      assert upload.version == "0.11.0"
    end
  end

  describe "codes" do
    test "a code already held by a live upload is never handed out twice" do
      next = codes(["111111", "111111", "111111", "222222"])
      assert {:ok, %{code: "111111"}} = send_text("one", "203.0.113.7", code: next)
      assert {:ok, %{code: "222222"}} = send_text("two", "203.0.113.7", code: next)
    end

    test "an expired upload's code is free again" do
      next = codes(["333333", "333333"])
      assert {:ok, _} = send_text("old", "203.0.113.7", code: next)
      later = DateTime.add(@t0, 31, :day)
      assert {:ok, %{code: "333333"}} = send_text("new", "203.0.113.7", code: next, now: later)
    end

    test "random codes keep their leading zeros" do
      for _ <- 1..200, do: assert(Support.random_code() =~ ~r/\A\d{6}\z/)
    end
  end

  describe "the rate limit" do
    test "five an hour from one address, then refused; another address is not" do
      for _ <- 1..5, do: assert({:ok, _} = send_text())
      assert send_text() == {:error, :rate_limited}
      assert {:ok, _} = send_text("x", "198.51.100.1")
    end

    test "an hour later the address may send again" do
      for _ <- 1..5, do: assert({:ok, _} = send_text())
      assert {:ok, _} = send_text("x", "203.0.113.7", now: DateTime.add(@t0, 3601))
    end

    test "the address itself is not stored" do
      {:ok, upload} = send_text()
      refute Repo.get!(Upload, upload.id).ip_hash =~ "203.0.113.7"
    end
  end

  describe "expiry" do
    test "expired uploads are not found, not listed, and purged" do
      {:ok, upload} = send_text()
      later = DateTime.add(@t0, 30 * 86_400)

      assert Support.get_live(upload.code, @t0).id == upload.id
      assert Support.get_live(upload.code, later) == nil
      assert Support.list_recent(50, later) == []

      assert Support.purge_expired(later) == 1
      assert Repo.aggregate(Upload, :count) == 0
    end

    test "a new upload purges the expired ones" do
      {:ok, _} = send_text()
      {:ok, _} = send_text("y", "198.51.100.1", now: DateTime.add(@t0, 31, :day))
      assert Repo.aggregate(Upload, :count) == 1
    end
  end
end
