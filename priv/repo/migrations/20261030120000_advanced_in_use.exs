defmodule Alnasl.Repo.Migrations.AdvancedInUse do
  use Ecto.Migration

  # "Show advanced features" is simple mode's switch (`AlnaslWeb.Mode`,
  # `ui_mode`). The `ui_mode` migration already left a box that was in use
  # before simple mode existed in full mode. This one catches the box that
  # was installed after that, never touched the switch, and has quietly
  # set something advanced since: fair play switched on, a tracker tuned,
  # the PIN set, the box renamed, the capture limit or the clock heartbeat
  # moved, the suggestions on. Taking those pages out of its menu would
  # take away something it uses, so it is given advanced features.
  #
  # A box that chose (a `ui_mode` row exists, either way) is left alone, and
  # so is one whose settings are all still the defaults. A setting saved at
  # its default value counts as the default. The sound switch on the
  # numbering page lives in the browser, out of this migration's reach.
  def up do
    %{rows: chosen} = repo().query!("SELECT 1 FROM settings WHERE key = 'ui_mode' LIMIT 1")

    if chosen == [] and advanced_in_use?() do
      repo().query!(
        "INSERT INTO settings (key, value) VALUES ('ui_mode', ?) ON CONFLICT(key) DO NOTHING",
        [Jason.encode!("full")]
      )
    end
  end

  def down, do: :ok

  defp advanced_in_use? do
    %{rows: settings} =
      repo().query!("""
      SELECT 1 FROM settings WHERE
           (key = 'auto_suggest' AND value = 'true')
        OR (key = 'new_game_on_setup' AND value <> '"unpaired"')
        OR (key = 'clock_heartbeat_s' AND value <> '20')
        OR (key = 'capture_cap_mb' AND value <> '500')
        OR (key = 'tracker' AND value NOT IN ('{}', 'null'))
        OR (key = 'pin' AND value <> 'null')
        OR (key = 'box_name' AND value <> '"Alnasl"')
      LIMIT 1
      """)

    %{rows: fair_play} =
      repo().query!("SELECT 1 FROM fair_play_settings WHERE enabled = 1 LIMIT 1")

    settings != [] or fair_play != []
  end
end
