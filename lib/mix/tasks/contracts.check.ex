defmodule Mix.Tasks.Contracts.Check do
  @shortdoc "mix contracts.sync --check, under its old name"

  @moduledoc """
  `mix contracts.sync --check`: fetches every vendored contract from its
  provider, writes nothing, and fails naming the files that differ. Kept
  under this name because the habit outlived the reason; the options are
  `mix contracts.sync`'s.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args), do: Mix.Tasks.Contracts.Sync.run(["--check" | args])
end
