defmodule AlnaslWeb.SupportController do
  @moduledoc """
  The two plain HTTP ends of support uploads (`Alnasl.Support`).

  ## `POST /support/upload`

  From a box, not a browser: no session, no CSRF token, no account. The
  body is the diagnostics file, either as the raw body (`text/plain`) or
  as the field `file` of a `multipart/form-data` form. Optional headers
  say what sent it: `x-alnasl-box` (the box's id), `x-alnasl-version`,
  `x-alnasl-mode`.

    * `201` `{"code": "123456", "expires_at": "..."}` - kept; the code is
      what the person reads out to support.
    * `400` `{"error": "empty"}`
    * `413` `{"error": "too_large"}` - over `Alnasl.Support.max_bytes/0`.
    * `415` `{"error": "not_text"}` - not UTF-8 text, or a JSON or
      urlencoded body.
    * `429` `{"error": "rate_limited"}` - with `retry-after`.
    * `404` `{"error": "not_found"}` - support is off here.

  ## `GET /support/download/:code`

  For the support admins only (`AlnaslWeb.SupportAccess`, in the router's
  pipeline and asked again here): the file as `text/plain`, as an
  attachment. Everybody else, and an unknown or expired code: 404.
  """

  use AlnaslWeb, :controller

  alias Alnasl.Support

  # Support off: not a byte of the body is read.
  def upload(conn, params) do
    if Support.enabled?(), do: receive_upload(conn, params), else: refuse(conn, :disabled)
  end

  defp receive_upload(conn, params) do
    result =
      with {:ok, content, filename, conn} <- body(conn, params) do
        meta = %{
          filename: filename,
          box_id: header(conn, "x-alnasl-box"),
          version: header(conn, "x-alnasl-version"),
          mode: header(conn, "x-alnasl-mode")
        }

        {Support.receive_upload(content, meta, client_ip(conn)), conn}
      end

    case result do
      {{:ok, upload}, conn} ->
        conn
        |> put_status(201)
        |> json(%{code: upload.code, expires_at: DateTime.to_iso8601(upload.expires_at)})

      {{:error, reason}, conn} ->
        refuse(conn, reason)

      {:error, reason, conn} ->
        refuse(conn, reason)
    end
  end

  # The file: the form's `file`, or the raw body. Read no further than one
  # byte past the limit, which is enough to know it is past it.
  defp body(conn, %{"file" => %Plug.Upload{path: path, filename: filename}}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        if size > Support.max_bytes(),
          do: {:error, :too_large, conn},
          else: {:ok, File.read!(path), filename, conn}

      _empty ->
        {:error, :empty, conn}
    end
  end

  defp body(conn, _params) do
    case content_type(conn) do
      type when type in ["application/json", "application/x-www-form-urlencoded"] ->
        {:error, :not_text, conn}

      "multipart/form-data" ->
        {:error, :empty, conn}

      _raw ->
        case read_body(conn, length: Support.max_bytes() + 1, read_length: 256_000) do
          {:ok, content, conn} -> {:ok, content, nil, conn}
          {:more, _partial, conn} -> {:error, :too_large, conn}
          {:error, _reason} -> {:error, :empty, conn}
        end
    end
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] -> type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      [] -> nil
    end
  end

  defp refuse(conn, :disabled), do: answer(conn, 404, "not_found")
  defp refuse(conn, :empty), do: answer(conn, 400, "empty")
  defp refuse(conn, :too_large), do: answer(conn, 413, "too_large")
  defp refuse(conn, :not_text), do: answer(conn, 415, "not_text")

  defp refuse(conn, :rate_limited) do
    conn |> put_resp_header("retry-after", "3600") |> answer(429, "rate_limited")
  end

  defp refuse(conn, _other), do: answer(conn, 503, "try_again")

  defp answer(conn, status, error), do: conn |> put_status(status) |> json(%{error: error})

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  # Who is sending, for the rate limit. Behind the Cloudflare tunnel every
  # request arrives from the loopback address and the sender is in
  # `cf-connecting-ip`, which Cloudflare sets itself. The header is
  # believed only from the loopback address: anybody reaching the port
  # directly could write it.
  @doc false
  def client_ip(conn) do
    peer = conn.remote_ip

    with true <- loopback?(peer),
         [forwarded | _] <- get_req_header(conn, "cf-connecting-ip"),
         {:ok, ip} <- forwarded |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      ip |> :inet.ntoa() |> to_string()
    else
      _ -> peer |> :inet.ntoa() |> to_string()
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_other), do: false

  def download(conn, %{"code" => code}) do
    with true <- Support.admin?(conn.assigns[:current_scope]),
         %{} = upload <- Support.get_live(code) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> send_download({:binary, upload.content},
        filename: "alnasl-support-#{upload.code}.txt",
        content_type: "text/plain",
        charset: "utf-8"
      )
    else
      _ -> raise AlnaslWeb.NotFound
    end
  end
end
