defmodule Alnasl.TakeoverHelpers do
  @moduledoc """
  A cloud and a box in one test run (`Alnasl.Takeover`): this Alnasl is the
  cloud for the test, and the box's requests reach it in-process - `Req`'s
  `plug:` option, the real endpoint, router and controller - so a box and
  its cloud share a database and nothing goes near a network.

  The box is the database's own `"takeover"` setting, so a test has one box
  of its own; the other boxes of a hall are cloud rows made by redeeming a
  code (`other_box/2`), which a test drives through `Alnasl.Takeover.Cloud`
  directly - what their requests would do.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query, only: [from: 2]

  alias Alnasl.{Repo, Takeover}
  alias Alnasl.Takeover.{Cloud, Lease, RateLimit}

  @doc "This Alnasl is a cloud for the test, and the box's requests go to it."
  def cloud_on do
    put_env(:takeover_cloud, true)
    put_env(:takeover_req_options, plug: AlnaslWeb.Endpoint)
    put_env(:takeover_server, "http://cloud.test")
    RateLimit.reset()
    Takeover.delete_key()
    on_exit(fn -> Takeover.delete_key() end)
    :ok
  end

  @doc "Pairs this test's box with `hall`, in `role`, through the real pairing link."
  def pair_this_box(hall, role \\ "active") do
    put_env(:takeover_role, role)
    {:ok, join} = Cloud.create_join(hall.id)
    :ok = Takeover.Link.pair("http://cloud.test/takeover/join/" <> join.code)
    Cloud.authenticate(Takeover.key()) |> elem(1)
  end

  @doc "Another box of `hall`, as the cloud knows it: `%{box, key}`."
  def other_box(hall, name) do
    {:ok, join} = Cloud.create_join(hall.id)
    uid = "other" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    {:ok, %{box: box, key: key}} =
      Cloud.redeem(join.code, %{"uid" => uid, "name" => name, "software" => "test"})

    %{box: box, key: key}
  end

  @doc "The hall's lease runs out now: its box has been silent too long."
  def silence(hall_id) do
    Repo.update_all(
      from(l in Lease, where: l.hall_id == ^hall_id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
  end

  def put_env(key, value) do
    before = Application.fetch_env(:alnasl, key)
    Application.put_env(:alnasl, key, value)

    on_exit(fn ->
      case before do
        {:ok, old} -> Application.put_env(:alnasl, key, old)
        :error -> Application.delete_env(:alnasl, key)
      end
    end)
  end
end
