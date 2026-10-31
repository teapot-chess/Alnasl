defmodule AlnaslWeb.SystemTest do
  @moduledoc """
  `/healthz` for everybody and nothing more; `/system` and
  `/system/dashboard` for the installation's admins and nobody else.
  """

  use AlnaslWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AlnaslWeb.AccountHelpers

  alias Alnasl.Ops.{ErrorReports, Health}

  @moduletag :capture_log

  describe "GET /healthz" do
    test "200 and the whole shape, without a session cookie", %{conn: conn} do
      server_mode()
      conn = get(conn, ~p"/healthz")

      assert %{
               "status" => "ok",
               "version" => version,
               "checks" => %{"database" => "ok", "backup" => "disabled", "bridge" => "ok"}
             } = json_response(conn, 200)

      assert version == to_string(Application.spec(:alnasl, :vsn))
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "says only those words: no names, no counts", %{conn: conn} do
      body = conn |> get(~p"/healthz") |> json_response(200)
      assert Map.keys(body) |> Enum.sort() == ~w(checks status version)
      assert Map.keys(body["checks"]) |> Enum.sort() == ~w(backup bridge database)
    end

    test "503 when the database is gone; the other checks never decide it", %{conn: conn} do
      report = %{
        status: "degraded",
        version: "0.0.0",
        checks: %{database: "unreachable", backup: "ok", bridge: "ok"}
      }

      conn = conn |> assign(:health_report, report) |> AlnaslWeb.HealthController.show(%{})
      assert %{"status" => "degraded"} = json_response(conn, 503)
    end

    test "a stale backup and a missing bridge process leave the status ok" do
      assert Health.bridge([:no_such_process_anywhere]) == "degraded"
      assert Health.bridge([Alnasl.BridgeRegistry]) == "ok"

      report = Health.report()
      assert report.status == "ok"
    end
  end

  describe "/system" do
    setup do
      server_mode()
      admin_emails(["admin@example.org"])
      admin = user_fixture("admin@example.org")
      hall = hall_fixture("Main hall")
      arbiter = member(hall, user_fixture("arbiter@example.org"), "arbiter")
      %{admin: admin, arbiter: arbiter, hall: hall}
    end

    test "an admin sees health, the backup and the errors", %{conn: conn, admin: admin} do
      ErrorReports.record(%{
        fingerprint: "f1",
        kind: "ArgumentError",
        message: "nope",
        location: "Alnasl.Thing.go/1",
        stacktrace: "Alnasl.Thing.go/1 (lib/thing.ex:1)"
      })

      {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/system")

      assert has_element?(view, "#system-health")
      assert has_element?(view, "#health-database")
      assert has_element?(view, "#offsite-disabled")
      assert has_element?(view, "#system-dashboard-link")
      [row] = ErrorReports.list()
      assert has_element?(view, "#errors-#{row.id}")

      view |> element("#error-forget-#{row.id}") |> render_click()
      assert ErrorReports.list() == []
      assert has_element?(view, "#errors-empty")
    end

    test "forget all", %{conn: conn, admin: admin} do
      for fp <- ~w(a b) do
        ErrorReports.record(%{
          fingerprint: fp,
          kind: "K",
          message: "m",
          location: nil,
          stacktrace: ""
        })
      end

      {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/system")
      view |> element("#errors-forget-all") |> render_click()
      assert ErrorReports.list() == []
    end

    test "somebody who is not an admin is sent away", %{conn: conn, arbiter: arbiter, hall: hall} do
      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> log_in(arbiter, hall) |> live(~p"/system")
    end

    test "nobody signed in is asked to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/log-in"}}} = live(conn, ~p"/system")
    end

    test "an admin removed from the list is stopped on the open page",
         %{conn: conn, admin: admin} do
      {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/system")
      admin_emails([])

      assert {:error, {:redirect, %{to: "/"}}} =
               view |> element("#system-refresh") |> render_click()
    end
  end

  describe "/system/dashboard" do
    setup do
      server_mode()
      admin_emails(["admin@example.org"])
      %{admin: user_fixture("admin@example.org"), other: user_fixture("other@example.org")}
    end

    test "opens for an admin", %{conn: conn, admin: admin} do
      conn = conn |> log_in(admin) |> get(~p"/system/dashboard")
      assert redirected_to(conn) =~ "/system/dashboard/"
      conn = conn |> recycle() |> log_in(admin) |> get(redirected_to(conn))
      assert html_response(conn, 200) =~ "LiveDashboard"
    end

    test "sends anybody else to the front page", %{conn: conn, other: other} do
      conn = conn |> log_in(other) |> get(~p"/system/dashboard/home")
      assert redirected_to(conn) == "/"
    end

    test "sends nobody signed in to the sign-in page", %{conn: conn} do
      conn = get(conn, ~p"/system/dashboard/home")
      assert redirected_to(conn) == "/log-in"
    end

    test "its socket refuses a non-admin too", %{conn: conn, other: other} do
      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> log_in(other) |> live("/system/dashboard/home")
    end
  end
end
