defmodule Alnasl.AccessPin do
  @moduledoc """
  The PIN a browser on another machine gives before it is let in. There is
  always one: made at the first start, six random digits, and changed in
  Setup or by the box. There is no way to have none, which used to be the
  default and was exactly as safe as it sounds.

  It lives in plain text in `<data>/access-pin`, one line, mode 0600. Plain,
  because it has to be shown: on the box's own Setup page, and on the Pi's
  screen, which reads this file. The box never writes it; it asks for a
  change through `<data>/pin-request` before Alnasl starts
  (`Alnasl.PinRequest`).

  The file is written whole and renamed over the old one, and neither path
  is followed when it is a symlink. What was read is kept in a
  `:persistent_term` and read again only after this module wrote it.

  The PIN is never logged, never put in a URL, never in the Log page and
  never in a support upload. A browser that gave it carries a *stamp* of it
  (`AlnaslWeb.Hall.pin_stamp/0`), keyed with the endpoint's secret, so a
  new PIN voids every earlier grant without anybody keeping a list.

  ## The rules for a PIN

  6 to 64 characters, no space at either end, nothing invisible. Digits,
  letters, punctuation and spaces inside are all fine.
  """

  require Logger

  @file_name "access-pin"
  @min 6
  @max 64

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # A supervisor child that does its work while it is being started, so the
  # endpoint never answers a request before there is a PIN, and then is not
  # there (`:ignore`).
  @doc false
  def start_link(opts) do
    boot(Keyword.get(opts, :dir, default_dir()))
    :ignore
  end

  @doc "The shortest PIN there may be."
  def min_length, do: @min

  @doc "The longest PIN there may be."
  def max_length, do: @max

  @doc "The file's name inside the data directory."
  def file_name, do: @file_name

  @doc "Where the PIN is kept."
  def path(dir \\ default_dir()), do: Path.join(dir, @file_name)

  @doc """
  What the start does, in order: a request from the box, then the old
  hash of Alnasl 0.17 and before, then a PIN if there is still none.
  Returns `:kept`, `:made` or `:replaced_legacy`.
  """
  def boot(dir) do
    forget(dir)
    Alnasl.PinRequest.consume(dir)
    legacy? = retire_legacy()

    case read(dir) do
      {:ok, _pin} ->
        :kept

      :none ->
        {:ok, _pin} = renew(dir, broadcast: false)

        if legacy? do
          note_legacy()
          :replaced_legacy
        else
          Logger.info("Access PIN made: there was none.")
          :made
        end
    end
  end

  @doc """
  The PIN now. Made on the spot if the file went missing since the start:
  there is always one.
  """
  def current(dir \\ default_dir()) do
    case :persistent_term.get(key(dir), nil) do
      nil ->
        case read(dir) do
          {:ok, pin} ->
            :persistent_term.put(key(dir), pin)
            pin

          :none ->
            {:ok, pin} = renew(dir)
            pin
        end

      pin ->
        pin
    end
  end

  @doc "Whether `guess` is the PIN. Constant time."
  def valid?(guess, dir \\ default_dir())

  def valid?(guess, dir) when is_binary(guess),
    do: Plug.Crypto.secure_compare(guess, current(dir))

  def valid?(_guess, _dir), do: false

  @doc """
  `:ok`, or `{:error, reason}` with reason one of `:too_short`,
  `:too_long`, `:edge_space`, `:invisible`.
  """
  def validate(pin) when is_binary(pin) do
    cond do
      not String.valid?(pin) -> {:error, :invisible}
      String.length(pin) < @min -> {:error, :too_short}
      String.length(pin) > @max -> {:error, :too_long}
      String.trim(pin) != pin -> {:error, :edge_space}
      pin |> String.to_charlist() |> Enum.any?(&invisible?/1) -> {:error, :invisible}
      true -> :ok
    end
  end

  def validate(_pin), do: {:error, :too_short}

  defp invisible?(c), do: c < 32 or c in 127..159

  @doc """
  Sets the PIN, if it keeps the rules. Every browser that gave the old one
  has to give this one, and the pages it has open are closed.
  """
  def set(pin, dir \\ default_dir(), opts \\ []) do
    with :ok <- validate(pin) do
      write(dir, pin, opts)
    end
  end

  @doc "A fresh random PIN of six digits, with the same effects as `set/3`. `{:ok, pin}`."
  def renew(dir \\ default_dir(), opts \\ []) do
    pin = random()
    :ok = write(dir, pin, opts)
    {:ok, pin}
  end

  @doc "Six digits from `:crypto.strong_rand_bytes/1`, none favoured."
  def random do
    # 8 bytes mod 10^6: the bias is under 1 in 10^13.
    <<n::unsigned-64>> = :crypto.strong_rand_bytes(8)
    n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  # --- the file -------------------------------------------------------------------

  @doc false
  # `{:ok, pin}` when the file is a plain file holding a valid PIN, else `:none`.
  def read(dir) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path(dir)),
         {:ok, content} <- File.read(path(dir)),
         pin = content |> String.trim_trailing("\n") |> String.trim_trailing("\r"),
         :ok <- validate(pin) do
      {:ok, pin}
    else
      _missing_or_bad -> :none
    end
  end

  defp write(dir, pin, opts) do
    :global.trans({__MODULE__, dir}, fn ->
      File.mkdir_p!(dir)
      target = path(dir)
      tmp = target <> ".new"

      # Whatever sits at the temporary name - a leftover, a symlink - goes,
      # and the new file is made exclusively, so nothing is followed.
      _ = File.rm(tmp)

      {:ok, io} = File.open(tmp, [:write, :exclusive, :binary])

      try do
        # Private while still empty: the PIN is never in a file others may
        # read, not even for the moment before a chmod. On Windows chmod does
        # nothing and the profile folder's own rights do the job.
        _ = File.chmod(tmp, 0o600)
        :ok = IO.binwrite(io, pin <> "\n")
      after
        File.close(io)
      end

      # rename(2) replaces a symlink at the target, it does not follow it.
      :ok = File.rename(tmp, target)
      :persistent_term.put(key(dir), pin)
    end)

    if Keyword.get(opts, :broadcast, true), do: changed()
    :ok
  end

  # Every remote browser's open pages, closed: they reconnect, show their
  # stale stamp and are sent to /unlock. Before the endpoint runs there is
  # nobody to tell.
  defp changed do
    AlnaslWeb.Endpoint.broadcast(socket_id(), "disconnect", %{})
  rescue
    _not_started -> :ok
  catch
    :exit, _not_started -> :ok
  end

  @doc "The `live_socket_id` of every browser let in with the PIN."
  def socket_id, do: "access_pin"

  # --- the hash of Alnasl 0.17 and before ----------------------------------------------

  # A salted hash in the settings cannot be shown, so it goes, and a new PIN
  # is made in its place (`boot/1`). True when there was one.
  defp retire_legacy do
    case Alnasl.Settings.get("pin") do
      %{} ->
        Alnasl.Settings.put("pin", nil)
        true

      _none ->
        false
    end
  rescue
    _no_database -> false
  catch
    :exit, _no_database -> false
  end

  defp note_legacy do
    Alnasl.Settings.put("pin_notice", true)
    Logger.warning("Access PIN made: the old one was kept only as a hash and cannot be shown.")
  rescue
    _no_database -> :ok
  catch
    :exit, _no_database -> :ok
  end

  @doc "Whether Setup still owes the arbiter the word that the PIN was made new."
  def notice?, do: Alnasl.Settings.get("pin_notice") == true

  @doc "The word was read."
  def notice_seen, do: Alnasl.Settings.put("pin_notice", nil)

  @doc false
  def forget(dir \\ default_dir()), do: :persistent_term.erase(key(dir))

  defp key(dir), do: {__MODULE__, Path.expand(dir)}

  defp default_dir, do: Alnasl.Paths.data()
end
