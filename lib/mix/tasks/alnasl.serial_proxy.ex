defmodule Mix.Tasks.Alnasl.SerialProxy do
  @shortdoc "Sits between DGT LiveChess and a real serial port and logs every byte both ways"

  @moduledoc """
  Sit between DGT LiveChess and a real serial port, forward every byte both
  ways, and log it with timestamps - a capture of the DGT bus with one
  adapter.

      LiveChess -> COM10 (com0com) <=> COM11 -> alnasl.serial_proxy -> COM3 -> boards

      ALNASL_UART=1 mix alnasl.serial_proxy --app COM11 --board COM3 --out capture.log

  Options: `--app` (the com0com end LiveChess does NOT use), `--board` (the
  real port of the loop), `--baud` (9600), `--out` (`capture.log`, appended
  to). The log has one line per chunk read:

      12.345678  APP>BRD  42
      12.351002  BRD>APP  86 00 43 00 00 ...

  APP>BRD is what LiveChess sent to the boards, BRD>APP what came back. Bytes
  are hex. A line `# ...` is a note you typed into the console while it
  runs (press Enter on an empty line to stop): use it to mark what you just
  did on the boards - "e2e4 on board 1", "lifted the knight on g1", "knocked
  over". `mix alnasl.replay` reads this log.

  Needs the serial library: on Windows start with `ALNASL_UART=1` from a
  checkout whose path has no space in it (see the README).
  """

  use Mix.Task

  alias Arkab.Transport.Uart

  @doc "The log line of one chunk: seconds since the start, direction tag, hex bytes."
  def chunk_line(seconds, tag, data) do
    "#{stamp(seconds)}  #{tag}  #{hex(data)}\n"
  end

  @doc "The log line of a note typed into the console."
  def note_line(seconds, note), do: "# #{stamp(seconds)}  NOTE  #{note}\n"

  @doc "The direction tag of bytes that arrived from `from` (`:app` or `:board`)."
  def tag(:app), do: "APP>BRD"
  def tag(:board), do: "BRD>APP"

  defp stamp(seconds),
    do:
      seconds |> :erlang.float() |> :erlang.float_to_binary(decimals: 6) |> String.pad_leading(12)

  defp hex(data),
    do:
      data
      |> :binary.bin_to_list()
      |> Enum.map_join(
        " ",
        &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase())
      )

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [app: :string, board: :string, baud: :integer, out: :string]
      )

    app_port =
      opts[:app] || Mix.raise("Give --app and --board. See mix help alnasl.serial_proxy.")

    board_port =
      opts[:board] || Mix.raise("Give --app and --board. See mix help alnasl.serial_proxy.")

    baud = opts[:baud] || 9600
    out = opts[:out] || "capture.log"

    Mix.Task.run("app.config")
    if Uart.available?(), do: Application.ensure_all_started(:circuits_uart)

    unless Uart.available?() do
      Mix.raise(
        "The serial library is not built into this copy. Start with ALNASL_UART=1 (see the README)."
      )
    end

    app = open!(app_port, baud)
    board = open!(board_port, baud)
    {:ok, log} = File.open(out, [:append, :utf8])
    t0 = System.monotonic_time(:microsecond)

    IO.write(
      log,
      "# capture started #{Calendar.strftime(NaiveDateTime.local_now(), "%Y-%m-%d %H:%M:%S")} " <>
        "app=#{app_port} board=#{board_port} baud=#{baud}\n"
    )

    me = self()
    spawn_link(fn -> notes(me) end)

    Mix.shell().info("Forwarding #{app_port} <-> #{board_port}, logging to #{out}.")
    Mix.shell().info("Type a note and press Enter to mark the log; an empty line stops.")

    ports = %{app_port => {:app, board}, board_port => {:board, app}}
    loop(ports, log, t0)

    IO.write(log, "# capture stopped\n")
    File.close(log)
    Uart.close(app)
    Uart.close(board)
    Mix.shell().info("Stopped.")
  end

  defp open!(port, baud) do
    case Uart.open(port, baud: baud) do
      {:ok, handle} -> handle
      {:error, reason} -> Mix.raise("Cannot open #{port}: #{inspect(reason)}")
    end
  end

  defp notes(owner) do
    case IO.gets("") do
      line when is_binary(line) ->
        case String.trim(line) do
          "" ->
            send(owner, :stop)

          note ->
            send(owner, {:note, note})
            notes(owner)
        end

      _eof ->
        send(owner, :stop)
    end
  end

  defp loop(ports, log, t0) do
    receive do
      :stop ->
        :ok

      {:note, note} ->
        IO.write(log, note_line(elapsed(t0), note))
        Mix.shell().info("  marked.")
        loop(ports, log, t0)

      {:circuits_uart, port, _} = msg when is_map_key(ports, port) ->
        {from, to} = Map.fetch!(ports, port)

        case Uart.message(msg) do
          {:data, data} ->
            Uart.write(to, data)
            IO.write(log, chunk_line(elapsed(t0), tag(from), data))
            loop(ports, log, t0)

          {:error, reason} ->
            IO.write(log, "# #{tag(from)} read error: #{inspect(reason)}\n")

          nil ->
            loop(ports, log, t0)
        end

      _other ->
        loop(ports, log, t0)
    end
  end

  defp elapsed(t0), do: (System.monotonic_time(:microsecond) - t0) / 1_000_000
end
