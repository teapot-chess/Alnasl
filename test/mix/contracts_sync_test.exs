defmodule Mix.Tasks.Contracts.SyncTest do
  # The copying and the comparing, against two directories on disk: a
  # provider checkout (what `--local`/`--path` read) and a vendored copy.
  # Nothing here touches the network or this repository's own vendor tree.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Contracts.Sync

  @contract %{"repo" => "provider", "name" => "thing-v1"}

  setup do
    root = Path.join(System.tmp_dir!(), "contracts-sync-#{System.unique_integer([:positive])}")
    provider = Path.join(root, "provider")
    vendored = Path.join(root, "vendored")
    on_exit(fn -> File.rm_rf!(root) end)

    put(provider, "index.json", ~s({"files": ["a.schema.json", "examples/a.json"]}))
    put(provider, "a.schema.json", ~s({"type": "object"}))
    put(provider, "examples/a.json", ~s({}))

    %{provider: provider, vendored: vendored}
  end

  defp put(checkout, file, bytes) do
    path = Path.join([checkout, "priv", "contracts", "thing-v1", file])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  test "an empty copy gets every file, the index included", %{provider: p, vendored: v} do
    files = Sync.fetch!(@contract, {:local, p})

    assert Sync.diff(v, files) == [
             {:added, "a.schema.json"},
             {:added, "examples/a.json"},
             {:added, "index.json"}
           ]

    :ok = Sync.write!(v, files, Sync.diff(v, files))
    assert Sync.diff(v, files) == []
    assert File.read!(Path.join(v, "examples/a.json")) == "{}"
  end

  test "a changed file and a file the index dropped are both reported", %{
    provider: p,
    vendored: v
  } do
    files = Sync.fetch!(@contract, {:local, p})
    Sync.write!(v, files, Sync.diff(v, files))

    put(p, "index.json", ~s({"files": ["a.schema.json"]}))
    put(p, "a.schema.json", ~s({"type": "array"}))
    files = Sync.fetch!(@contract, {:local, p})

    changes = Sync.diff(v, files)

    assert changes == [
             {:changed, "a.schema.json"},
             {:removed, "examples/a.json"},
             {:changed, "index.json"}
           ]

    Sync.write!(v, files, changes)
    refute File.exists?(Path.join(v, "examples/a.json"))
    assert Sync.local_files(v) == ["a.schema.json", "index.json"]
  end

  test "bytes count, not JSON equivalence", %{provider: p, vendored: v} do
    files = Sync.fetch!(@contract, {:local, p})
    Sync.write!(v, files, Sync.diff(v, files))

    put(p, "a.schema.json", ~s({"type":  "object"}))
    assert Sync.diff(v, Sync.fetch!(@contract, {:local, p})) == [{:changed, "a.schema.json"}]
  end

  test "an index naming something that is not a file name is refused", %{provider: p} do
    put(p, "index.json", ~s({"files": ["../../escape.json"]}))

    assert_raise Mix.Error, ~r/not a file name/, fn ->
      Sync.fetch!(@contract, {:local, p})
    end
  end

  test "--path picks the checkout for that provider, GitHub for the rest", %{provider: p} do
    paths = %{"provider" => p}

    assert Sync.source(@contract, false, paths) == {:local, p}
    assert Sync.source(%{"repo" => "other", "name" => "x-v1"}, false, paths) == {:github, "other"}

    # A private twin is looked up by the repository the bytes come from.
    twin = %{"repo" => "public", "from" => "Provider", "name" => "thing-v1"}
    assert Sync.source(twin, false, paths) == {:local, p}
  end
end
