defmodule Alnasl.RateLimitClaimTest do
  use ExUnit.Case, async: false

  alias Alnasl.Takeover.RateLimit

  setup do
    RateLimit.reset()
    :ok
  end

  test "a burst of parallel attempts cannot all pass" do
    results =
      1..60
      |> Task.async_stream(fn _ -> RateLimit.claim(:burst, 10, 60_000, 1_000) end,
        max_concurrency: 60
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 10
  end

  test "a refund gives the attempt back, and cannot go below nothing" do
    {:ok, ref} = RateLimit.claim(:refund, 1, 60_000, 1_000)
    assert {:error, _} = RateLimit.claim(:refund, 1, 60_000, 1_000)
    RateLimit.refund(ref)
    assert {:ok, _} = RateLimit.claim(:refund, 1, 60_000, 1_000)
    RateLimit.refund(ref)
    RateLimit.refund(ref)
    RateLimit.refund(ref)
    assert {:ok, _} = RateLimit.claim(:refund, 1, 60_000, 1_000)
  end
end
