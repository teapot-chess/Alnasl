defmodule Alnasl.ReleaseNotes do
  @moduledoc """
  What changed in each version, for the Updates page: shown inside Alnasl,
  because a touch-only screen in a hall has no business being sent to GitHub
  to read it.

  Two sources, one shape (`%{version, date, body}`, newest first):

    * GitHub's release list - the live one, and the only one that knows of
      versions newer than this program. Asked for when the page is opened,
      at most once in six hours (ten minutes after a failure), because the
      unauthenticated limit is sixty requests an hour for the whole hall.
    * `CHANGELOG.md`, read at compile time and carried inside the program.
      Release notes are that file's sections word for word (see
      docs/releasing.md), so offline the page loses only what is newer than
      this build.

  The body is Markdown from outside, and is rendered with `Alnasl.Markdown`
  (escaped text, a closed tag set, no `javascript:` links). Every link also
  gets `rel="noopener noreferrer"` here.
  """

  require Logger

  alias Alnasl.Markdown

  @repo "teapot-chess/Alnasl"
  @url "https://api.github.com/repos/#{@repo}/releases?per_page=30"
  @user_agent "Alnasl-UpdateCheck"
  @ok_ttl_s 6 * 3600
  @error_ttl_s 10 * 60
  @key {__MODULE__, :cache}

  @changelog Path.expand("../../CHANGELOG.md", __DIR__)
  @external_resource @changelog

  @bundled Alnasl.ReleaseNotes.Changelog.parse(File.read!(@changelog))

  @doc "The notes carried inside this build, newest first."
  def bundled, do: @bundled

  @doc """
  `{:ok, notes, :live}` from GitHub (or its cache), or `{:ok, notes,
  :bundled}` when GitHub gave nothing usable.
  """
  def get do
    now = System.os_time(:second)

    case :persistent_term.get(@key, nil) do
      {until, result} when until > now ->
        result

      _stale ->
        result = fetch()
        ttl = if match?({:ok, _, :live}, result), do: @ok_ttl_s, else: @error_ttl_s
        :persistent_term.put(@key, {now + ttl, result})
        result
    end
  end

  @doc "Forgets the cache (tests)."
  def forget do
    :persistent_term.erase(@key)
    :ok
  end

  defp fetch do
    request =
      [
        url: @url,
        headers: [{"accept", "application/vnd.github+json"}, {"user-agent", @user_agent}],
        receive_timeout: 10_000,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:alnasl, :updates_req_options, []))
      |> Req.new()

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: releases}} when is_list(releases) ->
        case read(releases) do
          [] -> fallback()
          notes -> {:ok, notes, :live}
        end

      {:ok, %Req.Response{status: status}} ->
        Logger.debug("Release notes: GitHub answered #{status}")
        fallback()

      {:error, reason} ->
        Logger.debug("Release notes: #{inspect(reason)}")
        fallback()
    end
  end

  defp fallback, do: {:ok, @bundled, :bundled}

  defp read(releases) do
    releases
    |> Enum.filter(&(is_map(&1) and &1["draft"] != true and &1["prerelease"] != true))
    |> Enum.flat_map(fn release ->
      with tag when is_binary(tag) <- release["tag_name"],
           {:ok, version} <- Version.parse(String.trim_leading(tag, "v")) do
        [
          %{
            version: to_string(version),
            date: release["published_at"] |> to_string() |> String.slice(0, 10),
            body: to_string(release["body"])
          }
        ]
      else
        _unreadable -> []
      end
    end)
    |> sort()
  end

  defp sort(notes) do
    Enum.sort(notes, fn a, b ->
      case {Version.parse(a.version), Version.parse(b.version)} do
        {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) != :lt
        _other -> a.version >= b.version
      end
    end)
  end

  @doc "A note's Markdown as safe HTML (a string, to go through `Phoenix.HTML.raw/1`)."
  def html(markdown) when is_binary(markdown) do
    markdown
    |> Markdown.parse()
    |> Enum.map(&rel/1)
    |> Markdown.render_ast()
  end

  defp rel({"a", attrs, children, meta}) do
    attrs = Enum.reject(attrs, fn {name, _value} -> name == "rel" end)
    {"a", [{"rel", "noopener noreferrer"} | attrs], Enum.map(children, &rel/1), meta}
  end

  defp rel({tag, attrs, children, meta}), do: {tag, attrs, Enum.map(children, &rel/1), meta}
  defp rel(text), do: text
end
