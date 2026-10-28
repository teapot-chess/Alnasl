defmodule Alnasl.Takeover.Hooks do
  @moduledoc """
  What runs right after a box has taken over a hall: the cloud's state is
  written here (`Alnasl.Takeover.Restore`), the box is active and its boards
  are starting.

  This is the seam for **board-memory recovery**. While no box ran the hall
  - the old one went silent, nobody had taken over yet - the boards went on
  being played, and a DGT board keeps the moves it saw. The games restored
  here end where the cloud's copy ended; whatever was played after that is
  in the boards. `after_takeover/1` is where a history pull belongs: for
  each board in `summary.boards` (serials), ask the board for what it
  stored and merge it into its game, the way a board that comes back after
  a power cut does.

  Today it tells whoever listens (`{:takeover, {:took_over, summary}}` on
  `Alnasl.Takeover.subscribe/0`), and calls the function configured as
  `config :alnasl, :after_takeover` (`{module, function}`, given the
  summary), if there is one. Nothing here waits for either: the hall is
  running already.
  """

  require Logger

  @doc """
  `summary`: `%{epoch, games, tournaments, boards}` - `boards` the serials
  of the boards whose table and game were restored.
  """
  def after_takeover(summary) do
    Alnasl.Takeover.notify({:took_over, summary})

    case Application.get_env(:alnasl, :after_takeover) do
      {module, function} when is_atom(module) and is_atom(function) ->
        try do
          apply(module, function, [summary])
        rescue
          error ->
            Logger.error("takeover: after_takeover failed: #{Exception.message(error)}")
        end

      _none ->
        :ok
    end

    :ok
  end
end
