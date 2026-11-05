defmodule AlnaslWeb.DoorHTML do
  @moduledoc """
  The PIN page: the only page a browser from elsewhere sees before it has
  the PIN. A text field, not a keypad: a PIN may hold letters too. Its
  "Show" button is `assets/js/app.js`'s, since a page that is not a LiveView
  runs no LiveView commands.
  """

  use AlnaslWeb, :html

  def unlock(assigns) do
    ~H"""
    <Layouts.door flash={@flash} id="door" title={gettext("This box asks for a PIN")}>
      <form id="unlock-form" action={~p"/unlock"} method="post" class="stack">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <p class="note">
          {gettext(
            "You are reaching Alnasl from another machine. Type the PIN: the arbiter finds it on the box itself, in Setup, Access."
          )}
        </p>
        <div class="row align-end">
          <.input
            id="unlock-pin"
            name="pin"
            value=""
            type="password"
            label={gettext("PIN")}
            autocomplete="off"
            maxlength="64"
            required
          />
          <.button
            id="unlock-show"
            type="button"
            variant="ghost"
            data-show-secret="unlock-pin"
            aria-pressed="false"
            aria-controls="unlock-pin"
          >
            {gettext("Show")}
          </.button>
        </div>
        <p
          :if={@error}
          id="unlock-error"
          class="error bad-text strong"
          role="alert"
        >
          {@error}
        </p>
        <.button id="unlock-submit" variant="primary" type="submit">{gettext("Open")}</.button>
      </form>
    </Layouts.door>
    """
  end
end
