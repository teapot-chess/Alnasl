defmodule AlnaslWeb.ReadyControllerTest do
  use AlnaslWeb.ConnCase, async: true

  test "answers ok without a session, a PIN or a header", %{conn: conn} do
    conn = get(conn, "/_ready")
    assert response(conn, 200) == "ok"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
