defmodule Alnasl.Takeover do
  @moduledoc """
  A spare box takes over a hall. The whole design is docs/takeover.md; this
  module is the box's end of it, and the few things both ends share.

  ## The two ends

  * **The cloud** (`Alnasl.Takeover.Cloud`, the hosted server, or any
    Alnasl with `ALNASL_TAKEOVER_CLOUD=1`) keeps, per hall: the boxes paired
    with it, one lease (which box runs the hall, and its epoch), the events
    the active box streamed, and its last state.
  * **A box** (this module, `Alnasl.Takeover.Link`, `Alnasl.Takeover.Stream`)
    is paired with one hall of one cloud. It is *active* - it reads the
    boards and streams what happens - or a *spare*, standing by. An active
    box that learns another box has the lease steps down: *superseded*.

  The hall box stays the primary and works offline: an active box that
  cannot reach the cloud keeps running the hall and queues what it streams.

  ## Where the box keeps it

  The setting `"takeover"` (a map: the cloud's address, the box's uid, the
  hall's name, the role, the epoch it holds, whether it was superseded),
  and the key in its own file, `takeover.key`, in the data directory: never
  in the database, never in a log, never on a page.
  """

  alias Alnasl.{Paths, Repo, Settings}
  alias Alnasl.Takeover.Queued

  @topic "takeover"
  @setting "takeover"
  @roles ~w(active spare)

  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  @doc false
  def notify(message \\ :changed),
    do: Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, {:takeover, message})

  def roles, do: @roles

  # --- configuration ---------------------------------------------------------------

  @doc """
  Whether this Alnasl hands out leases and keeps streams: the hosted server,
  or one started with `ALNASL_TAKEOVER_CLOUD=1`. Elsewhere the cloud's
  addresses answer 404.
  """
  def cloud? do
    case Application.get_env(:alnasl, :takeover_cloud) do
      nil -> Alnasl.edition() == :server
      value -> value == true
    end
  end

  @doc "How long a box may be silent before its lease is free (`ALNASL_TAKEOVER_LEASE_SECONDS`, 45)."
  def lease_ms, do: Application.get_env(:alnasl, :takeover_lease_seconds, 45) * 1000

  @doc "How many events a box queues before it stops queueing (`ALNASL_TAKEOVER_QUEUE_CAP`)."
  def queue_cap, do: Application.get_env(:alnasl, :takeover_queue_cap, 50_000)

  @doc "The cloud a bare code is for (`ALNASL_TAKEOVER_SERVER`)."
  def default_server,
    do: Application.get_env(:alnasl, :takeover_server, "https://alnasl.zerotwo.cloud")

  @doc """
  The role a box starts with when it has none of its own yet
  (`ALNASL_TAKEOVER_ROLE`, "active" when unset). Once a box has a role -
  given when it is paired, or by a takeover - that one counts: a spare that
  took over stays active across a restart.
  """
  def initial_role do
    case Application.get_env(:alnasl, :takeover_role) do
      role when role in @roles -> role
      _other -> "active"
    end
  end

  # --- the box's own record ----------------------------------------------------------

  @doc "The box's pairing, or `nil`: `%{\"server\", \"uid\", \"hall\", \"role\", ...}`."
  def config do
    case Settings.get(@setting) do
      %{"server" => server} = config when is_binary(server) -> config
      _none -> nil
    end
  end

  @doc false
  def put_config(nil) do
    Settings.put(@setting, nil)
    notify()
  end

  def put_config(%{} = config) do
    Settings.put(@setting, config)
    notify()
  end

  @doc false
  def update_config(fun) do
    case config() do
      nil -> nil
      config -> config |> fun.() |> tap(&put_config/1)
    end
  end

  @doc """
  What this box is in the hall:

  * `:unlinked` - paired with no cloud; it runs its hall as it always did;
  * `:active` - it runs the hall and streams it;
  * `:spare` - it stands by, reads no boards and sends no results;
  * `:superseded` - it was active, and another box has the lease now.
  """
  def phase, do: phase(config())

  def phase(nil), do: :unlinked
  def phase(%{"superseded" => true}), do: :superseded
  def phase(%{"role" => "spare"}), do: :spare
  def phase(%{}), do: :active

  @doc """
  Whether this box reads its boards and sends its results: unless it is a
  spare or was superseded. Asked before a board's process starts
  (`Alnasl.Boards`) and before a sender sends (`Alnasl.Destination.Sender`).
  """
  def driving?, do: phase() in [:unlinked, :active]

  # --- the key -------------------------------------------------------------------------

  @doc false
  def key_path, do: Path.join(Paths.data(), "takeover.key")

  @doc false
  def key do
    case File.read(key_path()) do
      {:ok, key} -> String.trim(key)
      {:error, _none} -> nil
    end
  end

  @doc false
  def put_key(key) when is_binary(key) do
    path = key_path()
    tmp = path <> ".new"
    # Locked down while still empty, so the key is never readable by others,
    # not even for the moment between writing it and remembering to chmod.
    File.write!(tmp, "")
    _ = File.chmod(tmp, 0o600)
    File.write!(tmp, key)
    File.rename!(tmp, path)
    :ok
  end

  @doc false
  def delete_key do
    _ = File.rm(key_path())
    :ok
  end

  # --- what is on show -----------------------------------------------------------------

  @runtime :alnasl_takeover

  @doc false
  def runtime_table, do: @runtime

  @doc false
  def put_runtime(map) do
    if :ets.whereis(@runtime) != :undefined do
      before = runtime()
      :ets.insert(@runtime, {:status, map})
      # The pages redraw when something they show changed, not every step.
      if Map.delete(before, :last_ok_at) != Map.delete(map, :last_ok_at), do: notify()
    end

    :ok
  end

  defp runtime do
    with true <- :ets.whereis(@runtime) != :undefined,
         [{:status, map}] <- :ets.lookup(@runtime, :status) do
      map
    else
      _none -> %{}
    end
  end

  @doc "Has the line to the cloud failed at its last try?"
  def offline?, do: runtime()[:online?] == false

  @doc "How many events wait for the cloud."
  def queued, do: Repo.aggregate(Queued, :count)

  @doc """
  Everything the pages say about it: `%{phase, hall, server, online?,
  queued, full?, holder, error, last_ok_at, auto?}`. `online?` is `nil`
  until the link has tried once.
  """
  def status do
    config = config()
    runtime = runtime()

    %{
      phase: phase(config),
      hall: config && config["hall"],
      server: config && config["server"],
      role: config && config["role"],
      auto?: config == nil or config["auto"] != false,
      epoch: config && config["epoch"],
      holder: config && config["holder"],
      online?: runtime[:online?],
      error: runtime[:error],
      last_ok_at: runtime[:last_ok_at],
      taking_over?: runtime[:taking_over?] == true,
      queued: if(config, do: queued(), else: 0),
      full?: config != nil and config["overflow"] == true
    }
  end
end
