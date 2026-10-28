defmodule Alnasl.Takeover.RateLimit do
  @moduledoc """
  A count per key and per window, in memory: enough to keep a box that has
  lost its mind - or somebody guessing pairing codes - from making the
  cloud busy. Counted in fixed windows; a restart forgets them, which is
  fine for this.

  A box asks every five seconds and sends a batch after a burst of moves;
  `AlnaslWeb.TakeoverController` allows it 240 requests a minute, and an
  address 10 attempts at a pairing code in ten minutes.
  """

  use GenServer

  @table :alnasl_takeover_rate

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, write_concurrency: true])
    :timer.send_interval(60_000, :sweep)
    {:ok, nil}
  end

  @doc "`:ok`, or `{:error, seconds}` until the window is over."
  def hit(key, limit, window_ms, now \\ System.system_time(:millisecond)) do
    window = div(now, window_ms)

    if :ets.whereis(@table) == :undefined do
      :ok
    else
      count =
        :ets.update_counter(@table, {key, window_ms, window}, 1, {{key, window_ms, window}, 0})

      if count <= limit,
        do: :ok,
        else: {:error, max(div((window + 1) * window_ms - now, 1000), 1)}
    end
  end

  @doc false
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)

    :ets.select_delete(@table, [
      {{{:_, :"$1", :"$2"}, :_}, [{:<, {:*, {:+, :"$2", 1}, :"$1"}, now}], [true]}
    ])

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
