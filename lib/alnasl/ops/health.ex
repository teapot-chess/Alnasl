defmodule Alnasl.Ops.Health do
  @moduledoc """
  What `/healthz` says, and what the System page repeats.

  Deliberately poor in information, because the endpoint is public: a
  status, the version (a release number; the releases are public on
  GitHub, and the deploy wants to see the new one come up), and a word per
  check. No counts, no hall or bridge names, no hostnames, no paths, no
  error text - a stranger learns that it is up and which release it runs,
  and nothing else. The same answer on a box in a hall as on the server.

  ## What decides the HTTP status

  Only the database. A monitor, or the deploy script's "did it come back"
  check, wants to know whether this process can serve a page, and without
  the database it cannot. The other two are reported beside it and never
  flip it: a bucket that is unreachable for an afternoon, or a Saturday
  with no hall playing, is not a reason for anything automated to declare
  the app dead and restart it - which would fix nothing and cut every
  bridge in the middle of a round.

  ## The checks

    * `database` - `"ok"` when `SELECT 1` answers within two seconds,
      `"unreachable"` otherwise.
    * `backup` - `Alnasl.Ops.OffsiteBackup.status/0`: `"ok"`, `"stale"`,
      `"failing"` or `"disabled"`.
    * `bridge` - whether this Alnasl can take bridges in at all: the
      registries the bridge links and their boards register in, and the
      supervisor the boards run under, are all running (`"ok"`), or one of
      them is not (`"degraded"`). Not whether any bridge is connected: an
      empty hall is a quiet evening, not a fault, and how many halls are
      playing right now is nobody's business but theirs.
  """

  alias Alnasl.Ops.OffsiteBackup
  alias Alnasl.Repo

  # What a bridge needs on this side (`AlnaslWeb.BridgeSocket`,
  # `Alnasl.Driver.Remote`, `Alnasl.Boards`).
  @bridge_processes [Alnasl.BridgeRegistry, Alnasl.RemoteRegistry, Alnasl.BoardSupervisor]

  @doc "The report: `%{status: \"ok\" | \"degraded\", version: ..., checks: %{...}}`."
  def report do
    database = database()

    %{
      status: if(database == "ok", do: "ok", else: "degraded"),
      version: version(),
      checks: %{database: database, backup: Atom.to_string(backup()), bridge: bridge()}
    }
  end

  defp database do
    case Repo.query("SELECT 1", [], timeout: 2_000, log: false) do
      {:ok, _} -> "ok"
      _ -> "unreachable"
    end
  rescue
    _ -> "unreachable"
  catch
    :exit, _ -> "unreachable"
  end

  defp backup do
    OffsiteBackup.status()
  catch
    :exit, _ -> :failing
  end

  @doc false
  def bridge(processes \\ @bridge_processes) do
    if Enum.all?(processes, &running?/1), do: "ok", else: "degraded"
  end

  defp running?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end

  defp version, do: :alnasl |> Application.spec(:vsn) |> to_string()
end
