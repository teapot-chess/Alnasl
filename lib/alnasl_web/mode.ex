defmodule AlnaslWeb.Mode do
  @moduledoc """
  Simple mode and full mode: how much of the site a person is shown.

  Simple mode is the default and has the basics for running a hall: the
  live boards and their games, the Boards page with its numbering run
  (touch a board, it gets the next table), the halls and their bridges,
  the setup that gets a tournament onto the boards (the wizard,
  Tournaments, Connections, Updates on a box), and the manual. Full mode
  ("Show everything") adds the rest: PGN, the outbox, the log, recordings,
  the phone page for finding a board in the hall, fair play, support, and
  the advanced Setup sections. Nothing is removed in simple mode; the pages are left out of
  the menu, and a link to one shows `AlnaslWeb.Layouts.full_mode_notice/1`
  with the switch instead of the page. docs/simple-mode.md says why each
  page is on its side of the line.

  ## Where it is kept

  An account keeps its own choice on its row (`users.ui_mode`), `nil` until
  it makes one. Without a choice, or on a box without accounts, the
  installation's word counts (`Settings` "ui_mode"): "simple" for a new
  installation, "full" for one that was in use before simple mode existed
  (the `ui_mode` migration). On a box without accounts the switch changes
  the installation's word, for every browser of the hall, which is all such
  a box can tell apart; the open pages follow it at once.

  The mode is worked out once, when a page mounts (`mount/1`, from
  `AlnaslWeb.Hall`), and kept on the scope (`Scope.mode`), where the frame
  and the pages read it without asking the database again.

  It is about what is shown, not about who may do what: the roles
  (`AlnaslWeb.Permit`) and fair play's own rule (`Alnasl.FairPlay.Access`)
  are the same in both modes.
  """

  use Gettext, backend: AlnaslWeb.Gettext

  alias Alnasl.{Accounts, Settings}
  alias Alnasl.Accounts.{Scope, User}

  @modes ~w(simple full)

  # The first segment of an address that is full mode's alone.
  @full_pages ~w(pgn outbox log recordings fair-play support)

  # Setup's sections that simple mode leaves out: the wizard, Tournaments,
  # Connections and Updates stay.
  @full_sections ~w(results this-box access advanced)

  @doc "The modes, in the order they are offered."
  def modes, do: @modes

  @doc "The mode for `scope`: the account's choice, else the installation's."
  def mode(%Scope{user: %User{ui_mode: mode}}) when mode in @modes, do: mode
  def mode(_scope), do: installation()

  @doc "The installation's mode: what a box without accounts, and an account without a choice, sees."
  def installation do
    case Settings.get("ui_mode") do
      mode when mode in @modes -> mode
      _other -> "simple"
    end
  end

  @doc "The scope with its mode worked out, for the frame and the pages."
  def mount(%Scope{} = scope), do: %{scope | mode: mode(scope)}
  def mount(scope), do: scope

  @doc "Is `scope` in simple mode?"
  def simple?(%Scope{mode: mode}) when mode in @modes, do: mode == "simple"
  def simple?(%Scope{} = scope), do: mode(scope) == "simple"
  def simple?(_scope), do: installation() == "simple"

  @doc """
  Is the page at `path` full mode's alone? A path with or without its
  query; the routes are `AlnaslWeb.Router`'s.
  """
  def full_only?(path) when is_binary(path) do
    case path |> URI.parse() |> Map.get(:path) |> to_string() |> String.split("/", trim: true) do
      [page | _rest] when page in @full_pages -> true
      ["boards", "find" | _rest] -> true
      ["setup", section | _rest] when section in @full_sections -> true
      ["halls", _id, "fair-play" | _rest] -> true
      _other -> false
    end
  end

  def full_only?(_path), do: false

  @doc "Is the page at `path` out of sight for `scope`: simple mode, and a full-mode page?"
  def hidden?(scope, path), do: full_only?(path) and simple?(scope)

  @doc "Is Setup's section `slug` shown to `scope`?"
  def section?(scope, slug), do: not hidden?(scope, "/setup/" <> slug)

  @doc """
  Keeps `mode` for `scope`: on the account, or - a box without accounts -
  for the installation. The scope comes back with the mode in it.
  """
  def put(%Scope{user: %User{} = user} = scope, mode) when mode in @modes do
    case Accounts.set_ui_mode(user, mode) do
      {:ok, user} -> %{scope | user: user, mode: mode}
      {:error, _changeset} -> scope
    end
  end

  def put(%Scope{open?: true} = scope, mode) when mode in @modes do
    Settings.put("ui_mode", mode)
    %{scope | mode: mode}
  end

  def put(scope, _mode), do: scope

  @doc """
  The `handle_event` hook every page has (`AlnaslWeb.Hall`): "ui_mode" with
  `mode` "simple" or "full", from the switch in the account menu, the rail,
  and the notice on a full-mode page.
  """
  def event("ui_mode", %{"mode" => mode}, socket) when mode in @modes do
    scope = put(socket.assigns.current_scope, mode)

    socket =
      socket
      |> Phoenix.Component.assign(current_scope: scope, simple?: simple?(scope))
      |> Phoenix.LiveView.put_flash(:info, switched(mode))

    {:halt, socket}
  end

  def event("ui_mode", _params, socket), do: {:halt, socket}
  def event(_event, _params, socket), do: {:cont, socket}

  defp switched("full"), do: gettext("Every page is in the menu now.")
  defp switched("simple"), do: gettext("Simple mode: the basics only.")

  @doc """
  Another browser changed the installation's mode (a box without accounts):
  the scope and `simple?` follow it. An account's own choice is its own,
  and is left alone.
  """
  def follow(%{assigns: %{current_scope: %Scope{user: nil} = scope}} = socket) do
    scope = mount(scope)
    Phoenix.Component.assign(socket, current_scope: scope, simple?: simple?(scope))
  end

  def follow(socket), do: socket
end
