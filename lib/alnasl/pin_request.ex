defmodule Alnasl.PinRequest do
  @moduledoc """
  A PIN asked for from outside the web page: the one way in that does not
  need a browser, for a box with no screen and no keyboard.

  On the Pi image a root-run step on the box leaves a *request file*,
  `pin-request`, in Alnasl's data directory (mode 0600, owner the user
  Alnasl runs as) before Alnasl starts. `consume/1` reads it at the start
  (`Alnasl.AccessPin.boot/1`), applies it and deletes it, whatever came of
  it. The box then reads `access-pin` back to see where things stand.

  Nothing here listens, and nothing a visitor can send reaches it: the file
  is in a directory only the box's own accounts can write to. A symlink, or
  anything else that is not a plain file, is deleted unread.

  The file is one of:

      set
      the-pin

  or `new` alone, for six fresh random digits. There is no `remove`: there
  is always a PIN. The PIN is never logged, here or anywhere it passes.
  """

  require Logger

  alias Alnasl.AccessPin

  @file_name "pin-request"

  @doc "The request file's name inside the data directory."
  def file_name, do: @file_name

  @doc """
  Applies the request in `data_dir`, if there is one, and deletes it.
  Returns `:none` without one, otherwise what became of it: `:set`, `:new`
  or `{:refused, reason}`.
  """
  @spec consume(Path.t()) :: :none | :set | :new | {:refused, atom()}
  def consume(data_dir) do
    path = Path.join(data_dir, @file_name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        result = path |> File.read() |> apply_request(data_dir)
        File.rm(path)
        report(result)
        result

      {:ok, _symlink_or_worse} ->
        File.rm(path)
        report({:refused, :not_a_plain_file})
        {:refused, :not_a_plain_file}

      {:error, _no_file} ->
        :none
    end
  end

  defp apply_request({:ok, content}, dir) do
    case String.split(content, "\n", parts: 2) do
      [command, rest] -> command(String.trim_trailing(command, "\r"), rest, dir)
      [command] -> command(String.trim_trailing(command, "\r"), "", dir)
    end
  end

  defp apply_request({:error, _reason}, _dir), do: {:refused, :unreadable}

  defp command("set", rest, dir) do
    pin = rest |> String.trim_trailing("\n") |> String.trim_trailing("\r")

    case AccessPin.set(pin, dir, broadcast: false) do
      :ok -> :set
      {:error, reason} -> {:refused, reason}
    end
  end

  defp command("new", rest, dir) do
    if String.trim(rest) == "" do
      {:ok, _pin} = AccessPin.renew(dir, broadcast: false)
      :new
    else
      {:refused, :unreadable}
    end
  end

  defp command(_other, _rest, _dir), do: {:refused, :unknown_command}

  defp report(:set), do: Logger.info("Access PIN set from the request file.")
  defp report(:new), do: Logger.info("Access PIN made new from the request file.")

  defp report({:refused, reason}),
    do: Logger.warning("Access PIN request refused (#{reason}); the PIN is unchanged.")
end
