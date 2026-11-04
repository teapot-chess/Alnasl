defmodule AlnaslWeb.AccessPinWebTest do
  @moduledoc """
  The PIN from a browser's side: the PIN page, who is asked, who sees it,
  and what a change does to the browsers that gave the old one.
  """

  use AlnaslWeb.SiteCase, async: false

  alias Alnasl.{AccessPin, DoorGuard, Log}

  @pin "zq-7731 pin"

  setup do
    DoorGuard.reset()
    :ok = AccessPin.set(@pin)
    on_exit(&DoorGuard.reset/0)
  end

  defp far(conn), do: %{conn | remote_ip: {192, 168, 1, 77}}

  defp unlocked(conn) do
    conn
    |> far()
    |> post(~p"/unlock", %{"pin" => @pin})
    |> recycle()
    |> far()
  end

  describe "the PIN page" do
    test "a text field with a show button, not a keypad", %{conn: conn} do
      html = conn |> far() |> get(~p"/unlock") |> html_response(200)
      doc = LazyHTML.from_document(html)

      assert [input] = doc |> LazyHTML.query("#unlock-pin") |> Enum.to_list()
      assert LazyHTML.attribute(input, "type") == ["password"]
      assert LazyHTML.attribute(input, "inputmode") == []
      assert LazyHTML.attribute(input, "maxlength") == ["64"]
      assert Enum.count(LazyHTML.query(doc, "#unlock-show[data-show-secret=unlock-pin]")) == 1
      refute html =~ @pin
    end

    test "the box's own browser is never asked", %{conn: conn} do
      assert conn |> get(~p"/help") |> html_response(200)
      assert redirected_to(get(conn, ~p"/unlock")) == ~p"/"
      assert {:ok, _view, _html} = live(conn, ~p"/")
    end

    test "every other machine is asked, and let in with the right PIN", %{conn: conn} do
      assert redirected_to(conn |> far() |> get(~p"/")) == ~p"/unlock"
      assert {:error, {:redirect, %{to: "/unlock"}}} = live(far(conn), ~p"/")

      inside = unlocked(conn)
      assert inside |> get(~p"/help") |> html_response(200)
      assert {:ok, _view, _html} = live(inside, ~p"/help")
    end

    test "the grant is a stamp, not the PIN and not a yes", %{conn: conn} do
      opened = conn |> far() |> post(~p"/unlock", %{"pin" => @pin})
      grant = get_session(opened, :unlocked)
      assert is_binary(grant) and grant != @pin and grant == AlnaslWeb.Hall.pin_stamp()
      refute AlnaslWeb.Hall.granted?(true)
    end

    test "the right PIN is refused while the address waits", %{conn: conn} do
      for _ <- 1..5,
          do: assert(conn |> far() |> post(~p"/unlock", %{"pin" => "wrong!"}) |> response(401))

      assert conn |> far() |> post(~p"/unlock", %{"pin" => @pin}) |> response(429) =~ "Too many"
    end

    test "the PIN is never in the log", %{conn: conn} do
      unlocked(conn)
      conn |> far() |> post(~p"/unlock", %{"pin" => "not-it-123"})
      text = Log.list() |> Enum.map_join(" ", &(&1.data || ""))
      refute text =~ @pin
      refute text =~ "not-it-123"
    end
  end

  describe "a change of PIN" do
    test "voids every earlier grant and closes the open pages", %{conn: conn} do
      inside = unlocked(conn)
      assert inside |> get(~p"/help") |> html_response(200)

      AlnaslWeb.Endpoint.subscribe(AccessPin.socket_id())
      {:ok, _pin} = AccessPin.renew()
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: "access_pin"}

      assert redirected_to(get(inside, ~p"/help")) == ~p"/unlock"
      assert {:error, {:redirect, %{to: "/unlock"}}} = live(inside, ~p"/help")
    end

    test "from Setup on the box: written to access-pin, the others out", %{conn: conn} do
      inside = unlocked(conn)

      {:ok, view, _html} = live(conn, ~p"/setup/access")
      assert has_element?(view, "#pin-value", @pin)
      refute has_element?(view, "#clear-pin")
      assert has_element?(view, "#pin-input[type=password]")
      assert has_element?(view, "#pin-input-show")

      assert view |> form("#pin-form", door: %{pin: " spaced"}) |> render_submit() =~ "space"
      assert AccessPin.current() == @pin

      view |> form("#pin-form", door: %{pin: "new pin 42"}) |> render_submit()
      assert File.read!(AccessPin.path()) == "new pin 42\n"

      unless match?({:win32, _}, :os.type()) do
        assert {:ok, %File.Stat{mode: mode}} = File.stat(AccessPin.path())
        assert Bitwise.band(mode, 0o777) == 0o600
      end

      assert redirected_to(get(inside, ~p"/help")) == ~p"/unlock"

      view |> element("#new-pin") |> render_click()
      assert AccessPin.current() =~ ~r/\A\d{6}\z/
      assert has_element?(view, "#pin-value", AccessPin.current())
    end
  end

  describe "who sees the PIN" do
    test "not a browser that gave it: no PIN, no form, and its events do nothing", %{conn: conn} do
      inside = unlocked(conn)
      {:ok, view, html} = live(inside, ~p"/setup/access")
      refute html =~ @pin
      assert has_element?(view, "#pin-elsewhere")
      refute has_element?(view, "#pin-form")

      render_hook(view, "save_pin", %{"door" => %{"pin" => "taken over"}})
      render_hook(view, "new_pin", %{})
      assert AccessPin.current() == @pin
    end

    test "never on the hall's pages or the phone panel", %{conn: conn} do
      for path <- [~p"/", ~p"/round/1", ~p"/round/1/board/1", ~p"/boards", ~p"/help"] do
        {:ok, _view, html} = live(conn, path)
        refute html =~ @pin, path
      end
    end

    test "the box's own browser is told once that an old hash was replaced", %{conn: conn} do
      Alnasl.Settings.put("pin_notice", true)
      {:ok, view, _html} = live(conn, ~p"/setup")
      assert has_element?(view, "#pin-notice-value", @pin)
      view |> element("#pin-notice-seen") |> render_click()
      refute has_element?(view, "#pin-notice")
      refute AccessPin.notice?()

      Alnasl.Settings.put("pin_notice", true)
      {:ok, _view, html} = live(unlocked(conn), ~p"/setup")
      refute html =~ @pin
    end
  end
end
