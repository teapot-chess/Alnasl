defmodule Mix.Tasks.Contracts.Sync do
  @shortdoc "Copies the providers' contracts into priv/contracts/vendor, or checks that they match"

  @moduledoc """
  The one command for vendored contracts: it copies each provider's contract
  into `priv/contracts/vendor/<repo, lowercase>/<name>/`, byte for byte, and
  says which files it added, changed or removed.

      mix contracts.sync                    # from each provider's main on GitHub
      mix contracts.sync --check            # the same comparison, writes nothing,
                                            # exits non-zero on any difference (CI)
      mix contracts.sync --local            # from the sibling checkouts, ../<repo>
      mix contracts.sync --path openpairings=../openpairings-wt-x
                                            # from that checkout (implies --local
                                            # for that provider only)

  `--check` combines with any source. `--local` and `--path` read the
  provider's working tree, uncommitted edits included, which is what makes it
  possible to bring a consumer up to a provider change before that change is
  merged; CI always reads GitHub.

  What is vendored is `priv/contracts/vendor/contracts.json`, and nowhere
  else: `[{"repo": "openpairings", "name": "publish-v1"}]`, `[]` while
  nothing is. An optional `"from"` names the repository the bytes come from
  when it is not `"repo"` (a private twin); the vendored directory and the
  schemas' `$id` keep the `repo` name either way.

  For each entry the provider's `priv/contracts/<name>/index.json` is read
  first, then every file it lists; the vendored directory becomes exactly
  that, so a file the index no longer lists is deleted. A listed name that
  is not a plain `.json` file name (or one under `examples/`) is refused
  before anything is written: a broken index does not get to climb out of
  the vendored directory.

  GitHub is read with Req. The token in `CONTRACTS_TOKEN`, when set, goes
  with every request: private repositories answer 404 to anyone without
  one, and an entry with `"from"` refuses to start without it rather than
  let that 404 do the explaining. The token is never printed.

  Nothing here runs in `mix test`. A sync that turns the tests red is the
  point, not an accident: the provider moved, and this is where it shows.
  """
  use Mix.Task

  @base "https://raw.githubusercontent.com/teapot-chess"
  @file_name ~r/\A(?:examples\/)?[A-Za-z0-9][A-Za-z0-9_.-]*\.json\z/
  @switches [check: :boolean, local: :boolean, path: :keep]
  @usage "mix contracts.sync [--check] [--local] [--path REPO=DIR]..."

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [], do: Mix.raise("Usage: " <> @usage)

    check? = Keyword.get(opts, :check, false)
    paths = paths!(Keyword.get_values(opts, :path))
    local? = Keyword.get(opts, :local, false)

    results =
      for contract <- contracts() do
        source = source(contract, local?, paths)
        files = fetch!(contract, source)
        dir = dir(contract)
        changes = diff(dir, files)

        unless check?, do: write!(dir, files, changes)

        report(contract, source, files, changes, check?)
        {contract, changes}
      end

    drift? = Enum.any?(results, fn {_contract, changes} -> changes != [] end)

    cond do
      results == [] ->
        Mix.shell().info("Nothing is vendored (priv/contracts/vendor/contracts.json is []).")

      check? and drift? ->
        Mix.raise(
          "Vendored contracts differ from their providers. " <>
            "Run `mix contracts.sync`, then the tests, and see what broke."
        )

      check? ->
        Mix.shell().info("Every vendored contract matches its provider.")

      true ->
        :ok
    end

    results
  end

  @doc false
  def vendor_root, do: Path.expand("priv/contracts/vendor", File.cwd!())

  @doc false
  # `[%{"repo" => ..., "name" => ...}]`, from the one list.
  def contracts do
    vendor_root() |> Path.join("contracts.json") |> File.read!() |> Jason.decode!()
  end

  @doc false
  def dir(%{"repo" => repo, "name" => name}),
    do: Path.join([vendor_root(), String.downcase(repo), name])

  @doc false
  def label(%{"repo" => repo, "name" => name}), do: "#{repo}/#{name}"

  @doc false
  # Every file under `dir`, `index.json` included, relative and sorted.
  def local_files(dir) do
    # Expanded first: a Windows path with backslashes in it (System.tmp_dir!/0
    # hands out exactly that) matches nothing at all in Path.wildcard/1.
    dir = Path.expand(dir)

    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  @doc false
  # `[{:added | :changed | :removed, file}]`, sorted by file: what writing
  # `files` (`%{relative path => bytes}`, the index included) over `dir`
  # would do. `[]` is "already identical".
  def diff(dir, files) do
    local = local_files(dir)
    names = Enum.sort(Enum.uniq(local ++ Map.keys(files)))

    for name <- names,
        change = change(name in local, Map.fetch(files, name), Path.join(dir, name)),
        change != nil,
        do: {change, name}
  end

  defp change(false, {:ok, _bytes}, _path), do: :added
  defp change(true, :error, _path), do: :removed

  defp change(true, {:ok, bytes}, path) do
    if File.read!(path) == bytes, do: nil, else: :changed
  end

  @doc false
  def write!(dir, files, changes) do
    File.mkdir_p!(dir)

    for {change, name} <- changes do
      path = Path.join(dir, name)

      case change do
        :removed ->
          File.rm!(path)

        _added_or_changed ->
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, Map.fetch!(files, name))
      end
    end

    :ok
  end

  @doc false
  # `{:github, repository}` or `{:local, checkout directory}`.
  def source(contract, local?, paths) do
    repo = contract["from"] || contract["repo"]

    case Map.fetch(paths, String.downcase(repo)) do
      {:ok, dir} -> {:local, dir}
      :error when local? -> {:local, sibling!(repo)}
      :error -> {:github, repo}
    end
  end

  # `../<repo>` next to this checkout, as named or in lower case.
  defp sibling!(repo) do
    candidates = Enum.uniq([repo, String.downcase(repo)])
    parent = Path.expand("..", File.cwd!())

    Enum.find_value(candidates, fn name ->
      dir = Path.join(parent, name)
      if File.dir?(Path.join(dir, "priv/contracts")), do: dir
    end) ||
      Mix.raise(
        "No checkout of #{repo} next to this one (#{Path.join(parent, repo)}). " <>
          "Pass --path #{String.downcase(repo)}=DIR."
      )
  end

  defp paths!(values) do
    Map.new(values, fn value ->
      case String.split(value, "=", parts: 2) do
        [repo, dir] when repo != "" and dir != "" ->
          dir = Path.expand(dir)

          unless File.dir?(Path.join(dir, "priv/contracts")),
            do: Mix.raise("--path #{value}: #{dir} has no priv/contracts")

          {String.downcase(repo), dir}

        _ ->
          Mix.raise("--path wants REPO=DIR, not #{inspect(value)}. Usage: " <> @usage)
      end
    end)
  end

  @doc false
  # `%{relative path => bytes}` for the provider's contract as `source` has
  # it: `index.json` and every file it lists.
  def fetch!(contract, source) do
    read = reader(contract, source)
    index = read.("index.json")

    listed =
      case Jason.decode(index) do
        {:ok, %{"files" => files}} when is_list(files) -> files
        _ -> Mix.raise("#{label(contract)}: index.json has no file list")
      end

    for file <- listed, not (is_binary(file) and file =~ @file_name) do
      Mix.raise("#{label(contract)}: index.json lists #{inspect(file)}, which is not a file name")
    end

    listed
    |> Map.new(&{&1, read.(&1)})
    |> Map.put("index.json", index)
  end

  defp reader(contract, {:local, checkout}) do
    base = Path.join([checkout, "priv", "contracts", contract["name"]])

    fn file ->
      path = Path.join(base, file)

      case File.read(path) do
        {:ok, bytes} -> bytes
        {:error, reason} -> Mix.raise("#{path}: #{:file.format_error(reason)}")
      end
    end
  end

  defp reader(contract, {:github, repo}) do
    {:ok, _apps} = Application.ensure_all_started(:req)
    base = "#{@base}/#{repo}/main/priv/contracts/#{contract["name"]}/"
    headers = headers(contract)
    &get!(base <> &1, headers)
  end

  defp headers(contract) do
    case System.get_env("CONTRACTS_TOKEN") do
      token when is_binary(token) and token != "" ->
        [authorization: "token " <> token]

      _ ->
        if from = contract["from"],
          do: Mix.raise("#{from} is private: set CONTRACTS_TOKEN to a token that can read it")

        []
    end
  end

  # Bytes, undecoded: the copy has to be identical, not equivalent.
  defp get!(url, headers) do
    case Req.get(url,
           headers: headers,
           decode_body: false,
           retry: :transient,
           max_retries: 3,
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} -> body
      {:ok, %Req.Response{status: status}} -> Mix.raise("#{url} answered #{status}")
      {:error, error} -> Mix.raise("#{url}: #{Exception.message(error)}")
    end
  end

  defp report(contract, source, files, [], _check?) do
    Mix.shell().info(
      "#{label(contract)} (#{where(source)}): up to date, #{map_size(files)} files"
    )
  end

  defp report(contract, source, _files, changes, check?) do
    shell = Mix.shell()
    say = if check?, do: &shell.error/1, else: &shell.info/1
    verb = if check?, do: "differs from", else: "synced from"
    say.("#{label(contract)} #{verb} #{where(source)}:")

    for {change, name} <- changes do
      word =
        case {change, check?} do
          {:added, true} -> "added by the provider"
          {:removed, true} -> "removed by the provider"
          {:changed, true} -> "changed by the provider"
          {change, false} -> Atom.to_string(change)
        end

      say.("  #{word}: #{name}")
    end
  end

  defp where({:github, repo}), do: "teapot-chess/#{repo}@main"
  defp where({:local, dir}), do: dir
end
