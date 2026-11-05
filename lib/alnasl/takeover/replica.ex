defmodule Alnasl.Takeover.Replica do
  @moduledoc """
  The second copy: the active box's whole database, replicated by Litestream
  about once a second to a store the box writes to (S3-compatible, or SFTP,
  or a directory), so a spare that takes over loses seconds instead of
  whatever the cloud had not been told yet. docs/takeover.md, "The replica".

  The cloud's stream (`Alnasl.Takeover.Stream`) is still what a takeover
  starts from: it says who holds the hall and it is fenced by the lease. The
  replica only tops it up. It is read once, at a takeover, and a replica
  that cannot be read, is late, or belongs to a schema this box cannot make
  sense of changes nothing: the takeover goes on with the cloud's copy.

  ## Where it goes

  `ALNASL_TAKEOVER_REPLICA` is the base (`s3://bucket/halls/club`); each
  box writes under its own uid (`s3://bucket/halls/club/<uid>`), so a box
  that was superseded and is still running somewhere offline writes over
  nobody's copy but its own. A spare reads the one of the box that ran the
  hall last: the uid in the newest event the cloud gave it.

  The store's credentials are Litestream's own environment
  (`LITESTREAM_ACCESS_KEY_ID`, `LITESTREAM_SECRET_ACCESS_KEY`): Alnasl
  never reads them, writes them or puts them in the configuration file it
  makes. On the Pi image systemd hands them to the service from a root-only
  file; nobody types them into a page.

  ## Who replicates

  An active box that is paired with a hall (`Alnasl.Takeover.Replicator`
  runs `litestream replicate` while that is so, and stops it the moment the
  box steps down or stands by). A spare, a superseded box and an unpaired
  one replicate nothing.
  """

  require Logger

  alias Alnasl.Paths
  alias Alnasl.Takeover.Snapshot

  @schemes ~w(s3 gs abs sftp file)
  @uid ~r/\A[A-Za-z0-9_-]{1,64}\z/

  # --- configuration ---------------------------------------------------------------

  @doc """
  The replica's settings, or `nil` when there is none: `%{url, endpoint,
  region, sync}`. From `config :alnasl, :takeover_replica` (runtime.exs,
  `ALNASL_TAKEOVER_REPLICA*`).
  """
  def config do
    case Application.get_env(:alnasl, :takeover_replica) do
      %{url: url} = config when is_binary(url) ->
        if valid_url?(url), do: Map.merge(%{endpoint: nil, region: nil, sync: "1s"}, config)

      _none ->
        nil
    end
  end

  @doc "Whether this box has a replica to write to and a Litestream to write with."
  def enabled?, do: config() != nil and runner().available?()

  @doc false
  def valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in @schemes -> not String.contains?(url, ["\n", "\r"])
      _other -> false
    end
  end

  def valid_url?(_other), do: false

  @doc false
  def runner,
    do: Application.get_env(:alnasl, :takeover_replica_runner, Alnasl.Takeover.Replica.Litestream)

  @doc "Where the box `uid` keeps its copy: the base and the uid."
  def url_for(%{url: base}, uid) when is_binary(uid) do
    if Regex.match?(@uid, uid), do: String.trim_trailing(base, "/") <> "/" <> uid
  end

  @doc """
  Litestream's configuration for one database and its replica. YAML, every
  value quoted; no credentials (Litestream reads those from its
  environment).
  """
  def yaml(config, db_path, replica_url) do
    extra =
      if String.starts_with?(replica_url, "s3://") do
        [
          config.endpoint && ["        endpoint: ", yq(config.endpoint), "\n"],
          config.endpoint && "        force-path-style: true\n",
          config.region && ["        region: ", yq(config.region), "\n"]
        ]
      else
        []
      end

    IO.iodata_to_binary([
      "# Made by Alnasl (Alnasl.Takeover.Replica); written again at every start.\n",
      "dbs:\n",
      "  - path: ",
      yq(db_path),
      "\n",
      "    replica:\n",
      "        url: ",
      yq(replica_url),
      "\n",
      "        sync-interval: ",
      yq(config.sync),
      "\n",
      Enum.reject(extra, &(&1 in [nil, false]))
    ])
  end

  defp yq(text), do: Jason.encode!(to_string(text))

  @doc false
  def config_path, do: Path.join(Paths.data(), "litestream.yml")

  @doc """
  Writes the configuration with which this box (`uid`) replicates its own
  database. `{:ok, path}`, or `:off` when there is nothing to replicate to.
  """
  def write_config(uid) do
    with %{} = config <- config(),
         url when is_binary(url) <- url_for(config, uid) do
      path = config_path()
      write_private(path, yaml(config, database(), url))
      {:ok, path}
    else
      _none -> :off
    end
  end

  defp write_private(path, text) do
    tmp = path <> ".new"
    File.write!(tmp, "")
    _ = File.chmod(tmp, 0o600)
    File.write!(tmp, text)
    File.rename!(tmp, path)
  end

  defp database, do: Application.fetch_env!(:alnasl, Alnasl.Repo)[:database]

  # --- reading another box's copy ---------------------------------------------------

  @doc """
  The uid of the box whose copy a takeover should read: the one that sent
  the newest event the cloud had, else the one that sent the state.
  """
  def source_uid(state, events) do
    from_event =
      events
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{"game" => key} when is_binary(key) ->
          case String.split(key, "/") do
            [uid, _id] -> uid
            _other -> nil
          end

        _other ->
          nil
      end)

    uid = from_event || (is_map(state) && state["box"])
    if is_binary(uid) and Regex.match?(@uid, uid), do: uid
  end

  @doc """
  At a takeover: the state of the box `uid` as its replica has it - the
  same shape as `Alnasl.Takeover.Snapshot.build/1` - or `nil`, whatever
  went wrong (logged). Never raises; never takes longer than `timeout` ms
  (`ALNASL_TAKEOVER_REPLICA_TIMEOUT`, 30 s: the lease is 45).
  """
  def fetch(uid, timeout \\ timeout()) do
    with %{} = config <- config(),
         true <- runner().available?() || :no_litestream,
         url when is_binary(url) <- url_for(config, uid || "") || :bad_uid do
      task =
        Task.async(fn ->
          try do
            restore_and_read(config, url, uid)
          rescue
            error -> unreadable(Exception.message(error))
          catch
            kind, why -> unreadable("#{kind}: #{inspect(why)}")
          end
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        nil ->
          Logger.warning("takeover: the replica took longer than #{timeout} ms; going on without")
          nil
      end
    else
      nil -> nil
      why -> tap(nil, fn _ -> Logger.warning("takeover: no replica read (#{why})") end)
    end
  end

  defp timeout, do: Application.get_env(:alnasl, :takeover_replica_timeout_ms, 30_000)

  defp restore_and_read(config, url, uid) do
    dir = Path.join(Paths.data(), "replica-restore")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    source = Path.join(dir, "source.db")
    out = Path.join(dir, "restored.db")
    yml = Path.join(dir, "litestream.yml")
    write_private(yml, yaml(config, source, url))

    try do
      case runner().restore(yml, source, out) do
        :ok ->
          if File.exists?(out), do: read(out, uid), else: missing()

        {:error, why} ->
          Logger.warning("takeover: restoring the replica failed: #{why}")
          nil
      end
    rescue
      error -> unreadable(Exception.message(error))
    after
      File.rm_rf(dir)
    end
  end

  defp missing do
    Logger.warning("takeover: the box that ran the hall has no replica (yet)")
    nil
  end

  @doc """
  The state of the box `uid`, read out of a copy of its database at `path`.
  The copy is brought up to this box's schema first (it may be an older
  Alnasl's): it is a throwaway file, and only then do the queries mean the
  same here as there. `nil` when it cannot be read.
  """
  def read(path, uid) do
    repo_opts = [
      name: nil,
      database: path,
      pool: DBConnection.ConnectionPool,
      pool_size: 1,
      log: false
    ]

    previous = Alnasl.Repo.get_dynamic_repo()

    # Not linked: a copy that will not open must not take the caller with it.
    case with_trap(fn -> Alnasl.Repo.start_link(repo_opts) end) do
      {:ok, pid} ->
        try do
          Alnasl.Repo.put_dynamic_repo(pid)
          migrate(pid)
          Snapshot.build(uid)
        rescue
          error -> unreadable(Exception.message(error))
        catch
          :exit, why -> unreadable(inspect(why))
        after
          Alnasl.Repo.put_dynamic_repo(previous)
          Process.unlink(pid)
          Supervisor.stop(pid)
        end

      other ->
        unreadable(inspect(other))
    end
  end

  @doc false
  # This Alnasl's migrations on the database `pid` (a dynamic repo). The
  # migration modules are loaded already - the box ran them at its start -
  # and loading them again would say so once per migration in the log.
  def migrate(pid) do
    ignore? = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(Alnasl.Repo, :up, all: true, dynamic_repo: pid, log: false)
    after
      Code.put_compiler_option(:ignore_module_conflict, ignore?)
    end
  end

  defp with_trap(fun) do
    trap? = Process.flag(:trap_exit, true)

    try do
      fun.()
    catch
      :exit, why -> {:error, why}
    after
      Process.flag(:trap_exit, trap?)
    end
  end

  defp unreadable(why) do
    Logger.warning("takeover: the replica could not be read: #{why}")
    nil
  end
end
