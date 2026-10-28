defmodule AlnaslWeb.TakeoverController do
  @moduledoc """
  The cloud's addresses for hall boxes (`Alnasl.Takeover.Cloud`, the whole
  protocol in docs/takeover.md). JSON from a program: no session, no CSRF
  token, no PIN. Off (404, nothing read) on an Alnasl that is not a cloud
  (`Alnasl.Takeover.cloud?/0`).

  | | | |
  |---|---|---|
  | `POST /takeover/join/:code` | the pairing code, once | `{uid, name, software}` in; `{key, hall, hall_id}` out |
  | `POST /takeover/lease` | key | `{action: claim\\|standby\\|take_over\\|release, epoch, queued, role}` |
  | `POST /takeover/events` | key | `{epoch, events: [...]}`, at most 500; `{acked}` out |
  | `PUT /takeover/state` | key | `{epoch, state}`; at most 4 MB |
  | `GET /takeover/restore?epoch=&after=` | key | `{state, events, next}` |

  Everything but joining needs `Authorization: Bearer <key>`: 401 without
  a key this cloud gave (`{"error": "key"}`) or for a box removed from its
  hall (`{"error": "revoked"}`). A box only ever reaches its own hall: the
  hall is the key's, never a parameter. A write with an epoch that is not
  the lease's is a 409 with the lease as it is. 429 with `retry-after` past
  240 requests a minute from one box, or ten pairing attempts in ten
  minutes from one address. 422 for anything malformed.
  """

  use AlnaslWeb, :controller

  alias Alnasl.Takeover
  alias Alnasl.Takeover.{Cloud, RateLimit}

  @box_limit 240
  @join_limit 10
  @max_state_bytes 4_000_000

  plug :cloud_only
  plug :authenticate when action in [:lease, :events, :state, :restore]

  defp cloud_only(conn, _opts) do
    if Takeover.cloud?(), do: conn, else: conn |> error(404, "not_found") |> halt()
  end

  defp authenticate(conn, _opts) do
    with ["Bearer " <> key] <- get_req_header(conn, "authorization"),
         {:ok, box} <- Cloud.authenticate(String.trim(key)) do
      case RateLimit.hit({:box, box.id}, @box_limit, 60_000) do
        :ok -> assign(conn, :box, box)
        {:error, wait} -> conn |> limited(wait) |> halt()
      end
    else
      {:error, :revoked} -> conn |> error(401, "revoked") |> halt()
      _no_key -> conn |> error(401, "key") |> halt()
    end
  end

  # --- pairing -----------------------------------------------------------------------

  def join(conn, %{"code" => code} = params) do
    case RateLimit.hit({:join, client_ip(conn)}, @join_limit, 600_000) do
      :ok ->
        identity = Map.take(params, ["uid", "name", "software"])

        case Cloud.redeem(code, identity) do
          {:ok, %{key: key, hall: hall}} ->
            json(conn, %{key: key, hall: hall.name, hall_id: hall.id})

          {:error, :elsewhere} ->
            error(conn, 403, "elsewhere")

          {:error, :bad_request} ->
            error(conn, 422, "bad_request")

          {:error, _used_or_expired} ->
            error(conn, 410, "used_or_expired")
        end

      {:error, wait} ->
        limited(conn, wait)
    end
  end

  # --- the lease ---------------------------------------------------------------------

  def lease(conn, %{"action" => action} = params)
      when action in ~w(claim standby take_over release) do
    box = conn.assigns.box

    with {:ok, epoch} <- epoch(params["epoch"]) do
      if is_integer(params["queued"]), do: Cloud.report(box, params["queued"])
      lease(conn, action, box, epoch, params)
    else
      :error -> error(conn, 422, "bad_request")
    end
  end

  def lease(conn, _params), do: error(conn, 422, "bad_request")

  defp lease(conn, "claim", box, epoch, _params), do: verdict(conn, box, Cloud.claim(box, epoch))

  defp lease(conn, "take_over", box, _epoch, _params),
    do: verdict(conn, box, Cloud.take_over(box))

  defp lease(conn, "standby", box, _epoch, params) do
    role = if params["role"] == "superseded", do: "superseded", else: "spare"
    json(conn, %{lease: Cloud.view(Cloud.standby(box, role), box)})
  end

  defp lease(conn, "release", box, epoch, _params) do
    {:released, lease} = Cloud.release(box, epoch)
    json(conn, %{lease: Cloud.view(lease, box)})
  end

  defp verdict(conn, box, {:granted, lease, previous}),
    do:
      json(conn, %{
        granted: true,
        previous: Atom.to_string(previous),
        lease: Cloud.view(lease, box)
      })

  defp verdict(conn, box, {:denied, lease, why}),
    do: json(conn, %{granted: false, why: Atom.to_string(why), lease: Cloud.view(lease, box)})

  # --- the stream --------------------------------------------------------------------

  def events(conn, %{"epoch" => epoch, "events" => events}) when is_list(events) do
    box = conn.assigns.box

    with {:ok, epoch} when is_integer(epoch) <- epoch(epoch),
         {:ok, seq} <- Cloud.put_events(box, epoch, events) do
      json(conn, %{acked: seq})
    else
      {:error, :stale} -> stale(conn, box)
      _bad -> error(conn, 422, "bad_request")
    end
  end

  def events(conn, _params), do: error(conn, 422, "bad_request")

  def state(conn, %{"epoch" => epoch, "state" => %{} = state}) do
    box = conn.assigns.box

    with {:ok, epoch} when is_integer(epoch) <- epoch(epoch),
         true <- small?(state),
         :ok <- Cloud.put_state(box, epoch, state) do
      json(conn, %{ok: true})
    else
      {:error, :stale} -> stale(conn, box)
      false -> error(conn, 413, "too_large")
      _bad -> error(conn, 422, "bad_request")
    end
  end

  def state(conn, _params), do: error(conn, 422, "bad_request")

  def restore(conn, params) do
    box = conn.assigns.box

    with {epoch, ""} <- Integer.parse(to_string(params["epoch"])),
         {:ok, after_id} <- after_id(params["after"]),
         {:ok, page} <- Cloud.restore(box, epoch, after_id) do
      json(conn, page)
    else
      {:error, :stale} -> stale(conn, box)
      _bad -> error(conn, 422, "bad_request")
    end
  end

  # --- helpers ---------------------------------------------------------------------

  defp epoch(nil), do: {:ok, nil}
  defp epoch(epoch) when is_integer(epoch) and epoch >= 0, do: {:ok, epoch}
  defp epoch(_other), do: :error

  defp after_id(nil), do: {:ok, nil}

  defp after_id(text) do
    case Integer.parse(to_string(text)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _bad -> :error
    end
  end

  defp small?(state) do
    case Jason.encode(state) do
      {:ok, json} -> byte_size(json) <= @max_state_bytes
      _error -> false
    end
  end

  defp stale(conn, box) do
    conn
    |> put_status(409)
    |> json(%{error: "stale", lease: Cloud.view(Cloud.lease(box.hall_id), box)})
  end

  defp limited(conn, wait) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(wait))
    |> error(429, "rate_limited")
  end

  defp error(conn, status, error), do: conn |> put_status(status) |> json(%{error: error})

  # Behind a Cloudflare tunnel every request comes from the loopback
  # address; the sender is then the tunnel's header, and only then (as in
  # `AlnaslWeb.SupportController`).
  defp client_ip(conn) do
    case {conn.remote_ip, get_req_header(conn, "cf-connecting-ip")} do
      {{127, 0, 0, 1}, [ip | _]} -> ip
      {{0, 0, 0, 0, 0, 0, 0, 1}, [ip | _]} -> ip
      {ip, _header} -> ip |> :inet.ntoa() |> to_string()
    end
  end
end
