defmodule AlnaslWeb.NotFound do
  @moduledoc """
  Raised for a page that, for this person, does not exist: answered as the
  same 404 an address nobody routes gets, so the answer says nothing about
  whether there was something there.
  """

  defexception message: "not found", plug_status: 404
end
