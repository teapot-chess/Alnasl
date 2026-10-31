defmodule Alnasl.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The database lives in the data directory; make sure there is one.
    case Application.get_env(:alnasl, Alnasl.Repo)[:database] do
      path when is_binary(path) -> File.mkdir_p!(Path.dirname(path))
      _memory -> :ok
    end

    tidy_release_tmp()

    children =
      children(
        autostart: Application.get_env(:alnasl, :autostart, true),
        local_boards: Alnasl.Boards.local?()
      )

    opts = [strategy: :one_for_one, name: Alnasl.Supervisor]

    with {:ok, _pid} = started <- Supervisor.start_link(children, opts) do
      # Crash reports onto the System page, not into a third party's
      # dashboard (`Alnasl.Ops.ErrorReports`). Off in test.
      if Application.get_env(:alnasl, :error_reports, true) do
        Alnasl.Ops.ErrorReports.LoggerHandler.install()
      end

      started
    end
  end

  @doc """
  What the box runs. `local_boards: false` is a box with no boards of its
  own (`ALNASL_NO_LOCAL_BOARDS`, the hosted server): no buses, no serial
  drivers - its boards arrive from bridges, and everything after the
  board's own process is the same.
  """
  def children(opts) do
    autostart? = Keyword.fetch!(opts, :autostart)
    local? = Keyword.fetch!(opts, :local_boards)

    # The launcher's Details panel: this start's secret (and its file, when
    # no launcher handed one over), the CPU sample, the slow queries. Before
    # the endpoint, which asks it.
    # The box asks GitHub for a newer version of itself; a server is
    # updated by whoever deploys it, and has no business asking.
    [
      AlnaslWeb.Telemetry,
      Alnasl.Repo,
      # Always: the box is an appliance, not a deployment with a migration step.
      {Ecto.Migrator,
       repos: Application.fetch_env!(:alnasl, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: Alnasl.PubSub},
      {Registry, keys: :unique, name: Alnasl.BoardRegistry},
      # The bridges' links, and the boards that arrive over them.
      {Registry, keys: :unique, name: Alnasl.BridgeRegistry},
      {Registry, keys: :unique, name: Alnasl.RemoteRegistry},
      {Task.Supervisor, name: Alnasl.TaskSupervisor},
      Alnasl.Recorder,
      Alnasl.DoorGuard,
      # The cloud's count of who asks how often (`Alnasl.Takeover`).
      Alnasl.Takeover.RateLimit,
      # Writes crash reports for the logger handler installed in start/2.
      Alnasl.Ops.ErrorReports.Recorder,
      # A snapshot of the database off the box, encrypted; idle unless
      # configured (`OFFSITE_BACKUP_*`).
      Alnasl.Ops.OffsiteBackup.Scheduler
    ] ++
      if(Alnasl.FairPlay.Live.enabled?(), do: [Alnasl.FairPlay.Live], else: []) ++
      if(local?,
        do:
          [
            {Alnasl.Updates.Checker, timer: Application.get_env(:alnasl, :updates_timer, true)},
            Arkab.Drivers
          ] ++ takeover_link(),
        else: []
      ) ++
      [
        {DynamicSupervisor,
         name: Alnasl.BoardSupervisor, strategy: :one_for_one, max_restarts: 100, max_seconds: 60},
        Alnasl.Finder,
        Alnasl.LauncherDetails
      ] ++
      if(autostart?,
        do:
          Alnasl.Destination.child_specs() ++
            [Alnasl.OpenPairings.Poller, {Task, &Alnasl.Boards.start_all/0}],
        else: []
      ) ++
      [AlnaslWeb.Endpoint]
  end

  # A box paired with a hall in the cloud streams it there, or stands by as
  # its spare (`Alnasl.Takeover.Link`). Not in the tests, which step it by
  # hand.
  defp takeover_link do
    if Application.get_env(:alnasl, :takeover_link, true),
      do: [Alnasl.Takeover.Link],
      else: []
  end

  @impl true
  def config_change(changed, _new, removed) do
    AlnaslWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # A release writes the configuration it starts with to a file in
  # RELEASE_TMP, a new one every start, and never takes one away. They hold
  # the cookie secret and they add up; the one this start is using stays.
  defp tidy_release_tmp do
    with tmp when is_binary(tmp) <- System.get_env("RELEASE_TMP"),
         mine when is_binary(mine) <- System.get_env("RELEASE_SYS_CONFIG") do
      for file <- Path.wildcard(Path.join(Path.expand(tmp), "alnasl-*.runtime.config")),
          Path.basename(file, ".config") != Path.basename(mine) do
        File.rm(file)
      end
    end

    :ok
  end

  # Tests migrate through the `mix test` alias, under the sandbox.
  defp skip_migrations?, do: Application.get_env(:alnasl, :skip_migrations, false)
end
