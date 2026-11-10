defmodule AlnaslWeb.SessionHTML do
  @moduledoc "The sign-in page."

  use AlnaslWeb, :html

  def qr(assigns) do
    ~H"""
    <Layouts.door flash={@flash} id="log-in-qr" title={gettext("Sign in")}>
      <div class="stack">
        <p class="note">{gettext("Sign in on this phone with the code you scanned?")}</p>

        <.form
          for={%{}}
          id="log-in-qr-form"
          action={~p"/log-in/qr/#{@token}"}
          method="post"
          class="stack"
        >
          <input type="hidden" name="to" value={@to} />
          <.button id="log-in-qr-submit" variant="primary" type="submit">
            {gettext("Sign in")}
          </.button>
        </.form>
      </div>
    </Layouts.door>
    """
  end

  def new(assigns) do
    ~H"""
    <Layouts.door flash={@flash} id="log-in" title={gettext("Sign in")}>
      <div class="stack">
        <p :if={@server?} id="log-in-invitation-only" class="note">
          {gettext(
            "This Alnasl is reached by invitation. An admin or a hall's owner sends you a link; a 02cloud login alone does not get you in."
          )}
        </p>

        <.form for={@form} id="log-in-form" action={~p"/log-in"} class="stack">
          <.input
            field={@form[:email]}
            type="text"
            label={gettext("Email address")}
            autocomplete="username"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            autocomplete="current-password"
            required
          />
          <p :if={@error} id="log-in-error" class="error" role="alert">{@error}</p>
          <.button id="log-in-submit" variant="primary" type="submit">{gettext("Sign in")}</.button>
        </.form>

        <div :if={@keycloak?}>
          <.button id="log-in-keycloak" href={~p"/auth/keycloak"}>
            {gettext("Sign in with 02cloud")}
          </.button>
        </div>

        <p class="note">
          {gettext(
            "Forgot your password? Alnasl sends no mail: an admin can give you a temporary one."
          )}
        </p>
      </div>
    </Layouts.door>
    """
  end
end
