defmodule AlnaslWeb.BoardLogWords do
  @moduledoc """
  The sentences of the board debug log (`Alnasl.BoardLog`): one plain line
  for each, made when it is shown, so it reads in the reader's language.
  Lines copied from the arbiter's log keep that log's words
  (`AlnaslWeb.Words.log/1`).
  """

  use Gettext, backend: AlnaslWeb.Gettext

  alias AlnaslWeb.Words

  @doc "The sentence of a line."
  def text(%{kind: "log", data: %{event: event}}), do: Words.log(event)
  def text(%{kind: kind, data: data}), do: line(kind, data)

  @doc "The name of a category, for the filter."
  def cat(:all), do: gettext("All")
  def cat(:move), do: gettext("Moves")
  def cat(:position), do: gettext("Readings")
  def cat(:clock), do: gettext("Clock")
  def cat(:result), do: gettext("Results")
  def cat(:connection), do: gettext("Connection")
  def cat(:sent), do: gettext("Sent")
  def cat(_other), do: gettext("Other")

  # --- connection ----------------------------------------------------------------

  defp line("driver.started", d) do
    where = d[:port] || d[:address]

    if where,
      do:
        gettext("Driver started: %{driver} on %{where}.",
          driver: Words.driver(d[:driver]),
          where: where
        ),
      else: gettext("Driver started: %{driver}.", driver: Words.driver(d[:driver]))
  end

  defp line("driver.restart", _d), do: gettext("Starting the driver again.")

  defp line("board.info", d) do
    parts =
      [
        d[:serial] && gettext("serial %{s}", s: d[:serial]),
        d[:firmware] && gettext("firmware %{f}", f: d[:firmware]),
        d[:bus_address] && gettext("loop address %{a}", a: d[:bus_address]),
        is_list(d[:loop]) && gettext("%{n} boards answer on this port", n: length(d[:loop]))
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    gettext("The board says who it is: %{parts}.", parts: parts)
  end

  defp line("poll.deaf", d),
    do:
      gettext(
        "%{n} polls in a row without an answer: the board counts as not heard, and moves may be reconstructed across the gap.",
        n: d[:run]
      )

  defp line("history.received", d),
    do:
      ngettext(
        "The board handed over its own memory: %{count} event. It is held up against the game.",
        "The board handed over its own memory: %{count} events. It is held up against the game.",
        d[:count] || 0
      )

  # --- readings --------------------------------------------------------------------

  defp line("position", %{changes: nil} = d),
    do: gettext("First reading of the board.") <> use_note(d[:use])

  defp line("position", %{changes: changes} = d) do
    said =
      case changes do
        [one] -> change(one)
        [_, _ | _] when length(changes) <= 4 -> Enum.map_join(changes, "; ", &change/1)
        many -> ngettext("%{count} square changed.", "%{count} squares changed.", length(many))
      end

    sentence = String.trim_trailing(said, ".") <> "."
    flipped = if d[:flipped], do: " " <> gettext("(read turned round)"), else: ""
    sentence <> flipped <> use_note(d[:use])
  end

  defp line("status", %{status: status, detail: detail}) do
    case status do
      :live ->
        gettext("Tracker: following the game.")

      :settling ->
        case detail do
          {:gesture, result} ->
            gettext("Tracker: the kings stand in the centre (%{result}); waiting.",
              result: result
            )

          _other ->
            gettext("Tracker: a change on the board, waiting for it to stand still.")
        end

      :waiting_start ->
        gettext("Tracker: waiting for the starting position.")

      :out_of_sync ->
        case Words.alarm(detail) do
          nil ->
            {headline, _text} = Words.state_help(:out_of_sync, detail)
            gettext("Tracker: out of sync - %{why}.", why: headline)

          named ->
            gettext("Tracker: out of sync - %{why}.", why: named)
        end

      other ->
        gettext("Tracker: %{status}.", status: to_string(other))
    end
  end

  # --- moves -----------------------------------------------------------------------

  defp line("move", d) do
    who = if d[:piece], do: Words.piece(d[:piece]), else: gettext("a piece")

    base =
      if d[:from] && d[:to],
        do:
          gettext("%{san} recognised: %{who} from %{from} to %{to}.",
            san: d.san,
            who: who,
            from: d.from,
            to: d.to
          ),
        else: gettext("%{san} recognised.", san: d.san)

    base <> " " <> how(d[:flags] || [], d[:read])
  end

  defp line("correction", d) do
    moves = Enum.join(d[:moves] || [], " ")

    reason =
      case d[:reason] do
        :takeback -> gettext("a takeback")
        :revised -> gettext("a move read too early and revised")
        :promotion -> gettext("the promotion piece set down")
        :misread -> gettext("a move read wrong and put right")
        :arbiter -> gettext("the arbiter")
        :memory -> gettext("the board's memory")
        other -> to_string(other)
      end

    gettext("The game is cut back to %{keep} plies (%{reason}), then: %{moves}",
      keep: d[:keep],
      reason: reason,
      moves: if(moves == "", do: "-", else: moves)
    )
  end

  defp line("restart", _d),
    do: gettext("The game starts over from the position on the board (a set-up position).")

  defp line("game.linked", d),
    do:
      gettext(
        "Linked to round %{round}, board %{board}, game %{game} (%{plies} plies restored, %{status}).",
        round: d[:round],
        board: d[:board],
        game: d[:game],
        plies: d[:plies],
        status: d[:status]
      )

  defp line("game.unlinked", _d), do: gettext("Not linked to any game: readings are not used.")

  # --- clock -----------------------------------------------------------------------

  defp line("clock.first", _d), do: gettext("The clock reports.")

  defp line("clock.pressed", %{to: :white}),
    do: gettext("Clock pressed: Black's time stops, White's runs.")

  defp line("clock.pressed", _d), do: gettext("Clock pressed: White's time stops, Black's runs.")

  defp line("clock.started", %{side: :white}),
    do: gettext("The clock is started: White's time runs.")

  defp line("clock.started", _d), do: gettext("The clock is started: Black's time runs.")
  defp line("clock.stopped", _d), do: gettext("The clock is stopped.")

  defp line("clock.off", _d),
    do: gettext("The clock is switched off or unplugged: no clock checks until it reports again.")

  # --- results ---------------------------------------------------------------------

  defp line("result.why", %{why: :gesture} = d) do
    colour =
      case d.result do
        "1-0" -> gettext("both on light squares (e4, d5): White won")
        "0-1" -> gettext("both on dark squares (d4, e5): Black won")
        _draw -> gettext("one on a light and one on a dark square: a draw")
      end

    gettext(
      "%{result} from the result gesture: white king on %{white}, black king on %{black}, %{colour}.",
      result: d.result,
      white: d[:white_king] || "?",
      black: d[:black_king] || "?",
      colour: colour
    )
  end

  defp line("result.why", %{why: :checkmate} = d) do
    mated = if d[:turn] == :w, do: gettext("White"), else: gettext("Black")

    gettext("%{result} from the position: %{side} is checkmated after %{last}.",
      result: d.result,
      side: mated,
      last: d[:last] || "?"
    )
  end

  defp line("result.why", %{why: :stalemate} = d) do
    side = if d[:turn] == :w, do: gettext("White"), else: gettext("Black")

    gettext("%{result} from the position: %{side} is to move and has no legal move (stalemate).",
      result: d.result,
      side: side
    )
  end

  defp line("result.why", %{why: :insufficient_material} = d),
    do:
      gettext("%{result} from the position: neither side has enough material left to mate.",
        result: d.result
      )

  defp line("result.why", d),
    do: gettext("%{result} suggested (%{why}).", result: d[:result], why: to_string(d[:why]))

  defp line("result.auto", d),
    do:
      gettext(
        "%{result} set by itself: it is a fact of the position, and \"Offer mate and stalemate to the results site without waiting for me\" is on.",
        result: d[:result]
      )

  defp line("result.waits", %{fact: false} = d),
    do:
      gettext(
        "%{result} stays a suggestion for the arbiter: a gesture is never taken as a result by itself.",
        result: d[:result]
      )

  defp line("result.waits", d),
    do:
      gettext(
        "%{result} stays a suggestion for the arbiter: \"Offer mate and stalemate to the results site without waiting for me\" is off.",
        result: d[:result]
      )

  defp line("result.by_hand", %{by: "openpairings"} = d),
    do:
      gettext("%{result} set by the arbiter in OpenPairings (a command Alnasl fetched)%{was}.",
        result: d[:result],
        was: suggested(d[:suggestion], d[:result])
      )

  defp line("result.by_hand", d),
    do:
      gettext("%{result} set by the arbiter on the board's page%{was}.",
        result: d[:result],
        was: suggested(d[:suggestion], d[:result])
      )

  # --- sent ------------------------------------------------------------------------

  defp line("queued", d) do
    what =
      case d[:why] do
        :heartbeat ->
          gettext("the clocks, as they read now")

        _change ->
          if d[:replace], do: gettext("the whole game again"), else: gettext("the change")
      end

    ngettext(
      "Queued for every destination: %{what} (%{count} ply, update %{seq}).",
      "Queued for every destination: %{what} (%{count} plies, update %{seq}).",
      d[:plies] || 0,
      what: what,
      seq: d[:seq]
    )
  end

  defp line("sent", d) do
    where = destination(d[:destination])

    case {d[:outcome], d[:detail]} do
      {:sent, detail} when detail in [nil, ""] ->
        gettext("%{where} took update %{seq}.", where: where, seq: d[:seq])

      {:sent, _note} ->
        gettext("%{where} answered update %{seq} without applying it: %{why}.",
          where: where,
          seq: d[:seq],
          why: d[:detail]
        )

      {:rejected, _code} ->
        gettext("%{where} refused update %{seq}: %{why}.",
          where: where,
          seq: d[:seq],
          why: Words.entry_error(d[:detail]) || d[:detail] || "?"
        )

      _retry ->
        gettext("%{where} could not be reached for update %{seq}; it is tried again (%{why}).",
          where: where,
          seq: d[:seq],
          why: d[:detail] || "?"
        )
    end
  end

  defp line(kind, _d), do: kind

  # --- pieces of sentences ---------------------------------------------------------

  defp change({square, before, nil}),
    do:
      gettext("%{piece} lifted from %{square}", piece: Words.piece(before), square: name(square))

  defp change({square, nil, after_}),
    do:
      gettext("%{piece} set down on %{square}", piece: Words.piece(after_), square: name(square))

  defp change({square, before, after_}),
    do:
      gettext("%{square}: %{before} replaced by %{after}",
        square: name(square),
        before: Words.piece(before),
        after: Words.piece(after_)
      )

  defp name(square) when is_integer(square), do: Alnasl.Position.square_name(square)
  defp name(square), do: to_string(square)

  defp use_note(:unlinked), do: " " <> gettext("Not used: the board feeds no game.")
  defp use_note(:finished), do: " " <> gettext("Not used: the game is over.")

  defp use_note(:held),
    do: " " <> gettext("Held back: the board's memory is expected first.")

  defp use_note(_used), do: ""

  # How the tracker knows a move: seen, or worked out, and how sure.
  defp how(flags, read) do
    cond do
      :guessed in flags ->
        gettext("Not seen: one of several lines of moves that fit the board was taken. Check it.")

      :recovered in flags and :long_gap in flags ->
        gettext("Not seen: worked out after a gap in contact; only this line of moves fits.")

      :recovered in flags ->
        gettext(
          "Not seen move by move: worked out from the squares; only this line of moves fits."
        )

      :rewritten in flags ->
        gettext("First read as %{read}, a piece set down beside its square, and put right.",
          read: read || "?"
        )

      :memory in flags ->
        gettext("Taken from the board's own memory.")

      :arbiter in flags ->
        gettext("Entered by hand.")

      :assumed in flags ->
        gettext("Seen; the promotion piece was not, so a queen is assumed.")

      :unseen in flags ->
        gettext("Seen and legal, made while a piece stood unseen.")

      true ->
        gettext(
          "Seen: the piece left one square and arrived on the other, and it is legal there."
        )
    end
  end

  defp suggested(nil, _result), do: ""
  defp suggested(same, same), do: " " <> gettext("(as the board suggested)")

  defp suggested(other, _result),
    do: " " <> gettext("(the board suggested %{other})", other: other)

  defp destination("openresults"), do: gettext("The results site")
  defp destination("openpairings"), do: gettext("OpenPairings")
  defp destination("lichess"), do: gettext("Lichess")
  defp destination(other), do: to_string(other)
end
