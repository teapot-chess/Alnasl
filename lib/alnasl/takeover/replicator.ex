defmodule Alnasl.Takeover.Replicator do
  @moduledoc """
  Runs `litestream replicate` while this box is the active box of a hall and
  has a replica to write to (`Alnasl.Takeover.Replica`), and stops it the
  moment that is no longer so: a box that steps down, stands by, leaves its
  hall or is removed from it replicates nothing.

  It listens on the `"takeover"` topic, which says when the box's record
  changed, and looks again every minute anyway. A Litestream that exits is
  started again after `@retry_ms`, not at once: one that cannot reach its
  store would otherwise do nothing but restart.
  """

  use GenServer

  require Logger

  alias Alnasl.{Log, Takeover}
  alias Alnasl.Takeover.Replica

  @retry_ms 10_000
  @look_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  `%{state: :off | :running | :waiting, uid, last}`: `:waiting` after it
  exited and before it is tried again; `last` its last line of output.
  """
  def status do
    case Process.whereis(__MODULE__) do
      nil -> %{state: :off, uid: nil, last: nil}
      pid -> GenServer.call(pid, :status, 2_000)
    end
  catch
    :exit, _busy -> %{state: :off, uid: nil, last: nil}
  end

  @doc "Looks again now (tests; the box's record changing does it by itself)."
  def check, do: GenServer.call(__MODULE__, :check)

  @impl true
  def init(_opts) do
    # So that `terminate/2` runs at shutdown and Litestream is stopped, not orphaned.
    Process.flag(:trap_exit, true)
    Takeover.subscribe()
    send(self(), :look)
    {:ok, %{handle: nil, uid: nil, waiting?: false, last: nil}}
  end

  @impl true
  def handle_call(:status, _from, st) do
    state =
      cond do
        st.handle -> :running
        st.waiting? -> :waiting
        true -> :off
      end

    {:reply, %{state: state, uid: st.uid, last: st.last}, st}
  end

  def handle_call(:check, _from, st), do: {:reply, :ok, check(st)}

  @impl true
  def handle_info({:takeover, _what}, st), do: {:noreply, check(st)}

  def handle_info(:look, st) do
    Process.send_after(self(), :look, @look_ms)
    {:noreply, check(st)}
  end

  def handle_info(:retry, st), do: {:noreply, check(%{st | waiting?: false})}

  def handle_info({handle, {:data, {_eol, line}}}, %{handle: handle} = st),
    do: {:noreply, %{st | last: String.slice(line, 0, 300)}}

  def handle_info({handle, {:exit_status, status}}, %{handle: handle} = st) do
    Logger.warning("takeover: litestream exited (#{status}): #{st.last}")
    Log.add(:warn, "takeover.replica_stopped", %{status: status})
    Process.send_after(self(), :retry, retry_ms())
    {:noreply, %{st | handle: nil, uid: nil, waiting?: true}}
  end

  def handle_info(_other, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, %{handle: handle}) when handle != nil, do: Replica.runner().stop(handle)
  def terminate(_reason, _st), do: :ok

  defp retry_ms, do: Application.get_env(:alnasl, :takeover_replica_retry_ms, @retry_ms)

  # --- what should run ----------------------------------------------------------------

  defp check(st) do
    want = wanted()

    cond do
      st.handle != nil and want == st.uid ->
        st

      st.handle != nil ->
        Replica.runner().stop(st.handle)
        Logger.info("takeover: replication stopped")
        check(%{st | handle: nil, uid: nil})

      want == nil or st.waiting? ->
        st

      true ->
        start(st, want)
    end
  end

  # The uid to replicate as, or nil.
  defp wanted do
    with %{"uid" => uid} = config <- Takeover.config(),
         :active <- Takeover.phase(config),
         true <- Replica.enabled?() do
      uid
    else
      _no -> nil
    end
  end

  defp start(st, uid) do
    with {:ok, path} <- Replica.write_config(uid),
         {:ok, handle} <- Replica.runner().start(path) do
      Logger.info("takeover: replicating the database (litestream)")
      %{st | handle: handle, uid: uid, last: nil}
    else
      other ->
        Logger.warning("takeover: litestream did not start: #{inspect(other)}")
        Process.send_after(self(), :retry, retry_ms())
        %{st | waiting?: true}
    end
  rescue
    error ->
      Logger.warning("takeover: litestream did not start: #{Exception.message(error)}")
      Process.send_after(self(), :retry, retry_ms())
      %{st | waiting?: true}
  end
end
