defmodule Alnasl.Takeover.Replica.Litestream do
  @moduledoc """
  The Litestream binary, run by Alnasl: `litestream replicate` as a port
  while the box is active, `litestream restore` once at a takeover.

  The binary is `ALNASL_LITESTREAM` (the Pi image sets
  `/usr/local/bin/litestream`, pinned by version and SHA-256 at build
  time), else whatever `litestream` is on the PATH. Nothing is downloaded
  here: a box without it simply does not replicate.

  The tests use a stand-in with the same four functions
  (`config :alnasl, :takeover_replica_runner`).
  """

  @doc """
  The binary's path, or `nil`. `ALNASL_LITESTREAM` must be an absolute path
  to an existing file called `litestream` (`litestream.exe` on Windows):
  the setting names a program, not a command line.
  """
  def binary do
    case Application.get_env(:alnasl, :litestream) do
      path when is_binary(path) and path != "" -> if trusted?(path), do: path
      _unset -> System.find_executable("litestream")
    end
  end

  @doc false
  def trusted?(path) do
    Path.type(path) == :absolute and Path.basename(path) in ~w(litestream litestream.exe) and
      File.regular?(path)
  end

  def available?, do: binary() != nil

  @doc """
  Starts `litestream replicate -config <path>`. Its output comes to the
  caller as `{port, {:data, {:eol | :noeol, line}}}`, its end as
  `{port, {:exit_status, n}}`.
  """
  def start(config_path) do
    case binary() do
      nil ->
        {:error, :no_litestream}

      bin ->
        port =
          Port.open({:spawn_executable, bin}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, 1024},
            args: ["replicate", "-config", config_path]
          ])

        {:ok, port}
    end
  end

  @doc """
  Stops it: SIGTERM, on which Litestream syncs what it has not sent yet and
  exits. Closing the port alone would leave it running.
  """
  def stop(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> kill(pid)
      nil -> :ok
    end

    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp kill(pid) do
    case :os.type() do
      {:win32, _} -> System.cmd("taskkill", ["/PID", "#{pid}", "/F"], stderr_to_stdout: true)
      _unix -> System.cmd("kill", ["-TERM", "#{pid}"], stderr_to_stdout: true)
    end

    :ok
  rescue
    _error -> :ok
  end

  @doc """
  Restores the database `db` of the configuration at `config_path` to
  `out`. `:ok` also when the replica does not exist (`-if-replica-exists`):
  the caller looks for `out`.
  """
  def restore(config_path, db, out) do
    case binary() do
      nil ->
        {:error, "no litestream"}

      bin ->
        args = ["restore", "-config", config_path, "-if-replica-exists", "-o", out, db]

        case System.cmd(bin, args, stderr_to_stdout: true) do
          {_out, 0} -> :ok
          {text, status} -> {:error, "exit #{status}: #{last_line(text)}"}
        end
    end
  end

  defp last_line(text),
    do: text |> String.trim() |> String.split("\n") |> List.last() |> String.slice(0, 300)
end
