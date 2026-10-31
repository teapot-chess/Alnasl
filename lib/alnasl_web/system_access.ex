defmodule AlnaslWeb.SystemAccess do
  @moduledoc """
  The door of `/system` and `/system/dashboard`: the installation's admins
  (`Alnasl.Accounts.Scope.can?(scope, :admin)` - the box's first account,
  the addresses in `ALNASL_ADMIN_EMAILS`, and everybody past the PIN on a
  box with no accounts, who may change the PIN itself anyway). No new rule:
  the one Setup's box-wide switches already answer to.

  In three places, like `AlnaslWeb.SupportAccess`: the plug in front of the
  dashboard's HTTP request, the `on_mount` of the System page and of the
  dashboard's socket, and `allowed?/1` on every event of the System page.
  The sign-in and the PIN come first (`AlnaslWeb.Hall`'s gate); somebody
  past them who is not an admin is sent to the front page, with a word.
  """

  use Gettext, backend: AlnaslWeb.Gettext

  alias Alnasl.Accounts
  alias Alnasl.Accounts.{Scope, User}
  alias AlnaslWeb.Hall

  @doc """
  Is this scope an admin of the installation - asked again of the database
  for an account, so that somebody taken off the list stops on a page that
  is already open.
  """
  def allowed?(%Scope{open?: true} = scope), do: Scope.can?(scope, :admin)

  def allowed?(%Scope{user: %User{id: id}}) do
    case Accounts.get_user(id) do
      %User{} = user -> Accounts.admin?(user)
      nil -> false
    end
  end

  def allowed?(_nobody), do: false

  @doc false
  def refusal, do: gettext("That page is for the admins of this installation.")

  ## the plug

  def init(opts), do: opts

  def call(conn, _opts) do
    if allowed?(conn.assigns[:current_scope]) do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, refusal())
      |> Phoenix.Controller.redirect(to: "/")
      |> Plug.Conn.halt()
    end
  end

  ## the LiveView hook

  @doc """
  For a socket. Inside the site's own pages `AlnaslWeb.Hall` has put the
  scope there already; the dashboard's socket has only the session, and
  gets the same answer from it that the site's pages would.
  """
  def on_mount(:default, _params, session, socket) do
    scope =
      case socket.assigns[:current_scope] do
        %Scope{} = scope ->
          scope

        _none ->
          case Hall.session_scope(session) do
            {:ok, scope} -> scope
            _away -> nil
          end
      end

    if allowed?(scope) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, refusal())
       |> Phoenix.LiveView.redirect(to: "/")}
    end
  end
end
