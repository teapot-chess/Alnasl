defmodule AlnaslWeb.Components.ReleaseNotes do
  @moduledoc """
  The release notes on Setup > Updates: every version and what changed,
  newest first. The installed one is marked, the newer ones are marked and
  open, the older ones are folded. The data is `Alnasl.ReleaseNotes`.
  """

  use Phoenix.Component
  use Gettext, backend: AlnaslWeb.Gettext

  alias Alnasl.ReleaseNotes

  @doc """
  The notes as the page keeps them: `Alnasl.ReleaseNotes` entries, each with its rendered `html` and its `state` (`:new`,
  `:installed` or `:older`) against `current`, the installed version.
  """
  def prepare(notes, current) do
    current = Version.parse!(current)

    for note <- notes do
      state =
        case Version.parse(note.version) do
          {:ok, version} ->
            case Version.compare(version, current) do
              :gt -> :new
              :eq -> :installed
              :lt -> :older
            end

          :error ->
            :older
        end

      note |> Map.put(:state, state) |> Map.put(:html, ReleaseNotes.html(note.body))
    end
  end

  attr :notes, :list, required: true
  attr :source, :atom, required: true, doc: "`:bundled`, `:live` or `:offline`"
  attr :releases_page, :string, required: true

  def release_notes(assigns) do
    ~H"""
    <section id="release-notes" class="release-notes stack" aria-labelledby="release-notes-title">
      <h3 id="release-notes-title" class="release-notes-title">{gettext("What changed")}</h3>

      <p :if={@source == :offline} id="release-notes-offline" class="note">
        {gettext(
          "GitHub could not be reached, so these are the notes that came with this version. Anything newer needs the internet; nothing else here does."
        )}
      </p>

      <details
        :for={note <- @notes}
        id={"release-" <> note.version}
        class={["release-note", "release-note-" <> to_string(note.state)]}
        open={note.state != :older}
      >
        <summary>
          <b>{note.version}</b> <span :if={note.date} class="hint">{note.date}</span>
          <span :if={note.state == :installed} class="release-flag installed">
            {gettext("installed")}
          </span>

          <span :if={note.state == :new} class="release-flag new">{gettext("newer than yours")}</span>
        </summary>

        <div class="release-body">{Phoenix.HTML.raw(note.html)}</div>
      </details>

      <p class="note">
        <a id="release-notes-github" href={@releases_page} target="_blank" rel="noopener noreferrer">
          {gettext("View on GitHub")}
        </a>
      </p>
    </section>
    """
  end
end
