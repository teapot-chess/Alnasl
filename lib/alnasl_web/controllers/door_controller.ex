defmodule AlnaslWeb.DoorController do
  @moduledoc """
  The two things that are plain requests rather than live pages: giving the
  PIN from another machine, and a person switching their language.
  """

  use AlnaslWeb, :controller

  alias Alnasl.{AccessPin, DoorGuard, Log}
  alias AlnaslWeb.Hall

  def unlock(conn, _params) do
    if Hall.allowed?(get_session(conn, :local) == true, get_session(conn, :unlocked)) do
      redirect(conn, to: ~p"/")
    else
      render(conn, :unlock, error: nil)
    end
  end

  def enter(conn, %{"pin" => pin}) do
    ip = conn.remote_ip
    from = ip |> :inet.ntoa() |> to_string()

    # Counted before it is compared: a burst of guesses cannot outrun the
    # count (`Alnasl.DoorGuard.claim/2`).
    case DoorGuard.claim(ip) do
      {:wait, seconds} ->
        Log.add(:warn, "door.throttled", %{from: from})

        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(:too_many_requests)
        |> render(:unlock,
          error:
            ngettext(
              "Too many wrong PINs. Try again in %{count} second.",
              "Too many wrong PINs. Try again in %{count} seconds.",
              seconds
            )
        )

      :ok ->
        if AccessPin.valid?(pin) do
          DoorGuard.succeeded(ip)
          Log.add(:info, "door.unlocked", %{from: from})

          # A stamp of the PIN, not "yes": a new PIN voids it. The socket id
          # lets a change of PIN close this browser's open pages too.
          conn
          |> configure_session(renew: true)
          |> put_session(:unlocked, Hall.pin_stamp())
          |> put_session(:live_socket_id, AccessPin.socket_id())
          |> redirect(to: ~p"/")
        else
          Log.add(:warn, "door.refused", %{from: from})

          conn
          |> put_status(:unauthorized)
          |> render(:unlock, error: gettext("That is not the PIN."))
        end
    end
  end

  def enter(conn, _params), do: redirect(conn, to: ~p"/unlock")

  def lock(conn, _params) do
    conn
    |> delete_session(:unlocked)
    |> delete_session(:live_socket_id)
    |> redirect(to: ~p"/unlock")
  end

  @doc """
  A person's language, from the account menu: kept on the account when
  someone is signed in, in a cookie of this browser when nobody is. It
  changes nobody else's - the box's default is Setup's, for an admin. A
  POST, so no link a browser prefetches switches it.
  """
  def locale(conn, %{"locale" => locale} = params) when locale in ["en", "nl"] do
    conn =
      case conn.assigns[:current_scope] do
        %{user: %Alnasl.Accounts.User{} = user} ->
          {:ok, _user} = Alnasl.Accounts.set_locale(user, locale)
          conn

        _nobody ->
          put_resp_cookie(conn, AlnaslWeb.Hall.locale_cookie(), locale,
            max_age: 365 * 86_400,
            same_site: "Lax",
            http_only: true
          )
      end

    redirect(conn, to: AlnaslWeb.UserAuth.local_path(params["return_to"]))
  end

  def locale(conn, params),
    do: redirect(conn, to: AlnaslWeb.UserAuth.local_path(params["return_to"]))
end
