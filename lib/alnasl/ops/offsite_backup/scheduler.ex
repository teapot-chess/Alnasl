defmodule Alnasl.Ops.OffsiteBackup.Scheduler do
  @moduledoc """
  Sends a snapshot off the box (`Alnasl.Ops.OffsiteBackup.push/1`): ten
  minutes after boot, then every day - and every hour instead while the
  last attempt failed, so a bucket that was down at three in the morning
  has the copy by four rather than by tomorrow.

  Ten minutes, not at once, because a deploy is the one moment the box has
  better things to do than compress its own database, and a restart loop
  should not become an upload loop.

  Idle - started, never ticking - when off-site backups are not configured,
  and in the test environment (`interval: :disabled`), where `push/1` is
  called directly.
  """
  use GenServer

  alias Alnasl.Ops.OffsiteBackup

  @interval :timer.hours(24)
  @retry :timer.hours(1)
  @first_run :timer.minutes(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:alnasl, :offsite_backup_interval, @interval)
      end)

    if interval != :disabled and OffsiteBackup.enabled?() do
      Process.send_after(self(), :tick, @first_run)
    end

    {:ok, %{interval: interval, retry: Keyword.get(opts, :retry, @retry)}}
  end

  @impl true
  def handle_info(:tick, state) do
    # push/1 records its own failures and never raises for the ordinary ones;
    # this catch is for the extraordinary, so the timer survives them.
    result =
      try do
        OffsiteBackup.push()
      rescue
        _ -> :error
      end

    Process.send_after(self(), :tick, next_in(result, state))
    {:noreply, state}
  end

  @doc false
  def next_in({:ok, _key}, state), do: state.interval
  def next_in(_failed, state), do: min(state.retry, state.interval)
end
