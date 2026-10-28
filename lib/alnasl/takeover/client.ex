defmodule Alnasl.Takeover.Client do
  @moduledoc """
  The box's requests to the cloud (`AlnaslWeb.TakeoverController` there).
  JSON over HTTPS, the box's key as `Authorization: Bearer ...`. Each
  answers `{:ok, body}`, `{:error, status, body}` for an answer that is not
  a 2xx, or `{:error, :unreachable}` when there was none.

  The key is never put in a URL, a log line or an error: `Req` is given it
  as a header, and what comes back is only ever the cloud's JSON.
  """

  alias Alnasl.Takeover

  @doc false
  def req_options, do: Application.get_env(:alnasl, :takeover_req_options, [])

  defp request(server, opts) do
    [base_url: server, retry: false, receive_timeout: 10_000, connect_options: [timeout: 5_000]]
    |> Keyword.merge(opts)
    |> Keyword.merge(req_options())
    |> Req.new()
  end

  defp call(server, key, method, path, opts) do
    headers = if key, do: [{"authorization", "Bearer " <> key}], else: []

    case Req.request(request(server, [method: method, url: path, headers: headers] ++ opts)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, if(is_map(body), do: body, else: %{})}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, status, if(is_map(body), do: body, else: %{})}

      {:error, _exception} ->
        {:error, :unreachable}
    end
  end

  @doc """
  Pairs this box with a hall: `link` is the link the cloud showed
  (`https://<cloud>/takeover/join/K7Q-4MD`) or only its code, for the
  default cloud (`Alnasl.Takeover.default_server/0`). `{:ok, %{server, key,
  hall, hall_id}}` or `{:error, reason}`.
  """
  def join(link, identity) do
    with {:ok, server, code} <- parse(link) do
      case call(server, nil, :post, "/takeover/join/" <> URI.encode(code), json: identity) do
        {:ok, %{"key" => key} = body} when is_binary(key) ->
          {:ok, %{server: server, key: key, hall: body["hall"], hall_id: body["hall_id"]}}

        {:error, status, _body} when status in [404, 410] ->
          {:error, :used_or_expired}

        {:error, 403, _body} ->
          {:error, :elsewhere}

        {:error, 429, _body} ->
          {:error, :rate_limited}

        {:error, :unreachable} ->
          {:error, :unreachable}

        _other ->
          {:error, :refused}
      end
    end
  end

  @doc false
  def parse(link) when is_binary(link) do
    link = String.trim(link)

    cond do
      link =~ ~r/\A[A-Za-z0-9]{3}-?[A-Za-z0-9]{4}\z/ ->
        {:ok, Takeover.default_server(), dashed(link)}

      true ->
        case URI.parse(link) do
          %URI{scheme: scheme, host: host, path: "/takeover/join/" <> code} = uri
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            server = URI.to_string(%URI{scheme: scheme, host: host, port: uri.port})
            {:ok, server, dashed(code)}

          _other ->
            {:error, :bad_link}
        end
    end
  end

  def parse(_link), do: {:error, :bad_link}

  defp dashed(code) do
    plain = code |> String.upcase() |> String.replace("-", "")

    if String.length(plain) == 7,
      do: String.slice(plain, 0, 3) <> "-" <> String.slice(plain, 3, 4),
      else: plain
  end

  @doc "`action`: \"claim\", \"standby\", \"take_over\" or \"release\"."
  def lease(server, key, action, fields \\ %{}),
    do: call(server, key, :post, "/takeover/lease", json: Map.put(fields, "action", action))

  def events(server, key, epoch, events),
    do:
      call(server, key, :post, "/takeover/events", json: %{"epoch" => epoch, "events" => events})

  def state(server, key, epoch, state),
    do: call(server, key, :put, "/takeover/state", json: %{"epoch" => epoch, "state" => state})

  def restore(server, key, epoch, after_id),
    do:
      call(server, key, :get, "/takeover/restore",
        params: [epoch: epoch] ++ if(after_id, do: [after: after_id], else: [])
      )
end
