defmodule Alnasl.Takeover.Cloud do
  @moduledoc """
  The cloud's end of a spare box taking over (docs/takeover.md): the boxes
  paired with a hall, its lease, and what the active box streamed.

  ## Pairing

  The hall's owner or an arbiter makes a code (`create_join/2`), good for
  fifteen minutes and one box. The box redeems it once (`redeem/2`) and is
  given its own key, `"<uid>.<secret>"`, which it keeps in a file and sends
  as `Authorization: Bearer ...` from then on. Only the key's hash is kept
  here. Removing the box in the hall (`revoke/1`) ends it: every request
  with that key is refused from then on.

  ## The lease

  One a hall: which box runs it, and the epoch. `claim/3` renews it for the
  box that holds it, and grants it to a box that asks when nobody holds it
  or the holder has been silent longer than `Alnasl.Takeover.lease_ms/0`.
  Every grant to another box is a new epoch. A box that asks with an epoch
  older than the lease's is not given it back, even when the lease is free:
  it ran the hall once, others have since, and its own idea of the hall is
  out of date - it steps down, and an arbiter decides. `take_over/2` is the
  arbiter's "Take over" pressed on a spare, `hand_over/3` the same pressed
  here: both grant at once, whoever held it.

  ## Fencing

  `put_events/3` and `put_state/4` take the epoch the box believes it holds,
  and refuse anything but the lease's own (`{:error, :stale}`), from
  anything but the box that holds it. So a box cut off by a network split
  that comes back with a queue full of moves cannot write over the box that
  took over: its first write is refused, and that is how it learns.
  """

  import Ecto.Query, only: [from: 2]

  alias Alnasl.{Halls, Log, Repo, Takeover}
  alias Alnasl.Takeover.{Box, Event, Join, Lease, State, Stream}

  @join_minutes 15
  # No 0/O, no 1/I/L: read off a screen across a hall, and typed on a box.
  @alphabet ~c"23456789ABCDEFGHJKMNPQRSTUVWXYZ"
  @max_events 500
  @topic "takeover:cloud"
  @max_event_bytes 16_384

  def max_events, do: @max_events

  @doc "The hall pages hear here when a box was paired, removed, or was heard from."
  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  defp notify, do: Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, {:takeover_cloud, :changed})

  @doc "The hall's lease as it is, without making one."
  def peek_lease(hall_id), do: Repo.get_by(Lease, hall_id: hall_id)

  # --- pairing -----------------------------------------------------------------------

  @doc "A fresh pairing code for hall `hall_id`. Old codes are tidied away on the way."
  def create_join(hall_id, now \\ DateTime.utc_now(:second)) when is_integer(hall_id) do
    Repo.delete_all(from j in Join, where: j.expires_at < ^now)

    %Join{code: code(), hall_id: hall_id, expires_at: DateTime.add(now, @join_minutes * 60)}
    |> Repo.insert()
  end

  defp code do
    chars = Alnasl.SecretCode.chars(@alphabet, 7)
    {first, last} = Enum.split(chars, 3)
    List.to_string(first) <> "-" <> List.to_string(last)
  end

  @doc """
  A box redeems a code with who it is (`%{"uid", "name", "software"}`):
  `{:ok, %{key, box, hall}}`, or `{:error, :used_or_expired | :bad_request |
  :elsewhere}`. The same box (`uid`) paired again is the same row with a
  new key; one that is still paired with another hall is refused until it
  is removed there.
  """
  def redeem(code, identity, now \\ DateTime.utc_now(:second))

  def redeem(code, %{"uid" => uid} = identity, now)
      when is_binary(code) and is_binary(uid) do
    with true <- uid =~ ~r/\A[A-Za-z0-9_-]{8,64}\z/ || {:error, :bad_request},
         {:ok, result} <- do_redeem(String.upcase(String.trim(code)), uid, identity, now) do
      Log.add(:info, "takeover.box_paired", %{name: result.box.name}, %{})
      notify()
      {:ok, result}
    end
  end

  def redeem(_code, _identity, _now), do: {:error, :bad_request}

  defp do_redeem(code, uid, identity, now) do
    Repo.transaction(fn ->
      with %Join{used_at: nil} = join <- Repo.get_by(Join, code: code),
           :gt <- DateTime.compare(join.expires_at, now),
           %{} = hall <- Halls.get(join.hall_id) do
        key = uid <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        fields = %{
          name: text(identity["name"], 80) || "Box",
          software: text(identity["software"], 80),
          key_hash: hash(key),
          revoked_at: nil,
          hall_id: join.hall_id,
          role: nil
        }

        box =
          case Repo.get_by(Box, uid: uid) do
            nil ->
              Repo.insert!(struct(Box, Map.put(fields, :uid, uid)))

            %Box{revoked_at: nil, hall_id: hall_id} when hall_id != join.hall_id ->
              Repo.rollback(:elsewhere)

            old ->
              old |> Ecto.Changeset.change(fields) |> Repo.update!()
          end

        join |> Ecto.Changeset.change(used_at: now, box_id: box.id) |> Repo.update!()
        %{key: key, box: box, hall: hall}
      else
        _used_or_expired -> Repo.rollback(:used_or_expired)
      end
    end)
  end

  defp text(value, max) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, max) do
      "" -> nil
      text -> text
    end
  end

  defp text(_value, _max), do: nil

  defp hash(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

  @doc """
  The box whose key is `key`: `{:ok, box}`, or `{:error, :key}` (not a key
  given here) or `{:error, :revoked}` (removed from its hall).
  """
  def authenticate(key) when is_binary(key) and byte_size(key) < 200 do
    with [uid, _secret] <- String.split(key, ".", parts: 2),
         %Box{} = box <- Repo.get_by(Box, uid: uid),
         true <- Plug.Crypto.secure_compare(hash(key), box.key_hash) do
      if box.revoked_at, do: {:error, :revoked}, else: {:ok, box}
    else
      _no -> {:error, :key}
    end
  end

  def authenticate(_key), do: {:error, :key}

  @doc "The boxes of a hall, not removed, oldest first."
  def boxes(hall_id) do
    Repo.all(from b in Box, where: b.hall_id == ^hall_id and is_nil(b.revoked_at), order_by: b.id)
  end

  def get_box(id), do: Repo.get(Box, id)

  @doc "Removes a box from its hall: its key stops working at once. A box holding the lease loses it."
  def revoke(%Box{} = box) do
    box = box |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update!()

    Repo.update_all(from(l in Lease, where: l.box_id == ^box.id),
      set: [box_id: nil, expires_at: nil]
    )

    Log.add(:info, "takeover.box_removed", %{name: box.name}, %{})
    notify()
    {:ok, box}
  end

  # --- the lease ---------------------------------------------------------------------

  @doc "The hall's lease (made, empty, the first time it is asked for)."
  def lease(hall_id) do
    Repo.get_by(Lease, hall_id: hall_id) ||
      Repo.insert!(%Lease{hall_id: hall_id, epoch: 0},
        on_conflict: :nothing,
        conflict_target: :hall_id
      )
      |> then(fn _inserted -> Repo.get_by!(Lease, hall_id: hall_id) end)
  end

  @doc "Is the lease held, and not run out, at `now`?"
  def live?(%Lease{box_id: nil}, _now), do: false
  def live?(%Lease{expires_at: nil}, _now), do: false
  def live?(%Lease{expires_at: at}, now), do: DateTime.compare(at, now) == :gt

  @doc """
  The active box renewing, or any box asking for the lease. `epoch` is the
  one the box believes it holds, `nil` for a box that never held one here.
  `{:granted, lease, previous}` - `previous` is `:self` when this box held it
  before, `:other` when another box did, `:none` when nobody ever did - or
  `{:denied, lease, why}` with `why` `:held` (another box has it, and is
  not silent) or `:stale` (this box's epoch is old).
  """
  def claim(%Box{} = box, epoch, now \\ DateTime.utc_now()) do
    in_lease(box.hall_id, fn lease ->
      cond do
        lease.box_id == box.id and epoch == lease.epoch ->
          {:granted, renew(lease, now), :self}

        is_integer(epoch) and epoch < lease.epoch ->
          {:denied, lease, :stale}

        lease.box_id == box.id ->
          # Held here, with an epoch the box has lost (its data was reset):
          # the same lease, as far as the box goes.
          {:granted, renew(lease, now), :self}

        live?(lease, now) ->
          {:denied, lease, :held}

        true ->
          previous = if lease.epoch == 0, do: :none, else: :other
          {:granted, grant(lease, box, now), previous}
      end
    end)
    |> tap(&seen(box, &1, "active"))
  end

  @doc """
  A spare standing by: the lease as it is, and whether it was handed to
  this box from the cloud (`hand_over/3`) - then the spare takes it up.
  """
  def standby(%Box{} = box, role \\ "spare") do
    lease = lease(box.hall_id)
    seen(box, {:standby, lease}, role)
    lease
  end

  @doc "\"Take over\" pressed on a spare: the lease is this box's, in a new epoch, whoever had it."
  def take_over(%Box{} = box, now \\ DateTime.utc_now()) do
    in_lease(box.hall_id, fn lease ->
      previous = if lease.box_id == box.id, do: :self, else: :other
      {:granted, grant(lease, box, now), previous}
    end)
    |> tap(&seen(box, &1, "active"))
    |> tap(fn _ -> Log.add(:warn, "takeover.taken_over", %{name: box.name}, %{}) end)
  end

  @doc """
  "Take over" pressed here, for spare `box_id` of hall `hall_id`: the lease
  is that box's in a new epoch, at once. The spare notices at its next
  call and starts; the box that had it is refused from its next write.
  """
  def hand_over(hall_id, box_id, now \\ DateTime.utc_now()) do
    case Repo.get(Box, box_id) do
      %Box{hall_id: ^hall_id, revoked_at: nil} = box ->
        result = in_lease(hall_id, fn lease -> {:granted, grant(lease, box, now), :other} end)
        Log.add(:warn, "takeover.handed_over", %{name: box.name}, %{})
        notify()
        result

      _not_here ->
        {:error, :not_found}
    end
  end

  @doc "The active box gives the hall up (it became a spare, or left)."
  def release(%Box{} = box, epoch) do
    in_lease(box.hall_id, fn lease ->
      if lease.box_id == box.id and lease.epoch == epoch do
        {:released,
         lease |> Ecto.Changeset.change(box_id: nil, expires_at: nil) |> Repo.update!()}
      else
        {:released, lease}
      end
    end)
  end

  defp renew(lease, now),
    do:
      lease
      |> Ecto.Changeset.change(expires_at: DateTime.add(now, Takeover.lease_ms(), :millisecond))
      |> Repo.update!()

  defp grant(lease, box, now) do
    lease
    |> Ecto.Changeset.change(
      box_id: box.id,
      epoch: lease.epoch + 1,
      granted_at: DateTime.truncate(now, :second),
      expires_at: DateTime.add(now, Takeover.lease_ms(), :millisecond)
    )
    |> Repo.update!()
  end

  # Read and decide in one transaction that takes the write lock first:
  # two boxes asking at once are answered one after the other.
  defp in_lease(hall_id, fun) do
    _ = lease(hall_id)

    {:ok, result} =
      Repo.transaction(fn -> fun.(Repo.get_by!(Lease, hall_id: hall_id)) end, mode: :immediate)

    result
  end

  defp seen(box, result, role) do
    lease =
      case result do
        {_verdict, %Lease{} = lease, _why} -> lease
        {_verdict, %Lease{} = lease} -> lease
        _other -> nil
      end

    role =
      cond do
        lease && lease.box_id == box.id -> "active"
        role == "active" -> "superseded"
        true -> role
      end

    Repo.update_all(from(b in Box, where: b.id == ^box.id),
      set: [last_seen_at: DateTime.utc_now(:second), role: role]
    )

    notify()
  end

  @doc "What the box said about its queue, for the hall's page."
  def report(%Box{id: id}, queued) when is_integer(queued) and queued >= 0 do
    Repo.update_all(from(b in Box, where: b.id == ^id), set: [queued: min(queued, 10_000_000)])
    :ok
  end

  def report(_box, _queued), do: :ok

  # --- the stream --------------------------------------------------------------------

  @doc """
  Events from the box that holds the lease in `epoch`: kept, each once.
  `{:ok, seq}` - the highest of the box's numbers now kept - or `{:error,
  :stale}` or `{:error, :invalid}` (nothing is kept from a batch with one
  bad event in it).
  """
  def put_events(%Box{} = box, epoch, events) when is_list(events) do
    with :ok <- holds(box, epoch),
         {:ok, rows} <- validate_events(box, epoch, events) do
      Repo.insert_all(Event, rows, on_conflict: :nothing, conflict_target: [:hall_id, :event_id])
      {:ok, Enum.reduce(rows, 0, &max(&1.seq, &2))}
    end
  end

  def put_events(_box, _epoch, _events), do: {:error, :invalid}

  defp holds(box, epoch) do
    lease = lease(box.hall_id)
    if lease.box_id == box.id and lease.epoch == epoch, do: :ok, else: {:error, :stale}
  end

  defp validate_events(_box, _epoch, events) when length(events) > @max_events,
    do: {:error, :invalid}

  defp validate_events(box, epoch, events) do
    now = DateTime.utc_now(:second)

    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, rows} ->
      case row(box, epoch, event, now) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        :error -> {:halt, {:error, :invalid}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp row(box, epoch, %{"id" => id, "seq" => seq, "kind" => kind} = event, now)
       when is_binary(id) and is_integer(seq) and seq > 0 do
    data = event["data"]

    with true <- id == Stream.event_id(box.uid, seq),
         true <- kind in Stream.kinds(),
         true <- is_map(data),
         {:ok, json} <- Jason.encode(data),
         true <- byte_size(json) <= @max_event_bytes,
         true <- optional(event["game"], &(is_binary(&1) and byte_size(&1) <= 120)),
         true <- optional(event["serial"], &(is_binary(&1) and byte_size(&1) <= 64)),
         true <- optional(event["ply"], &(is_integer(&1) and &1 > 0 and &1 < 10_000)),
         true <- optional(event["at"], &is_integer/1) do
      {:ok,
       %{
         hall_id: box.hall_id,
         box_id: box.id,
         epoch: epoch,
         event_id: id,
         seq: seq,
         kind: kind,
         game: event["game"],
         serial: event["serial"],
         ply: event["ply"],
         at: event["at"],
         data: json,
         inserted_at: now
       }}
    else
      _bad -> :error
    end
  end

  defp row(_box, _epoch, _event, _now), do: :error

  defp optional(nil, _check), do: true
  defp optional(value, check), do: check.(value)

  @doc """
  The box's whole state, from the box that holds the lease in `epoch`.
  Sent only when the box's queue is empty, so every event it had is
  already here: `mark` is the last of them.
  """
  def put_state(%Box{} = box, epoch, %{} = data) do
    with :ok <- holds(box, epoch),
         {:ok, json} <- Jason.encode(data) do
      mark =
        Repo.one(from e in Event, where: e.hall_id == ^box.hall_id, select: max(e.id)) || 0

      Repo.insert!(
        %State{hall_id: box.hall_id, box_id: box.id, epoch: epoch, mark: mark, data: json},
        on_conflict: {:replace, [:box_id, :epoch, :mark, :data, :updated_at]},
        conflict_target: :hall_id
      )

      :ok
    end
  end

  def put_state(_box, _epoch, _data), do: {:error, :invalid}

  @doc """
  What a box that has just been given the lease starts from: the last
  state, and the events after it, `limit` at a time from `after` (an event
  id here). `{:ok, %{state, events, next}}` - `next` is where to ask again,
  `nil` at the end - or `{:error, :stale}` for a box that does not hold the
  lease in `epoch`.
  """
  def restore(%Box{} = box, epoch, after_id \\ nil, limit \\ 1000) do
    with :ok <- holds(box, epoch) do
      state = Repo.get_by(State, hall_id: box.hall_id)
      mark = if state, do: state.mark, else: 0
      from_id = max(after_id || 0, mark)

      events =
        Repo.all(
          from e in Event,
            where: e.hall_id == ^box.hall_id and e.id > ^from_id,
            order_by: e.id,
            limit: ^limit
        )

      {:ok,
       %{
         state: if(state && is_nil(after_id), do: Jason.decode!(state.data)),
         events:
           Enum.map(events, fn e ->
             %{
               "id" => e.event_id,
               "kind" => e.kind,
               "game" => e.game,
               "serial" => e.serial,
               "ply" => e.ply,
               "at" => e.at,
               "data" => Jason.decode!(e.data)
             }
           end),
         next: if(length(events) == limit, do: List.last(events).id)
       }}
    end
  end

  @doc "The lease as a box is told it: who holds it, the epoch, how long is left."
  def view(%Lease{} = lease, %Box{} = box, now \\ DateTime.utc_now()) do
    holder =
      cond do
        lease.box_id == nil -> "none"
        lease.box_id == box.id -> "you"
        true -> "other"
      end

    holder_box = if lease.box_id && lease.box_id != box.id, do: Repo.get(Box, lease.box_id)

    %{
      "holder" => holder,
      "holder_name" => holder_box && holder_box.name,
      "epoch" => lease.epoch,
      "live" => live?(lease, now),
      "expires_in_ms" =>
        if(lease.expires_at, do: max(DateTime.diff(lease.expires_at, now, :millisecond), 0)),
      "lease_ms" => Takeover.lease_ms()
    }
  end
end
