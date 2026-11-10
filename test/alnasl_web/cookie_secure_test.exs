defmodule AlnaslWeb.CookieSecureTest do
  use ExUnit.Case, async: true

  test "a deployment that is not https does not mark its cookies secure" do
    refute AlnaslWeb.Endpoint.secure_cookies?()
    refute Keyword.fetch!(AlnaslWeb.Endpoint.session_options(), :secure)
  end
end
