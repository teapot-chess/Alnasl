defmodule AlnaslWeb.ReadyController do
  @moduledoc """
  `GET /_ready`: is the server up, and can it reach its database.

  What the start screen (`rel/start/start.html`) asks while the program
  starts. It is a page on another origin (a file in the data folder) asking
  with `fetch(..., {mode: "no-cors"})`, so the answer is never read, only
  whether there is one; the body is for a person with `curl`.

  No pipeline, no session, no PIN, no CORS headers, and nothing in the
  answer that is not already true of every other page: `200 ok` or
  `503 starting`. One `select 1`, nothing cached.
  """

  use AlnaslWeb, :controller

  def show(conn, _params) do
    {status, body} =
      case Ecto.Adapters.SQL.query(Alnasl.Repo, "select 1", []) do
        {:ok, _} -> {200, "ok"}
        _ -> {503, "starting"}
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
