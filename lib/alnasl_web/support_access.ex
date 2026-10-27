defmodule AlnaslWeb.SupportAccess do
  @moduledoc """
  The door of `/support`, in its three places: the plug in front of every
  request (the page and the downloads), the LiveView's `on_mount`, and the
  check every event of the page passes (`allowed?/1`). All three ask
  `Alnasl.Support.admin?/1` and nothing else.

  Everybody it turns away gets a 404 (`AlnaslWeb.NotFound`): somebody not
  signed in, somebody signed in who is not on the list, and everybody at
  all while the list is empty. Not a redirect to the sign-in page, which
  would tell a stranger that something lives here.
  """

  alias Alnasl.Support
  alias AlnaslWeb.UserAuth

  @doc "May this scope (or user) use the support pages? `Alnasl.Support.admin?/1`."
  def allowed?(scope_or_user), do: Support.admin?(scope_or_user)

  ## the plug

  def init(opts), do: opts

  @doc "Before anything else of the request: on the list, or a 404."
  def call(conn, _opts) do
    if allowed?(conn.assigns[:current_scope]), do: conn, else: raise(AlnaslWeb.NotFound)
  end

  ## the LiveView hook

  @doc """
  For the socket: read from the session, before `AlnaslWeb.Hall` builds
  the page's frame, so that nobody is sent anywhere (to their halls, say)
  before being told there is nothing here.
  """
  def on_mount(:default, _params, session, socket) do
    if allowed?(UserAuth.session_user(session)),
      do: {:cont, socket},
      else: raise(AlnaslWeb.NotFound)
  end
end
