defmodule AlnaslWeb.ReleaseNotesTest do
  @moduledoc """
  What changed, on Setup > Updates, inside the program: the notes this build
  carries are there without asking anybody; GitHub's list replaces them when
  it answers; and when it does not, the page says so calmly and keeps what it
  has. The body is Markdown from outside and is rendered as such.
  """

  use AlnaslWeb.SiteCase

  alias Alnasl.{FakeReleases, ReleaseNotes, Updates}

  setup do
    start_supervised!(FakeReleases)
    FakeReleases.install()
    ReleaseNotes.forget()

    on_exit(fn ->
      FakeReleases.uninstall()
      ReleaseNotes.forget()
      Application.put_env(:alnasl, :release_notes_on_open, false)
    end)

    :ok
  end

  defp ask_github, do: Application.put_env(:alnasl, :release_notes_on_open, true)

  defp version_plus(minor_step) do
    version = Version.parse!(Updates.current_version())
    "#{version.major}.#{version.minor + minor_step}.0"
  end

  defp list_requests, do: length(FakeReleases.requests())

  describe "without asking" do
    test "the notes in this build are on the page, and nobody was asked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/updates")

      assert has_element?(view, "#release-notes")
      assert has_element?(view, "[id=\"release-#{Updates.current_version()}\"][open]")

      assert has_element?(
               view,
               "[id=\"release-#{Updates.current_version()}\"] .release-flag.installed"
             )

      refute has_element?(view, "#release-notes-offline")
      assert has_element?(view, "#release-notes-github")
      assert FakeReleases.requests() == []
    end
  end

  describe "from GitHub" do
    test "newest first; newer ones open and marked, the installed one marked, older ones folded",
         %{conn: conn} do
      ask_github()
      current = Updates.current_version()
      newer = version_plus(1)

      FakeReleases.publish_list([
        {"0.0.1", "The beginning."},
        {current, "Yours."},
        {newer, "- [Feature] **Shiny.**"}
      ])

      {:ok, view, _html} = live(conn, ~p"/setup/updates")
      render_async(view)

      assert has_element?(view, "[id=\"release-#{newer}\"][open] .release-flag.new")
      assert has_element?(view, "[id=\"release-#{newer}\"] .release-body strong", "Shiny.")
      assert has_element?(view, "[id=\"release-#{current}\"][open] .release-flag.installed")
      assert has_element?(view, "[id=\"release-0.0.1\"]")
      refute has_element?(view, "[id=\"release-0.0.1\"][open]")
      refute has_element?(view, "#release-notes-offline")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("details.release-note")
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> List.first()))

      assert ids == ["release-#{newer}", "release-#{current}", "release-0.0.1"]
    end

    test "the answer is kept: opening the page again does not ask again", %{conn: conn} do
      ask_github()
      FakeReleases.publish_list([{Updates.current_version(), "Yours."}])

      {:ok, first, _html} = live(conn, ~p"/setup/updates")
      render_async(first)
      {:ok, second, _html} = live(conn, ~p"/setup/updates")
      render_async(second)

      assert list_requests() == 1

      assert has_element?(
               second,
               "[id=\"release-#{Updates.current_version()}\"] .release-body",
               "Yours."
             )
    end

    test "a note is rendered as Markdown and cannot bring a script or a javascript: link",
         %{conn: conn} do
      ask_github()

      FakeReleases.publish_list([
        {Updates.current_version(),
         """
         <script>alert(1)</script>
         <img src=x onerror=alert(2)>

         [good](https://example.org/a) and [bad](javascript:alert(3))
         """}
      ])

      {:ok, view, _html} = live(conn, ~p"/setup/updates")
      html = render_async(view)

      body =
        view |> element("[id=\"release-#{Updates.current_version()}\"] .release-body") |> render()

      refute body =~ "<script"
      refute body =~ "<img"
      refute body =~ "onerror="
      refute body =~ "javascript:"
      assert body =~ ~s(href="https://example.org/a")
      assert body =~ ~s(rel="noopener noreferrer")
      assert html =~ "release-notes"
    end
  end

  describe "when GitHub does not answer" do
    for mode <- [:down, :rate_limited, :garbage] do
      test "#{mode}: a calm message, and the notes of this build stay", %{conn: conn} do
        ask_github()
        FakeReleases.mode(unquote(mode))

        {:ok, view, _html} = live(conn, ~p"/setup/updates")
        render_async(view)

        assert has_element?(view, "#release-notes-offline")
        assert has_element?(view, "[id=\"release-#{Updates.current_version()}\"][open]")
      end
    end
  end

  describe "the CHANGELOG carried in the build" do
    test "is cut into versions, newest first, without [Unreleased]" do
      notes = ReleaseNotes.bundled()

      assert [%{version: version} | _] = notes
      assert {:ok, _} = Version.parse(version)
      refute Enum.any?(notes, &(&1.version == "Unreleased"))
      assert Enum.all?(notes, &(&1.body != ""))
    end

    test "the cutting itself" do
      text = """
      # Changelog

      ## [Unreleased]

      - not yet

      ## [1.2.0] - 2026-01-02

      - [Feature] **Two.**

      ## [1.1.0] - 2026-01-01

      - [Fix] One.
      """

      assert [
               %{version: "1.2.0", date: "2026-01-02", body: "- [Feature] **Two.**"},
               %{version: "1.1.0", date: "2026-01-01", body: "- [Fix] One."}
             ] = ReleaseNotes.Changelog.parse(text)
    end
  end
end
