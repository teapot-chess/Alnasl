defmodule AlnaslWeb.SystemLive do
  @moduledoc """
  `/system`: is it up, is the off-site copy current, and what has crashed.
  The three questions whoever runs the installation asks before anything
  else, on one page, with a way into LiveDashboard.

  For the installation's admins (`AlnaslWeb.SystemAccess`): the `on_mount`
  below before the page, and `handle_event/3` on every event, so an admin
  taken off the list stops on a page that is already open.

  Everything here is read from this Alnasl's own tables (`Alnasl.Ops`), and
  nothing on it is a secret: the bucket's address, never its keys; how many
  public keys a copy is encrypted to, never which.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.Ops.{ErrorReports, Health, OffsiteBackup}
  alias AlnaslWeb.SystemAccess

  on_mount SystemAccess

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: gettext("System"), sending: false) |> load()}
  end

  defp load(socket) do
    config = OffsiteBackup.config()
    errors = ErrorReports.list()

    socket
    |> assign(
      health: Health.report(),
      offsite_enabled: OffsiteBackup.enabled?(config),
      offsite: offsite_summary(config),
      runs: OffsiteBackup.runs(10),
      errors_empty?: errors == []
    )
    |> stream(:errors, errors, reset: true)
  end

  defp offsite_summary(config) do
    s3 = config[:s3] || []

    %{
      host: s3[:endpoint] && URI.parse(s3[:endpoint]).host,
      bucket: s3[:bucket],
      recipients: length(config[:recipients] || []),
      stale_hours: OffsiteBackup.stale_hours(config)
    }
  end

  # Every event asks the door again, before anything else.
  @impl true
  def handle_event(event, params, socket) do
    if SystemAccess.allowed?(socket.assigns.current_scope) do
      event(event, params, socket)
    else
      {:noreply, socket |> put_flash(:error, SystemAccess.refusal()) |> redirect(to: ~p"/")}
    end
  end

  defp event("refresh", _params, socket), do: {:noreply, load(socket)}

  defp event("send_now", _params, socket) do
    {:noreply,
     socket
     |> assign(sending: true)
     |> start_async(:send, fn -> OffsiteBackup.push() end)}
  end

  defp event("forget", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id), do: ErrorReports.delete(id)
    {:noreply, load(socket)}
  end

  defp event("forget_all", _params, socket) do
    ErrorReports.clear()
    {:noreply, socket |> put_flash(:info, gettext("Error reports forgotten.")) |> load()}
  end

  defp event(_other, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:send, result, socket) do
    {kind, message} =
      case result do
        {:ok, {:ok, _key}} -> {:info, gettext("A copy has been sent off-site.")}
        {:ok, :disabled} -> {:error, gettext("Off-site backups are not configured.")}
        _failed -> {:error, gettext("The off-site backup failed; the newest run says why.")}
      end

    {:noreply, socket |> assign(sending: false) |> put_flash(kind, message) |> load()}
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:system}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      path={@current_path}
      title={gettext("System")}
    >
      <.panel id="system-health" title={gettext("Health")}>
        <:actions>
          <.button id="system-refresh" small type="button" phx-click="refresh">
            {gettext("Check again")}
          </.button>
          <.button id="system-dashboard-link" small icon="external" href={~p"/system/dashboard"}>
            {gettext("LiveDashboard")}
          </.button>
        </:actions>
        <p class="hint">
          {gettext(
            "The same answer /healthz gives a monitor. Only the database decides whether it answers 200 or 503; the backup and the bridges are reported beside it."
          )}
        </p>
        <dl class="support-meta system-facts">
          <dt>{gettext("Status")}</dt>
          <dd><.check id="health-status" value={@health.status} /></dd>
          <dt>{gettext("Database")}</dt>
          <dd><.check id="health-database" value={@health.checks.database} /></dd>
          <dt>{gettext("Off-site backup")}</dt>
          <dd><.check id="health-backup" value={@health.checks.backup} /></dd>
          <dt>{gettext("Bridges")}</dt>
          <dd><.check id="health-bridge" value={@health.checks.bridge} /></dd>
          <dt>{gettext("Version")}</dt>
          <dd id="health-version" class="mono">{@health.version}</dd>
        </dl>
      </.panel>

      <.panel id="system-offsite" title={gettext("Off-site backup")}>
        <:actions :if={@offsite_enabled}>
          <.button
            id="offsite-send-now"
            small
            variant="primary"
            type="button"
            phx-click="send_now"
            disabled={@sending}
          >
            {if @sending, do: gettext("Sending..."), else: gettext("Send a copy now")}
          </.button>
        </:actions>
        <%= if @offsite_enabled do %>
          <p id="offsite-enabled" class="hint">
            {gettext(
              "Once a day a snapshot of the database is compressed, encrypted to %{count} public key(s) and sent to %{bucket} on %{host}. This server cannot decrypt what it sends.",
              count: @offsite.recipients,
              bucket: @offsite.bucket,
              host: @offsite.host
            )}
            {gettext("Stale after %{hours} hours without a successful send.",
              hours: @offsite.stale_hours
            )}
          </p>
        <% else %>
          <p id="offsite-disabled" class="hint">
            {gettext(
              "Not configured: the database is on this machine only. The OFFSITE_BACKUP_* settings in the README switch it on."
            )}
          </p>
        <% end %>

        <div :if={@runs != []} class="table-wrap">
          <table id="offsite-runs">
            <thead>
              <tr>
                <th>{gettext("When")}</th>
                <th>{gettext("Result")}</th>
                <th>{gettext("Object")}</th>
                <th>{gettext("Size")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={run <- @runs} id={"offsite-run-#{run.id}"}>
                <td>{format_time(run.finished_at)}</td>
                <td>
                  <.check value={if run.status == "ok", do: "ok", else: "failing"} />
                  <span :if={run.error} class="hint">{run.error}</span>
                </td>
                <td class="mono">{run.object_key}</td>
                <td>{run.bytes && format_size(run.bytes)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.panel>

      <.panel id="system-errors" title={gettext("Errors")}>
        <:actions :if={!@errors_empty?}>
          <.button
            id="errors-forget-all"
            small
            type="button"
            phx-click="forget_all"
            data-confirm={gettext("Forget every error report?")}
          >
            {gettext("Forget all")}
          </.button>
        </:actions>
        <p class="hint">
          {gettext(
            "Crashes logged here, one row per kind, newest first. Kept on this machine, sent nowhere. Messages are cut short and stack traces carry no arguments, so no names, games or keys end up on this page."
          )}
        </p>

        <p :if={@errors_empty?} id="errors-empty" class="hint">{gettext("Nothing has crashed.")}</p>

        <div id="system-error-list" phx-update="stream">
          <div :for={{id, error} <- @streams.errors} id={id} class="system-error">
            <div class="system-error-head">
              <strong class="mono">{error.kind}</strong>
              <.badge>{ngettext("once", "%{count} times", error.count)}</.badge>
              <.button
                id={"error-forget-#{error.id}"}
                small
                variant="ghost"
                type="button"
                phx-click="forget"
                phx-value-id={error.id}
              >
                {gettext("Forget")}
              </.button>
            </div>
            <p class="system-error-message">{error.message}</p>
            <p class="hint">
              <span class="mono">{error.location}</span>
              &middot; {gettext("first %{first}, last %{last}",
                first: format_time(error.first_seen_at),
                last: format_time(error.last_seen_at)
              )}
            </p>
            <details :if={error.stacktrace != ""}>
              <summary>{gettext("Stack trace")}</summary>
              <pre class="mono support-text">{error.stacktrace}</pre>
            </details>
          </div>
        </div>
      </.panel>
    </Layouts.app>
    """
  end

  attr :value, :string, required: true
  attr :id, :string, default: nil

  defp check(assigns) do
    ~H"""
    <.badge id={@id} tone={check_tone(@value)} icon={check_icon(@value)}>
      {check_word(@value)}
    </.badge>
    """
  end

  defp check_tone("ok"), do: "ok"
  defp check_tone("disabled"), do: nil
  defp check_tone("stale"), do: "warn"
  defp check_tone(_bad), do: "bad"

  defp check_icon("ok"), do: "ok"
  defp check_icon("disabled"), do: nil
  defp check_icon("stale"), do: "warning"
  defp check_icon(_bad), do: "error"

  defp check_word("ok"), do: gettext("OK")
  defp check_word("degraded"), do: gettext("Degraded")
  defp check_word("unreachable"), do: gettext("Unreachable")
  defp check_word("stale"), do: gettext("Stale")
  defp check_word("failing"), do: gettext("Failing")
  defp check_word("disabled"), do: gettext("Not configured")
  defp check_word(other), do: other

  defp format_time(nil), do: ""
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp format_size(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp format_size(bytes), do: "#{max(div(bytes, 1_000), 1)} kB"
end
