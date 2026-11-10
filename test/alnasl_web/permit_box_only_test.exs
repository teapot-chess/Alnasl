defmodule AlnaslWeb.PermitBoxOnlyTest do
  @moduledoc """
  On a box without accounts the PIN opens the pages, but updates, the
  tracker's reset, takeover pairing and the off-site backup stay with the
  box's own browser.
  """

  use ExUnit.Case, async: true

  alias Alnasl.Accounts.Scope
  alias AlnaslWeb.{Permit, SetupLive, SpareLive, SystemLive}

  @open %Scope{open?: true}

  @box_only [
    {SetupLive, "save_update_mode"},
    {SetupLive, "check_update"},
    {SetupLive, "update_start"},
    {SetupLive, "update_cancel"},
    {SetupLive, "update_apply"},
    {SetupLive, "reset_tracker"},
    {SpareLive, "pair"},
    {SpareLive, "leave"},
    {SpareLive, "auto"},
    {SystemLive, "send_now"},
    {SetupLive, "update_later"},
    {SetupLive, "update_never"}
  ]

  test "a browser that gave the PIN is refused the box's own things" do
    for {view, event} <- @box_only do
      refute Permit.allowed?(@open, view, event, %{}, %{local?: false}), "#{view} #{event}"
      refute Permit.allowed?(@open, view, event, %{}, %{}), "#{view} #{event}"
    end
  end

  test "the box's own browser may" do
    for {view, event} <- @box_only do
      assert Permit.allowed?(@open, view, event, %{}, %{local?: true}), "#{view} #{event}"
    end
  end

  test "an arbiter's phone still does what an arbiter does" do
    assert Permit.allowed?(@open, SpareLive, "take_over", %{}, %{local?: false})
    assert Permit.allowed?(@open, SetupLive, "toggle_quiet", %{}, %{local?: false})
  end

  test "with accounts the level decides, not the address" do
    admin = %Scope{admin?: true}
    assert Permit.allowed?(admin, SetupLive, "update_apply", %{}, %{local?: false})
    assert Permit.box_owner?(admin, %{local?: false})
  end
end
