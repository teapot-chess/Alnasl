defmodule AlnaslWeb.SpareLive do
  @moduledoc """
  `/spare` on a box: its pairing with a hall in the cloud, and its part in
  that hall (`Alnasl.Takeover`).

  * Not paired: what it is for, and the field for the pairing link or code
    the cloud showed (the box's admin).
  * Active: it streams to the cloud; how much waits; "Make this box a
    spare".
  * Spare: it stands by; "Take over" (an arbiter), and whether it takes
    over by itself when the active box goes silent (the admin).
  * Superseded: another box runs the hall. This box reads no boards and
    sends nothing, and the page offers nothing that would fight the other
    box: only to stand by as a spare.

  On the cloud itself there is nothing to pair: the page says where the
  boxes are (each hall's Boxes tab).

  The buttons run in the background (`start_async/3`): taking over copies
  the hall, which can take a while on a long day.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.Takeover
  alias Alnasl.Takeover.Link
  alias AlnaslWeb.TakeoverWords

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Cloud and spare"), busy: nil, message: nil)
     |> assign(pair_form: to_form(%{"link" => ""}, as: :pair))
     |> load()}
  end

  defp load(socket),
    do: assign(socket, status: Takeover.status(), line: TakeoverWords.line(), box?: box?())

  defp box?, do: Alnasl.edition() == :box

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # --- the buttons -------------------------------------------------------------------

  @impl true
  def handle_event("pair", %{"pair" => %{"link" => link}}, socket) do
    link = String.slice(link, 0, 300)
    {:noreply, run(socket, :pair, fn -> Link.pair(link) end)}
  end

  def handle_event("take_over", _params, socket),
    do: {:noreply, run(socket, :take_over, &Link.take_over/0)}

  def handle_event("stand_by", _params, socket),
    do: {:noreply, run(socket, :stand_by, &Link.stand_by/0)}

  def handle_event("leave", _params, socket),
    do: {:noreply, run(socket, :leave, &Link.leave/0)}

  def handle_event("step", _params, socket),
    do: {:noreply, run(socket, :step, &Link.step_now/0)}

  def handle_event("auto", params, socket) do
    Link.set_auto(params["value"] == "on" or params["auto"] == "true")
    {:noreply, load(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp run(%{assigns: %{busy: busy}} = socket, _what, _fun) when busy != nil, do: socket

  defp run(socket, what, fun) do
    socket
    |> assign(busy: what, message: nil)
    |> start_async(what, fun)
  end

  @impl true
  def handle_async(what, {:ok, :ok}, socket) do
    {:noreply, socket |> assign(busy: nil, message: done(what)) |> load()}
  end

  def handle_async(_what, {:ok, {:error, why}}, socket) do
    {:noreply, socket |> assign(busy: nil, message: TakeoverWords.error(why)) |> load()}
  end

  def handle_async(_what, _crashed, socket) do
    {:noreply, socket |> assign(busy: nil, message: TakeoverWords.error(:crashed)) |> load()}
  end

  defp done(:pair), do: gettext("Paired. The box now keeps the cloud up to date.")
  defp done(:take_over), do: gettext("This box runs the hall now.")
  defp done(:stand_by), do: gettext("This box stands by as a spare now.")
  defp done(:leave), do: gettext("The box left its hall in the cloud.")
  defp done(:step), do: nil

  @impl true
  def handle_info({:takeover, _what}, socket), do: {:noreply, load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  # --- the page ----------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:spare}
      help={:spare}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      path={@current_path}
      title={gettext("Cloud and spare")}
    >
      <div class="stack">
        <.panel :if={!@box?} id="spare-server" title={gettext("This is the cloud")}>
          <p class="note">
            {gettext(
              "Boxes in a hall pair with a hall here, on that hall's Boxes tab. This page is for a box."
            )}
          </p>
          <.button id="spare-to-halls" navigate={~p"/halls"} icon="hall">
            {gettext("Halls")}
          </.button>
        </.panel>

        <.panel
          :if={@box? and @status.phase == :unlinked}
          id="spare-unpaired"
          title={gettext("Keep a copy in the cloud")}
        >
          <p class="note">
            {gettext(
              "Paired with its hall in the cloud, this box sends every move and result there as it happens. If it dies, a second box standing by as a spare takes over with everything it sent, and the hall goes on."
            )}
          </p>
          <p class="note">
            {gettext(
              "In the cloud, open the hall, then its Boxes tab, and press \"Pair a box\". Paste the link it shows here, or type its code."
            )}
          </p>
          <.form
            :if={@may_admin}
            for={@pair_form}
            id="spare-pair-form"
            phx-submit="pair"
            class="row"
          >
            <.input
              field={@pair_form[:link]}
              id="spare-pair-link"
              label={gettext("Pairing link or code")}
              autocomplete="off"
              required
            />
            <.button id="spare-pair-submit" type="submit" variant="primary" disabled={@busy != nil}>
              {gettext("Pair")}
            </.button>
          </.form>
          <%!-- The panels are one or the other, so the ids are each once. --%>
          <p :if={@busy} id="spare-busy" class="note" role="status">{gettext("Working...")}</p>
          <p :if={@message} id="spare-message" class="note" role="alert">{@message}</p>
        </.panel>

        <.panel
          :if={@box? and @status.phase != :unlinked}
          id="spare-status"
          title={@status.hall || gettext("Hall in the cloud")}
        >
          <p :if={@line} id="spare-line">
            <.badge tone={@line.tone} icon={@line.icon}>{@line.text}</.badge>
          </p>

          <dl class="facts">
            <dt>{gettext("Cloud")}</dt>
            <dd id="spare-server-name" class="mono">{@status.server}</dd>
            <dt>{gettext("This box")}</dt>
            <dd id="spare-phase">{phase(@status.phase)}</dd>
            <dt :if={@status.phase == :active}>{gettext("Waiting to be sent")}</dt>
            <dd :if={@status.phase == :active} id="spare-queued">{@status.queued}</dd>
            <dt :if={@status.last_ok_at}>{gettext("Last heard from the cloud")}</dt>
            <dd :if={@status.last_ok_at} id="spare-last-ok">
              {Calendar.strftime(@status.last_ok_at, "%H:%M:%S")} UTC
            </dd>
          </dl>

          <p :if={@status.full?} id="spare-full" class="note" role="alert">
            {gettext(
              "The queue is full. Nothing is lost on this box; when the line is back, the box sends its whole state once instead of every event it missed."
            )}
          </p>

          <div :if={@status.phase == :superseded} id="spare-superseded" class="stack">
            <p class="note" role="alert">
              <%= if @status.holder do %>
                {gettext(
                  "%{name} runs this hall now. This box reads no boards and sends nothing, so that the two cannot disagree.",
                  name: @status.holder
                )}
              <% else %>
                {gettext(
                  "Another box runs this hall now. This box reads no boards and sends nothing, so that the two cannot disagree."
                )}
              <% end %>
            </p>
            <div :if={@may_arbiter}>
              <.button id="spare-stand-by" phx-click="stand_by" disabled={@busy != nil}>
                {gettext("Stand by as a spare")}
              </.button>
            </div>
          </div>

          <div :if={@status.phase == :spare} id="spare-standing-by" class="stack">
            <p class="note">
              {gettext(
                "This box stands by: it reads no boards and sends nothing. When the active box has been silent too long, or you press Take over, it copies the hall from the cloud and runs it. Plug the boards into this box first."
              )}
            </p>
            <div :if={@may_arbiter} class="row">
              <.button
                id="spare-take-over"
                variant="primary"
                phx-click="take_over"
                disabled={@busy != nil}
                data-confirm={
                  gettext(
                    "Take the hall over now? The box that runs it now stops at its next word with the cloud."
                  )
                }
              >
                {gettext("Take over")}
              </.button>
            </div>
            <form :if={@may_admin} id="spare-auto-form" phx-change="auto">
              <input type="hidden" name="auto" value="false" />
              <label>
                <input
                  id="spare-auto"
                  type="checkbox"
                  name="auto"
                  value="true"
                  checked={@status.auto?}
                />
                {gettext("Take over by itself when the active box has been silent too long")}
              </label>
            </form>
          </div>

          <div :if={@status.phase == :active and @may_admin} id="spare-active" class="row">
            <.button
              id="spare-make-spare"
              phx-click="stand_by"
              disabled={@busy != nil}
              data-confirm={
                gettext("Make this box a spare? It stops reading the boards until it takes over.")
              }
            >
              {gettext("Make this box a spare")}
            </.button>
          </div>

          <p :if={@busy} id="spare-busy" class="note" role="status">{gettext("Working...")}</p>
          <p :if={@message} id="spare-message" class="note" role="status">{@message}</p>

          <div class="row">
            <.button
              :if={@may_arbiter}
              id="spare-step"
              small
              variant="ghost"
              phx-click="step"
              disabled={@busy != nil}
            >
              {gettext("Ask the cloud now")}
            </.button>
            <.button
              :if={@may_admin}
              id="spare-leave"
              small
              variant="danger"
              phx-click="leave"
              disabled={@busy != nil}
              data-confirm={
                gettext(
                  "Leave the hall in the cloud? This box forgets its key and runs its hall on its own."
                )
              }
            >
              {gettext("Leave the hall")}
            </.button>
          </div>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  defp phase(:active), do: gettext("Runs the hall")
  defp phase(:spare), do: gettext("Spare")
  defp phase(:superseded), do: gettext("Stepped down")
  defp phase(_other), do: gettext("Not paired")
end
