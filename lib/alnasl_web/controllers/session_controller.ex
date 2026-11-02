defmodule AlnaslWeb.SessionController do
  @moduledoc """
  Signing in with an address and a password, signing out, and the sign-in
  link of the QR code on Setup (`Alnasl.Accounts.use_qr_token/1`).

  Wrong passwords are counted (`Alnasl.Takeover.RateLimit`): ten in a
  quarter of an hour from one address, or against one account, and further
  tries wait out the quarter with a 429 - the right password included, or
  the count would tell a guesser when they hit it. Only failures count, so
  a hall full of arbiters signing in behind one router is not turned away.
  The address is the tunnel's `cf-connecting-ip` when the request comes
  from loopback, as for support uploads.
  """

  use AlnaslWeb, :controller

  alias Alnasl.{Accounts, Keycloak, Log}
  alias Alnasl.Takeover.RateLimit
  alias AlnaslWeb.UserAuth

  @failures 10
  @window_ms 15 * 60_000

  def new(conn, _params) do
    if Accounts.login_required?() do
      render_form(conn, nil)
    else
      # A box with no accounts has nobody to sign in.
      redirect(conn, to: ~p"/")
    end
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    keys = [
      {:sign_in_ip, AlnaslWeb.SupportController.client_ip(conn)},
      {:sign_in_email, normal(email)}
    ]

    case Enum.find_value(keys, &waiting/1) do
      nil -> attempt(conn, email, password, keys)
      seconds -> throttled(conn, seconds)
    end
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/log-in")

  def delete(conn, _params), do: UserAuth.log_out_user(conn)

  @doc "A phone that scanned the QR code: signed in once, within five minutes, as whoever made the code."
  def qr(conn, %{"token" => token} = params) do
    case Accounts.use_qr_token(token) do
      {:ok, user} ->
        UserAuth.log_in_user(conn, user, UserAuth.safe(params["to"]))

      :error ->
        conn
        |> put_flash(
          :error,
          gettext("That sign-in code is used or has run out. Make a new one on Setup.")
        )
        |> redirect(to: ~p"/log-in")
    end
  end

  defp attempt(conn, email, password, keys) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        Enum.each(keys, &RateLimit.hit(&1, @failures, @window_ms))
        Log.add(:warn, "account.refused", %{from: conn.remote_ip |> :inet.ntoa() |> to_string()})

        conn
        |> put_status(:unauthorized)
        |> render_form(gettext("That address and password do not match an account here."))

      user ->
        UserAuth.log_in_user(conn, user)
    end
  end

  defp waiting(key) do
    case RateLimit.peek(key, @failures, @window_ms) do
      :ok -> nil
      {:error, seconds} -> seconds
    end
  end

  defp throttled(conn, seconds) do
    minutes = div(seconds + 59, 60)
    Log.add(:warn, "account.throttled", %{from: conn.remote_ip |> :inet.ntoa() |> to_string()})

    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_status(:too_many_requests)
    |> render_form(
      ngettext(
        "Too many wrong passwords. Try again in %{count} minute.",
        "Too many wrong passwords. Try again in %{count} minutes.",
        minutes
      )
    )
  end

  defp normal(email), do: email |> String.trim() |> String.downcase()

  defp render_form(conn, error) do
    render(conn, :new,
      form: Phoenix.Component.to_form(%{"email" => "", "password" => ""}, as: :user),
      error: error,
      keycloak?: Keycloak.configured?(),
      server?: Accounts.server?()
    )
  end
end
