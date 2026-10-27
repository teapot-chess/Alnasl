defmodule AlnaslWeb.SupportTest do
  @moduledoc """
  Support from the outside: the upload address a box posts to, and the
  `/support` page and downloads, which exist for the support admins and are
  a 404 for everybody else - strangers, other accounts, and everybody at
  all while nobody is named.
  """

  use AlnaslWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AlnaslWeb.AccountHelpers

  alias Alnasl.Support

  @moduletag :capture_log

  setup do
    support_admins(["help@example.org"])
    helper = first_owner("help@example.org")
    other = user_fixture("someone@example.org")
    %{helper: helper, other: other}
  end

  defp upload_raw(conn, body, headers \\ []) do
    headers
    |> Enum.reduce(put_req_header(conn, "content-type", "text/plain"), fn {k, v}, c ->
      put_req_header(c, k, v)
    end)
    |> post(~p"/support/upload", body)
  end

  defp stored(text) do
    {:ok, upload} = Support.receive_upload(text, %{box_id: "box-7"}, "198.51.100.9")
    upload
  end

  describe "POST /support/upload" do
    test "a raw text body is kept, and the code comes back", %{conn: conn} do
      conn =
        upload_raw(conn, "diagnostics\n", [
          {"x-alnasl-box", "box-42"},
          {"x-alnasl-version", "0.11.0"},
          {"x-alnasl-mode", "kiosk"}
        ])

      assert %{"code" => code, "expires_at" => _} = json_response(conn, 201)
      upload = Support.get_live(code)
      assert upload.content == "diagnostics\n"
      assert {upload.box_id, upload.version, upload.mode} == {"box-42", "0.11.0", "kiosk"}
    end

    @tag :tmp_dir
    test "a multipart file is kept too", %{conn: conn, tmp_dir: dir} do
      path = Path.join(dir, "diag.txt")
      File.write!(path, "from a form")

      conn =
        post(conn, ~p"/support/upload", %{
          "file" => %Plug.Upload{path: path, filename: "diag.txt", content_type: "text/plain"}
        })

      assert %{"code" => code} = json_response(conn, 201)
      assert Support.get_live(code).filename == "diag.txt"
    end

    test "too large, not text, empty", %{conn: conn} do
      big = String.duplicate("a", Support.max_bytes() + 1)
      assert json_response(upload_raw(conn, big), 413) == %{"error" => "too_large"}
      assert json_response(upload_raw(build_conn(), <<0xFF, 0xFE>>), 415)["error"] == "not_text"
      assert json_response(upload_raw(build_conn(), ""), 400)["error"] == "empty"
    end

    test "rate-limited per sender, as Cloudflare names it", %{conn: _conn} do
      from = fn ip -> upload_raw(build_conn(), "x", [{"cf-connecting-ip", ip}]) end

      for _ <- 1..5, do: assert(json_response(from.("203.0.113.5"), 201))
      limited = from.("203.0.113.5")
      assert json_response(limited, 429) == %{"error" => "rate_limited"}
      assert get_resp_header(limited, "retry-after") == ["3600"]
      assert json_response(from.("203.0.113.6"), 201)
    end

    test "nobody named: refused, nothing kept", %{conn: conn} do
      support_admins([])
      assert json_response(upload_raw(conn, "x"), 404) == %{"error" => "not_found"}
      assert Alnasl.Repo.aggregate(Alnasl.Support.Upload, :count) == 0
    end
  end

  describe "who gets /support" do
    test "nobody signed in: 404, not the sign-in page", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/support") end
    end

    test "another account: 404", %{conn: conn, other: other} do
      assert_error_sent 404, fn -> get(log_in(conn, other), ~p"/support") end
    end

    test "the support admin, while nobody is named: 404", %{conn: conn, helper: helper} do
      support_admins([])
      assert_error_sent 404, fn -> get(log_in(conn, helper), ~p"/support") end
    end

    test "the support admin: the page, and Support in the menu", %{conn: conn, helper: helper} do
      {:ok, view, _html} = live(log_in(conn, helper), ~p"/support")
      assert has_element?(view, "#support-lookup-form")
      assert has_element?(view, "#nav-support")
    end

    test "nobody else has Support in the menu", %{conn: conn, other: other} do
      member(Alnasl.Repo.get!(Alnasl.Halls.Hall, Alnasl.Halls.own_id()), other, "owner")
      {:ok, view, _html} = live(log_in(conn, other), ~p"/boards")
      refute has_element?(view, "#nav-support")
    end

    test "taken off the list with the page open: the next event goes nowhere",
         %{conn: conn, helper: helper} do
      {:ok, view, _html} = live(log_in(conn, helper), ~p"/support")
      support_admins(["someone-else@example.org"])

      assert {:error, {:redirect, %{to: "/support"}}} =
               view |> form("#support-lookup-form", lookup: %{code: "123456"}) |> render_submit()
    end
  end

  describe "reading an upload" do
    test "found by its code, shown escaped", %{conn: conn, helper: helper} do
      upload = stored("<script>alert(1)</script>\n<b>bold</b>")
      {:ok, view, _html} = live(log_in(conn, helper), ~p"/support")

      view |> form("#support-lookup-form", lookup: %{code: upload.code}) |> render_submit()
      assert_patch(view, ~p"/support?#{[code: upload.code]}")

      html = view |> element("#support-content") |> render()
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute html =~ "<script>"
      refute html =~ "<b>"
      assert has_element?(view, "#support-recent-rows a", upload.code)
    end

    test "an unknown code says so", %{conn: conn, helper: helper} do
      {:ok, view, _html} = live(log_in(conn, helper), ~p"/support?code=000000")
      assert has_element?(view, "#support-not-found")
      refute has_element?(view, "#support-content")
    end

    test "downloaded as plain text by the support admin", %{conn: conn, helper: helper} do
      upload = stored("<html>not a page</html>")
      conn = get(log_in(conn, helper), ~p"/support/download/#{upload.code}")

      assert response(conn, 200) == "<html>not a page</html>"
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/plain"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end

    test "download refused to everybody else", %{conn: conn, other: other} do
      upload = stored("secret-ish")
      assert_error_sent 404, fn -> get(conn, ~p"/support/download/#{upload.code}") end

      assert_error_sent 404, fn ->
        get(log_in(build_conn(), other), ~p"/support/download/#{upload.code}")
      end
    end
  end
end
