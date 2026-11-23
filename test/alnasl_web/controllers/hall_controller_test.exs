defmodule AlnaslWeb.HallControllerTest do
  @moduledoc """
  The hall picker remembers: the hall an account last entered is where its
  next session opens - after a sign-out, a closed browser, another phone -
  unless that hall is gone or no longer the account's, when it is the first
  hall it may see, as before.
  """

  use AlnaslWeb.SiteCase, async: false

  @moduletag :capture_log

  import AlnaslWeb.AccountHelpers
  import Ecto.Query, only: [from: 2]

  alias Alnasl.{Accounts, Repo}
  alias Alnasl.Halls.Member

  setup do
    _admin = first_owner()
    a = hall_fixture("Hall A")
    b = hall_fixture("Hall B")
    user = user_fixture("both@example.org")
    member(a, user, "arbiter")
    member(b, user, "arbiter")
    %{a: a, b: b, user: user}
  end

  defp front_page_hall(conn, user) do
    {:ok, view, _html} = live(log_in(conn, user), ~p"/")
    view |> element("#hall-picker-current") |> render()
  end

  test "entering a hall is remembered for the next session", %{conn: conn, b: b, user: user} do
    assert front_page_hall(build_conn(), user) =~ "Hall A"

    conn = get(log_in(conn, user), ~p"/halls/#{b.id}/enter?return_to=/boards")
    assert redirected_to(conn) == "/boards"
    assert Accounts.get_user(user.id).last_hall_id == b.id

    # A fresh session: what the remember cookie or a new sign-in gives.
    assert front_page_hall(build_conn(), Accounts.get_user(user.id)) =~ "Hall B"
  end

  test "the session's own hall still wins over the remembered one", ctx do
    %{conn: conn, a: a, b: b, user: user} = ctx
    {:ok, user} = Accounts.remember_hall(user, b.id)

    {:ok, view, _html} = live(log_in(conn, user, a), ~p"/")
    assert view |> element("#hall-picker-current") |> render() =~ "Hall A"
  end

  test "a remembered hall the account lost is not opened", ctx do
    %{conn: conn, b: b, user: user} = ctx
    # A third hall, so there is still a picker to read once B is gone.
    member(hall_fixture("Hall C"), user, "viewer")
    {:ok, user} = Accounts.remember_hall(user, b.id)
    Repo.delete_all(from m in Member, where: m.user_id == ^user.id and m.hall_id == ^b.id)

    html = front_page_hall(conn, user)
    assert html =~ "Hall A"
    refute html =~ "Hall B"
  end

  test "a remembered hall that is gone is not opened", %{conn: conn, user: user} do
    {:ok, user} = Accounts.remember_hall(user, 999_999)
    assert front_page_hall(conn, user) =~ "Hall A"
  end

  test "a hall not one's own is neither entered nor remembered", %{conn: conn, user: user} do
    stranger = hall_fixture("Hall C")

    conn = get(log_in(conn, user), ~p"/halls/#{stranger.id}/enter")
    assert redirected_to(conn) == ~p"/halls"
    assert Accounts.get_user(user.id).last_hall_id == nil
  end
end
