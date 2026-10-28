defmodule AlnaslWeb.TakeoverPagesTest do
  @moduledoc """
  The pages of a spare box (`AlnaslWeb.SpareLive`, the hall's Boxes tab in
  `AlnaslWeb.HallsLive`, the status line in the layout): each phase shows
  what it may do and nothing that would fight the box that runs the hall,
  and the cloud's buttons are an arbiter's and an owner's only.
  """

  use AlnaslWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Alnasl.TakeoverHelpers
  import AlnaslWeb.AccountHelpers

  alias Alnasl.Takeover
  alias Alnasl.Takeover.{Cloud, Link}

  setup do
    cloud_on()

    if :ets.whereis(Takeover.runtime_table()) == :undefined,
      do: :ets.new(Takeover.runtime_table(), [:named_table, :public])

    %{hall: hall_fixture("Cloud hall")}
  end

  describe "/spare on a box" do
    test "not paired: the pairing field; pairing makes it the active box", %{
      conn: conn,
      hall: hall
    } do
      {:ok, view, _html} = live(conn, ~p"/spare")
      assert has_element?(view, "#spare-unpaired")
      assert has_element?(view, "#spare-pair-form")
      refute has_element?(view, "#spare-status")
      refute has_element?(view, "#takeover-line")

      {:ok, join} = Cloud.create_join(hall.id)

      view
      |> form("#spare-pair-form", pair: %{link: "http://cloud.test/takeover/join/" <> join.code})
      |> render_submit()

      render_async(view)
      assert has_element?(view, "#spare-status")
      assert has_element?(view, "#spare-active")
      assert has_element?(view, "#spare-make-spare")
      assert has_element?(view, "#spare-queued")
      refute has_element?(view, "#spare-take-over")
      refute render(view) =~ Takeover.key()
    end

    test "a used code says so and pairs nothing", %{conn: conn, hall: hall} do
      {:ok, join} = Cloud.create_join(hall.id)
      other_box_with(join.code)

      {:ok, view, _html} = live(conn, ~p"/spare")

      view
      |> form("#spare-pair-form", pair: %{link: "http://cloud.test/takeover/join/" <> join.code})
      |> render_submit()

      render_async(view)
      assert has_element?(view, "#spare-message")
      assert has_element?(view, "#spare-unpaired")
      assert Takeover.phase() == :unlinked
    end

    test "a spare: Take over and the auto switch; pressing it runs the hall", ctx do
      %{conn: conn, hall: hall} = ctx
      %{box: active} = other_box(hall, "Active")
      {:granted, _lease, :none} = Cloud.claim(active, nil)
      pair_this_box(hall, "spare")

      {:ok, view, _html} = live(conn, ~p"/spare")
      assert has_element?(view, "#spare-standing-by")
      assert has_element?(view, "#spare-take-over")
      assert has_element?(view, "#spare-auto")
      refute has_element?(view, "#spare-make-spare")
      assert has_element?(view, "#takeover-line")

      view |> form("#spare-auto-form", %{"auto" => "false"}) |> render_change()
      assert Takeover.config()["auto"] == false

      view |> element("#spare-take-over") |> render_click()
      render_async(view)
      assert has_element?(view, "#spare-active")
      assert Cloud.lease(hall.id).box_id != active.id
    end

    test "superseded: only Stand by as a spare", %{conn: conn, hall: hall} do
      pair_this_box(hall)
      %{box: spare} = other_box(hall, "Other box")
      {:granted, _lease, :other} = Cloud.hand_over(hall.id, spare.id)
      {:error, :superseded} = Link.step_now()

      {:ok, view, _html} = live(conn, ~p"/spare")
      assert has_element?(view, "#spare-superseded")
      assert has_element?(view, "#spare-superseded", "Other box")
      assert has_element?(view, "#spare-stand-by")
      refute has_element?(view, "#spare-take-over")
      refute has_element?(view, "#spare-make-spare")
      refute has_element?(view, "#spare-active")

      view |> element("#spare-stand-by") |> render_click()
      render_async(view)
      assert has_element?(view, "#spare-standing-by")
    end

    test "the status line is on every page and says where the box stands", %{
      conn: conn,
      hall: hall
    } do
      pair_this_box(hall)
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#takeover-line", "Streaming to the cloud")

      put_env(:takeover_req_options,
        plug: fn conn -> Req.Test.transport_error(conn, :econnrefused) end
      )

      Alnasl.Games.ensure(1, 1)
      |> Alnasl.Games.apply_event({:moves, [%{san: "e4"}, %{san: "e5"}]}, 1)

      Link.step_now()
      assert has_element?(view, "#takeover-line", "Offline, 3 events queued")
    end

    test "leaving forgets the hall and the key", %{conn: conn, hall: hall} do
      pair_this_box(hall)
      {:ok, view, _html} = live(conn, ~p"/spare")
      view |> element("#spare-leave") |> render_click()
      render_async(view)
      assert has_element?(view, "#spare-unpaired")
      assert Takeover.key() == nil
    end
  end

  describe "the hall's Boxes tab in the cloud" do
    setup %{hall: hall} do
      _admin = first_owner()
      owner = member(hall, user_fixture("hall-owner@example.org"), "owner")
      arbiter = member(hall, user_fixture("arbiter@example.org"), "arbiter")
      viewer = member(hall, user_fixture("viewer@example.org"), "viewer")
      %{box: active} = other_box(hall, "Active")
      %{box: spare} = other_box(hall, "Spare")
      {:granted, _lease, :none} = Cloud.claim(active, nil)
      %{owner: owner, arbiter: arbiter, viewer: viewer, active: active, spare: spare}
    end

    test "an arbiter pairs a box and hands the hall over", ctx do
      %{conn: conn, hall: hall, arbiter: arbiter, active: active, spare: spare} = ctx
      {:ok, view, _html} = live(log_in(conn, arbiter, hall), ~p"/halls/#{hall.id}/boxes")

      assert has_element?(view, "#hall-boxes")
      assert has_element?(view, "#box-#{active.id}-active")
      assert has_element?(view, "#box-#{spare.id}-take-over")
      refute has_element?(view, "#box-#{active.id}-take-over")
      refute has_element?(view, "#box-#{spare.id}-remove")

      view |> element("#box-pair") |> render_click()
      assert has_element?(view, "#box-join-code")
      assert has_element?(view, "#box-join-link", "/takeover/join/")

      view |> element("#box-#{spare.id}-take-over") |> render_click()
      assert has_element?(view, "#box-message")
      assert has_element?(view, "#box-#{spare.id}-active")
      assert Cloud.lease(hall.id).box_id == spare.id
    end

    test "a viewer sees the boxes and presses nothing", ctx do
      %{conn: conn, hall: hall, viewer: viewer, spare: spare} = ctx
      {:ok, view, _html} = live(log_in(conn, viewer, hall), ~p"/halls/#{hall.id}/boxes")

      assert has_element?(view, "#box-#{spare.id}")
      refute has_element?(view, "#box-pair")
      refute has_element?(view, "#box-#{spare.id}-take-over")
      refute has_element?(view, "#box-#{spare.id}-remove")

      render_click(view, "hand_over", %{"box" => to_string(spare.id)})
      render_click(view, "pair_box", %{})
      refute Cloud.lease(hall.id).box_id == spare.id
      refute has_element?(view, "#box-join-code")
    end

    test "an owner removes a box; a box of another hall cannot be named", ctx do
      %{conn: conn, hall: hall, owner: owner, spare: spare} = ctx
      other = hall_fixture("Other hall")
      %{box: elsewhere} = other_box(other, "Elsewhere")

      {:ok, view, _html} = live(log_in(conn, owner, hall), ~p"/halls/#{hall.id}/boxes")

      render_click(view, "hand_over", %{"box" => to_string(elsewhere.id)})
      render_click(view, "remove_box", %{"box" => to_string(elsewhere.id)})
      assert Cloud.get_box(elsewhere.id).revoked_at == nil
      assert Cloud.lease(other.id).box_id == nil

      view |> element("#box-#{spare.id}-remove") |> render_click()
      refute has_element?(view, "#box-#{spare.id}")
    end

    test "not a cloud: no Boxes tab", ctx do
      %{conn: conn, hall: hall, owner: owner} = ctx
      put_env(:takeover_cloud, false)
      {:ok, view, _html} = live(log_in(conn, owner, hall), ~p"/halls/#{hall.id}/boxes")
      refute has_element?(view, "#hall-tab-boxes")
      refute has_element?(view, "#hall-boxes")
    end
  end

  defp other_box_with(code),
    do: {:ok, _} = Cloud.redeem(code, %{"uid" => "used-code-box", "name" => "First"})
end
