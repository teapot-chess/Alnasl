defmodule AlnaslWeb.TakeoverWords do
  @moduledoc """
  What the pages say about a spare box taking over (`Alnasl.Takeover`): the
  box's status line in the frame, and the words for roles and errors.
  """

  use Gettext, backend: AlnaslWeb.Gettext

  alias Alnasl.Takeover

  @doc """
  The box's status line, `%{tone, icon, text}`, or `nil` on a box that is
  paired with no cloud (and on the cloud itself).
  """
  def line do
    if Alnasl.edition() == :box, do: line(Takeover.status()), else: nil
  end

  def line(%{phase: :unlinked}), do: nil

  def line(%{taking_over?: true}),
    do: %{tone: "warn", icon: "settling", text: gettext("Taking over the hall...")}

  def line(%{phase: :superseded}),
    do: %{tone: "bad", icon: "out_of_sync", text: gettext("Another box took over")}

  def line(%{phase: :spare, online?: false}),
    do: %{tone: "warn", icon: "offline", text: gettext("Standing by as a spare, no cloud")}

  def line(%{phase: :spare}),
    do: %{tone: nil, icon: "waiting", text: gettext("Standing by as a spare")}

  def line(%{phase: :active, full?: true, queued: n}),
    do: %{
      tone: "bad",
      icon: "warning",
      text: gettext("Queue full: %{count} events kept, the rest goes as one copy", count: n)
    }

  def line(%{phase: :active, online?: false, queued: n}),
    do: %{
      tone: "warn",
      icon: "offline",
      text: ngettext("Offline, %{count} event queued", "Offline, %{count} events queued", n)
    }

  def line(%{phase: :active, online?: true}),
    do: %{tone: "ok", icon: "live", text: gettext("Streaming to the cloud")}

  def line(%{phase: :active}),
    do: %{tone: nil, icon: "waiting", text: gettext("Reaching the cloud...")}

  @doc "A role in a hall, as the cloud lists its boxes."
  def role("active"), do: gettext("active")
  def role("spare"), do: gettext("spare")
  def role("superseded"), do: gettext("stepped down")
  def role(_none), do: gettext("not heard from")

  @doc "Why something the box asked for did not happen."
  def error(:already),
    do: gettext("This box is already paired with a hall. Leave that hall first.")

  def error(:bad_link), do: gettext("That is not a pairing link or code.")
  def error(:used_or_expired), do: gettext("That code is used up or has run out. Make a new one.")

  def error(:elsewhere),
    do: gettext("This box is still paired with another hall. Remove it there first.")

  def error(:rate_limited), do: gettext("Too many tries. Wait a few minutes.")
  def error(:unreachable), do: gettext("The cloud did not answer. Is the box online?")
  def error(:unpaired), do: gettext("This box is not paired with a hall.")
  def error(:superseded), do: gettext("Another box runs this hall now.")
  def error(:stale), do: gettext("Another box runs this hall now.")

  def error(:restore_failed),
    do: gettext("The hall could not be copied here. This box stays a spare.")

  def error(:revoked), do: gettext("This box was removed from its hall in the cloud.")
  def error(_other), do: gettext("The cloud said no.")
end
