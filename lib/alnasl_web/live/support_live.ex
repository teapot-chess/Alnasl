defmodule AlnaslWeb.SupportLive do
  @moduledoc """
  `/support`: the diagnostics boxes sent (`Alnasl.Support`). Type the code
  somebody read out, or pick one of the newest; read it, or download it.

  For the addresses in `ALNASL_SUPPORT_ADMINS` and nobody else
  (`AlnaslWeb.SupportAccess`): the router's plug before the page, the
  `on_mount` of its live_session, and `handle_event/3` below on every
  event, so that a name taken off the list stops working on a page that is
  already open. Everybody else gets a 404.

  What a box sent is a stranger's text: it is shown in a `<pre>`, escaped
  like every other value in a template, and never as markup.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.Support
  alias AlnaslWeb.SupportAccess

  @impl true
  def mount(_params, _session, socket) do
    Support.purge_expired()
    recent = Support.list_recent()

    {:ok,
     socket
     |> assign(
       page_title: gettext("Support"),
       upload: nil,
       not_found: nil,
       recent_empty?: recent == [],
       form: to_form(%{"code" => ""}, as: :lookup)
     )
     |> stream(:recent, recent)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["code"] do
      code when is_binary(code) and code != "" -> {:noreply, show(socket, code)}
      _none -> {:noreply, assign(socket, upload: nil, not_found: nil)}
    end
  end

  defp show(socket, code) do
    case Support.get_live(code) do
      nil ->
        assign(socket,
          upload: nil,
          not_found: String.slice(code, 0, 12),
          form: to_form(%{"code" => code}, as: :lookup)
        )

      upload ->
        assign(socket,
          upload: upload,
          not_found: nil,
          form: to_form(%{"code" => upload.code}, as: :lookup)
        )
    end
  end

  # Every event asks the door again, before anything else.
  @impl true
  def handle_event(event, params, socket) do
    if SupportAccess.allowed?(socket.assigns.current_scope),
      do: event(event, params, socket),
      else: {:noreply, redirect(socket, to: ~p"/support")}
  end

  defp event("lookup", %{"lookup" => %{"code" => code}}, socket) do
    {:noreply, push_patch(socket, to: ~p"/support?#{[code: String.trim(code)]}")}
  end

  defp event("refresh", _params, socket) do
    Support.purge_expired()
    recent = Support.list_recent()

    {:noreply,
     socket
     |> assign(recent_empty?: recent == [])
     |> stream(:recent, recent, reset: true)}
  end

  defp event(_other, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  defp when_text(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp size_text(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size_text(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:support}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      path={@current_path}
      title={gettext("Support")}
    >
      <.panel id="support-lookup" title={gettext("Find an upload")}>
        <.form for={@form} id="support-lookup-form" phx-submit="lookup" class="row">
          <.input
            field={@form[:code]}
            label={gettext("Code")}
            inputmode="numeric"
            maxlength="6"
            autocomplete="off"
            placeholder="123456"
          />
          <.button id="support-lookup-submit" variant="primary" type="submit">
            {gettext("Open")}
          </.button>
        </.form>
        <p :if={@not_found} id="support-not-found" class="hint">
          {gettext("No upload with code %{code}, or it has expired.", code: @not_found)}
        </p>
      </.panel>

      <.panel :if={@upload} id="support-upload" title={gettext("Upload %{code}", code: @upload.code)}>
        <:actions>
          <.button
            id="support-download"
            small
            icon="external"
            href={~p"/support/download/#{@upload.code}"}
          >
            {gettext("Download")}
          </.button>
        </:actions>
        <dl id="support-meta" class="support-meta">
          <dt>{gettext("Received")}</dt>
          <dd>{when_text(@upload.inserted_at)}</dd>
          <dt>{gettext("Expires")}</dt>
          <dd>{when_text(@upload.expires_at)}</dd>
          <dt>{gettext("Size")}</dt>
          <dd>{size_text(@upload.size)}</dd>
          <dt>{gettext("Box")}</dt>
          <dd>{@upload.box_id || "-"}</dd>
          <dt>{gettext("Version")}</dt>
          <dd>{@upload.version || "-"}</dd>
          <dt>{gettext("Mode")}</dt>
          <dd>{@upload.mode || "-"}</dd>
          <dt>{gettext("File")}</dt>
          <dd>{@upload.filename || "-"}</dd>
        </dl>
        <pre id="support-content" class="mono support-text">{@upload.content}</pre>
      </.panel>

      <.panel id="support-recent" title={gettext("Newest uploads")} flush>
        <:actions>
          <.button id="support-refresh" small type="button" phx-click="refresh">
            {gettext("Refresh")}
          </.button>
        </:actions>
        <p :if={@recent_empty?} id="support-recent-empty" class="hint">
          {gettext("Nothing has been sent in the last %{days} days.", days: Support.keep_days())}
        </p>
        <div class="table-wrap">
          <table id="support-recent-table">
            <thead>
              <tr>
                <th>{gettext("Code")}</th>
                <th>{gettext("Received")}</th>
                <th>{gettext("Box")}</th>
                <th>{gettext("Version")}</th>
                <th>{gettext("Size")}</th>
              </tr>
            </thead>
            <tbody id="support-recent-rows" phx-update="stream">
              <tr :for={{id, upload} <- @streams.recent} id={id}>
                <td>
                  <.link patch={~p"/support?#{[code: upload.code]}"} class="mono">
                    {upload.code}
                  </.link>
                </td>
                <td>{when_text(upload.inserted_at)}</td>
                <td>{upload.box_id || "-"}</td>
                <td>{upload.version || "-"}</td>
                <td>{size_text(upload.size)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.panel>
    </Layouts.app>
    """
  end
end
