defmodule Alnasl.Takeover.Link do
  @moduledoc """
  The box's line to the cloud: one process, one step every few seconds
  (`step/1`), and the arbiter's buttons, which wait for the step in hand.

  ## A step

  * **Active**: renew the lease (`claim`, with the epoch the box holds),
    send what is queued, oldest first, in batches of 500, and - once the
    queue is empty and the state changed, at most every fifteen seconds, or
    at once after the queue overflowed - the whole state. No answer: the
    box carries on running its hall, and says it is offline with so many
    events queued. Refused (another box has the lease, or a write carried
    an old epoch): it steps down.
  * **Spare**: say it is standing by (`standby`). When the cloud handed it
    the lease ("Take over" pressed there), or the lease is free because the
    active box has been silent for longer than the lease (and the spare
    takes over by itself, the default), take it: get the lease, pull the
    last state and the events after it, write them here
    (`Alnasl.Takeover.Restore`), start reading the boards, and then run
    `Alnasl.Takeover.Hooks.after_takeover/1`.
  * **Superseded**: say so, slowly, and nothing else. The page offers to
    stand by as a spare, which fights nobody; it does not offer to take the
    hall back by itself.

  ## What a box that is not driving does not do

  A spare and a superseded box start no board process
  (`Alnasl.Boards.start/1` asks `Alnasl.Takeover.driving?/0`) and send no
  results (`Alnasl.Destination.Sender` asks too). Stepping down stops the
  boards that were running.
  """

  use GenServer

  require Logger

  alias Alnasl.{Boards, Destination, Log, Settings, Takeover, Updates}
  alias Alnasl.Takeover.{Client, Hooks, Restore, Snapshot, Stream}

  @tick_ms 5_000
  @slow_tick_ms 30_000
  @state_every_ms 15_000
  @batches_a_step 20

  # --- starting ----------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    if :ets.whereis(Takeover.runtime_table()) == :undefined do
      :ets.new(Takeover.runtime_table(), [:named_table, :public, read_concurrency: true])
    end

    tick? = Keyword.get(opts, :tick, true)
    if tick?, do: Process.send_after(self(), :tick, 1_000)
    {:ok, %{tick?: tick?, timer: nil, digest: nil, state_at: nil, online?: nil}}
  end

  # --- the arbiter's buttons -----------------------------------------------------------

  @doc "Pairs the box with a hall (the link or the code the cloud showed): `:ok` or `{:error, reason}`."
  def pair(link), do: run({:pair, link})

  @doc "\"Take over\" pressed on this box: `:ok` or `{:error, reason}`."
  def take_over, do: run(:take_over)

  @doc "Becomes a spare (an active box gives the hall up; a superseded one stands by)."
  def stand_by, do: run(:stand_by)

  @doc "Takes over by itself when the active box goes silent, or only when told."
  def set_auto(auto?) when is_boolean(auto?), do: run({:auto, auto?})

  @doc "Unpairs the box: it forgets the cloud and its key, and runs its hall as before."
  def leave, do: run(:leave)

  @doc "One step now (tests, and the page's \"Try now\")."
  def step_now, do: run(:step)

  defp run(request) do
    case Process.whereis(__MODULE__) do
      nil -> request |> handle(initial()) |> elem(0)
      pid -> GenServer.call(pid, request, 60_000)
    end
  end

  defp initial, do: %{tick?: false, timer: nil, digest: nil, state_at: nil, online?: nil}

  @impl true
  def handle_call(request, _from, st) do
    {reply, st} = handle(request, st)
    {:reply, reply, st}
  end

  @impl true
  def handle_info(:tick, st) do
    {_reply, st} = handle(:step, st)
    {:noreply, schedule(st)}
  end

  # Something was queued: sent within half a second, if the box is active
  # and no step is near.
  def handle_info(:kick, %{tick?: true} = st) do
    if Takeover.phase() == :active and timer_left(st) > 500 do
      Process.cancel_timer(st.timer)
      {:noreply, %{st | timer: Process.send_after(self(), :tick, 500)}}
    else
      {:noreply, st}
    end
  end

  def handle_info(_other, st), do: {:noreply, st}

  defp schedule(%{tick?: false} = st), do: st

  defp schedule(st) do
    every = if Takeover.phase() == :superseded, do: @slow_tick_ms, else: tick_ms()
    %{st | timer: Process.send_after(self(), :tick, every)}
  end

  defp timer_left(%{timer: nil}), do: 0
  defp timer_left(%{timer: ref}), do: Process.read_timer(ref) || 0

  defp tick_ms, do: Application.get_env(:alnasl, :takeover_tick_ms, @tick_ms)

  # --- requests ------------------------------------------------------------------------

  defp handle({:pair, link}, st) do
    if Takeover.config() do
      {{:error, :already}, st}
    else
      uid = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      identity = %{
        "uid" => uid,
        "name" => Settings.get("box_name") || "Alnasl",
        "software" => "Alnasl " <> Updates.current_version()
      }

      case Client.join(link, identity) do
        {:ok, joined} ->
          Takeover.put_key(joined.key)
          Stream.clear()

          Takeover.put_config(%{
            "server" => joined.server,
            "uid" => uid,
            "hall" => joined.hall,
            "role" => Takeover.initial_role(),
            "auto" => true,
            "epoch" => nil,
            "superseded" => false
          })

          Log.add(:info, "takeover.paired", %{hall: joined.hall || ""})
          drive()
          # Paired, whatever the first step says: the status line tells.
          {_reply, st} = step(%{st | digest: nil, state_at: nil})
          {:ok, st}

        {:error, reason} ->
          {{:error, reason}, st}
      end
    end
  end

  defp handle(:take_over, st) do
    with %{} = config <- Takeover.config(),
         key when is_binary(key) <- Takeover.key() do
      case Client.lease(config["server"], key, "take_over") do
        {:ok, %{"granted" => true, "lease" => %{"epoch" => epoch}}} ->
          become_active(config, key, epoch, st)

        {:error, status, body} ->
          {{:error, refused(status, body)}, offline(st, status)}

        {:error, :unreachable} ->
          {{:error, :unreachable}, offline(st, :unreachable)}

        _other ->
          {{:error, :refused}, st}
      end
    else
      _unpaired -> {{:error, :unpaired}, st}
    end
  end

  defp handle(:stand_by, st) do
    case {Takeover.config(), Takeover.key()} do
      {%{} = config, key} when is_binary(key) ->
        if Takeover.phase(config) == :active and is_integer(config["epoch"]),
          do: Client.lease(config["server"], key, "release", %{"epoch" => config["epoch"]})

        Takeover.put_config(
          Map.merge(config, %{"role" => "spare", "superseded" => false, "epoch" => nil})
        )

        Log.add(:info, "takeover.standing_by", %{})
        drive()
        {:ok, st}

      _unpaired ->
        {{:error, :unpaired}, st}
    end
  end

  defp handle({:auto, auto?}, st) do
    Takeover.update_config(&Map.put(&1, "auto", auto?))
    {:ok, st}
  end

  defp handle(:leave, st) do
    case {Takeover.config(), Takeover.key()} do
      {%{} = config, key} ->
        if is_binary(key) and Takeover.phase(config) == :active and is_integer(config["epoch"]),
          do: Client.lease(config["server"], key, "release", %{"epoch" => config["epoch"]})

        Takeover.delete_key()
        Stream.clear()
        Takeover.put_config(nil)
        Takeover.put_runtime(%{})
        Log.add(:info, "takeover.left", %{})
        drive()
        {:ok, %{st | digest: nil, state_at: nil, online?: nil}}

      _unpaired ->
        {:ok, st}
    end
  end

  defp handle(:step, st), do: step(st)

  # --- a step --------------------------------------------------------------------------

  @doc false
  def step(st) do
    case {Takeover.config(), Takeover.key()} do
      {nil, _key} -> {:ok, st}
      {_config, nil} -> {{:error, :no_key}, offline(st, :no_key)}
      {config, key} -> step(Takeover.phase(config), config, key, st)
    end
  end

  defp step(:active, config, key, st) do
    fields = %{"epoch" => config["epoch"], "queued" => Takeover.queued()}

    case Client.lease(config["server"], key, "claim", fields) do
      {:ok, %{"granted" => true, "lease" => %{"epoch" => epoch}, "previous" => previous}} ->
        st = online(st)

        cond do
          # The hall was another box's before this one had it: what it did
          # comes first.
          previous == "other" and config["epoch"] != epoch ->
            become_active(config, key, epoch, st)

          config["epoch"] != epoch ->
            Takeover.put_config(Map.put(config, "epoch", epoch))
            flush(Map.put(config, "epoch", epoch), key, st)

          true ->
            flush(config, key, st)
        end

      {:ok, %{"granted" => false, "lease" => lease}} ->
        step_down(config, lease, online(st))

      other ->
        failed(other, st)
    end
  end

  defp step(:spare, config, key, st) do
    case Client.lease(config["server"], key, "standby", %{"role" => "spare"}) do
      {:ok, %{"lease" => %{"holder" => "you", "epoch" => epoch}}} ->
        Log.add(:warn, "takeover.handed_over_here", %{})
        become_active(config, key, epoch, online(st))

      {:ok, %{"lease" => %{"live" => false}}} ->
        if config["auto"] != false,
          do: claim_free(config, key, online(st)),
          else: {:ok, online(st)}

      {:ok, _standing_by} ->
        {:ok, online(st)}

      other ->
        failed(other, st)
    end
  end

  defp step(:superseded, config, key, st) do
    case Client.lease(config["server"], key, "standby", %{"role" => "superseded"}) do
      {:ok, %{"lease" => lease}} ->
        if config["holder"] != lease["holder_name"],
          do: Takeover.put_config(Map.put(config, "holder", lease["holder_name"]))

        {:ok, online(st)}

      other ->
        failed(other, st)
    end
  end

  # The active box went silent: this spare asks for the lease as a box that
  # holds none.
  defp claim_free(config, key, st) do
    case Client.lease(config["server"], key, "claim", %{"epoch" => nil}) do
      {:ok, %{"granted" => true, "lease" => %{"epoch" => epoch}}} ->
        Log.add(:warn, "takeover.silent_taken", %{})
        become_active(config, key, epoch, st)

      {:ok, _denied} ->
        {:ok, st}

      other ->
        failed(other, st)
    end
  end

  # --- sending ---------------------------------------------------------------------------

  defp flush(config, key, st, batches \\ 0)

  defp flush(config, _key, st, batches) when batches >= @batches_a_step do
    report(config, st)
  end

  defp flush(config, key, st, batches) do
    case Stream.batch(config["uid"]) do
      [] ->
        send_state(config, key, st)

      events ->
        case Client.events(config["server"], key, config["epoch"], events) do
          {:ok, %{"acked" => seq}} when is_integer(seq) ->
            Stream.acked(seq)
            flush(config, key, st, batches + 1)

          {:error, 409, body} ->
            step_down(config, body["lease"] || %{}, st)

          other ->
            failed(other, st)
        end
    end
  end

  defp send_state(config, key, st) do
    state = Snapshot.build(config["uid"])
    digest = Snapshot.digest(state)
    now = System.monotonic_time(:millisecond)
    overflow? = config["overflow"] == true

    due? =
      overflow? or st.state_at == nil or
        (digest != st.digest and now - st.state_at >= @state_every_ms)

    if (due? and digest != st.digest) or overflow? do
      case Client.state(config["server"], key, config["epoch"], state) do
        {:ok, _body} ->
          if overflow?, do: Takeover.update_config(&Map.delete(&1, "overflow"))
          report(config, %{st | digest: digest, state_at: now})

        {:error, 409, body} ->
          step_down(config, body["lease"] || %{}, st)

        other ->
          failed(other, st)
      end
    else
      report(config, st)
    end
  end

  defp report(_config, st), do: {:ok, st}

  # --- changing role ---------------------------------------------------------------------

  defp become_active(config, key, epoch, st) do
    Takeover.put_runtime(runtime(st, %{taking_over?: true}))

    case pull(config, key, epoch, nil, nil, []) do
      {:ok, state, events} ->
        case Restore.apply(state, events) do
          {:ok, summary} ->
            Takeover.put_config(
              Map.merge(config, %{
                "role" => "active",
                "epoch" => epoch,
                "superseded" => false,
                "holder" => nil
              })
            )

            Log.add(:warn, "takeover.took_over", %{
              games: summary.games,
              boards: length(summary.boards)
            })

            drive()
            Hooks.after_takeover(Map.put(summary, :epoch, epoch))
            Takeover.put_runtime(runtime(st, %{}))
            {:ok, %{st | digest: nil, state_at: nil}}

          {:error, why} ->
            Client.lease(config["server"], key, "release", %{"epoch" => epoch})
            Log.add(:error, "takeover.restore_failed", %{why: why})
            Takeover.put_runtime(runtime(st, %{error: :restore_failed}))
            {{:error, :restore_failed}, st}
        end

      {:error, 409} ->
        Takeover.put_runtime(runtime(st, %{}))
        {{:error, :stale}, st}

      {:error, other} ->
        Takeover.put_runtime(runtime(st, %{}))
        failed({:error, other}, st)
    end
  end

  defp pull(config, key, epoch, after_id, state, events) do
    case Client.restore(config["server"], key, epoch, after_id) do
      {:ok, %{"events" => page} = body} when is_list(page) ->
        state = state || body["state"]
        events = events ++ page

        case body["next"] do
          next when is_integer(next) -> pull(config, key, epoch, next, state, events)
          _done -> {:ok, state, events}
        end

      {:error, status, _body} ->
        {:error, status}

      {:error, :unreachable} ->
        {:error, :unreachable}

      _other ->
        {:error, :refused}
    end
  end

  defp step_down(config, lease, st) do
    Takeover.put_config(
      Map.merge(config, %{"superseded" => true, "holder" => lease["holder_name"]})
    )

    Log.add(:warn, "takeover.superseded", %{})
    Logger.warning("takeover: another box has this hall now; this one stops")
    drive()
    {{:error, :superseded}, st}
  end

  @doc false
  # Starts or stops the boards and the senders to match the box's phase.
  def drive do
    if Takeover.driving?() do
      if Application.get_env(:alnasl, :autostart, true), do: Boards.start_all()
      Destination.settings_changed()
    else
      for board <- Boards.list(), Boards.running?(board.id), do: Boards.stop(board)
    end

    Takeover.notify()
    :ok
  end

  # --- what the status line says ------------------------------------------------------

  defp online(st) do
    st = %{st | online?: true}
    Takeover.put_runtime(runtime(st, %{last_ok_at: DateTime.utc_now(:second)}))
    st
  end

  defp offline(st, why) do
    st = %{st | online?: false}
    Takeover.put_runtime(runtime(st, %{error: why}))
    st
  end

  defp runtime(st, extra), do: Map.merge(%{online?: st.online?}, extra)

  # A box removed from its hall in the cloud: it forgets the pairing and
  # runs its hall on its own, as it did before it was paired.
  defp failed({:error, 401, %{"error" => "revoked"}}, st) do
    Takeover.delete_key()
    Stream.clear()
    Takeover.put_config(nil)
    Log.add(:warn, "takeover.revoked", %{})
    drive()
    {{:error, :revoked}, offline(st, :revoked)}
  end

  defp failed({:error, status, body}, st),
    do: {{:error, refused(status, body)}, offline(st, status)}

  defp failed({:error, why}, st), do: {{:error, why}, offline(st, why)}
  defp failed(_other, st), do: {{:error, :refused}, offline(st, :refused)}

  defp refused(_status, %{"error" => error}) when is_binary(error), do: error
  defp refused(status, _body), do: status
end
