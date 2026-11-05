defmodule Alnasl.FakeLitestream do
  @moduledoc """
  Litestream for the tests (`config :alnasl, :takeover_replica_runner`):
  nothing runs. `start/1` and `stop/1` tell the test process; `restore/3`
  copies the database the test made (`:fake_litestream_source`) to where
  the real one would write the restored copy, or writes nothing when there
  is none, as `-if-replica-exists` would.
  """

  def available?, do: Application.get_env(:alnasl, :fake_litestream_available, true)

  def start(config_path) do
    handle = make_ref()
    tell({:litestream, :start, config_path, handle})
    {:ok, handle}
  end

  def stop(handle) do
    tell({:litestream, :stop, handle})
    :ok
  end

  def restore(config_path, _db, out) do
    tell({:litestream, :restore, File.read!(config_path)})

    case Application.get_env(:alnasl, :fake_litestream_source) do
      nil ->
        :ok

      {:error, why} ->
        {:error, why}

      source ->
        File.cp!(source, out)
        :ok
    end
  end

  defp tell(message) do
    case Application.get_env(:alnasl, :fake_litestream_owner) do
      pid when is_pid(pid) -> send(pid, message)
      _nobody -> :ok
    end
  end
end
