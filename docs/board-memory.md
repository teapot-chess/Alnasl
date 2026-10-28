# A board's own memory, read back

A DGT board keeps a log of everything it felt in its own memory: every
square that changed, every clock time written when a lever went over, and a
handful of marks (switched on, starting position, restarted). It keeps
writing whether anybody is reading the board or not. That makes it the one
witness to what happened while a cable was out, a bridge was down or a Pi
was being swapped for the spare: the first step towards a spare box taking
over without anybody retyping a game.

## Who does what

**Arkab** (the drivers) asks for the memory and decodes it:

- On a loop, with `0x86` ("from start") to one board at a time, when the
  board is first met, when it comes back after not answering, and when its
  own changes say it was switched off and on (a power-up or restarted
  mark). Between two boards' memories every board is asked its ordinary
  question, so twelve boards coming back at once do not stop the moves on
  all twelve. A memory that does not arrive whole is asked for twice and
  then left unread; the board goes on being read.
- On its own on a serial port, with `0x49` (`DGT_SEND_EE_MOVES`) once, at
  the first resync after the handshake, then back to update mode. A memory
  cut short on the line (a byte with bit 7 set inside it) is let go of and
  does not swallow the messages after it.

Either way the driver sends `{:history, events}` (`Arkab.Dgt.Bus.history/1`,
oldest first, at most 20,000 events, the newest kept), and a bridge carries
it as the `hist` event of `bridge-protocol-v1`. An Alnasl that does not know
the event drops it and acknowledges it, as it does any event it does not
know.

**Alnasl** holds it up against the game (`Alnasl.BoardHistory`, pure, no
process):

1. The events become what a board process would have seen: a whole board
   after each change, clock presses between them. The pieces a board scans
   after it is switched on are one reading, not thirty-two. Until the
   memory says where every piece stood (a power-up or a starting position),
   field events are passed over: that is the front of a memory that went
   round.
2. The readings are played through the same `Alnasl.Tracker` that reads the
   live board, one reading every 600 ms of its time, so castles, captures
   and promotions are found exactly as they would have been live.
3. The game Alnasl has is the anchor:
   - A game from the starting position is compared with the newest game in
     the memory that starts there. More of the same moves: **added**. The
     same or fewer: nothing. Other moves: a **draft**. An older game in the
     memory that fits as well: a draft (`ambiguous`). The pieces set up
     again since, and an older game that goes on from this one: a draft
     (`earlier_game`), never taken by itself, since yesterday's game with
     the same opening fits just as well.
   - A game set up from a position, or a memory with no starting position
     in it: the last reading that shows the board where the game stands is
     where a tracker, caught up with the game, takes over. A reading of an
     earlier position of the game: a draft (`conflict`). The start not in
     the memory at all, but a game from the starting position is: a draft
     (`unknown_start`). Nothing: nothing.

Added moves are marked `memory` in the game (`Alnasl.Games`), logged as
`board.history_merged`, saved, queued and sent like any other moves. A
draft is a row of `memory_drafts` (`Alnasl.MemoryDrafts`) beside the game,
keyed by what it says, so the same memory read every time the board comes
back is one draft, and a dismissed one stays dismissed. The board's page
shows it with **Use the board's version** and **Keep the game as it is**;
the round's tile says one is waiting. Using it is a correction from where
the two part (or a restart from the memory's start position), sent as a
replacement of the game; it is refused when the game has changed since in
the moves the draft relies on.

Nothing is ever written to a board: `0x85` (clear the memory) is not sent,
not even as an option. Clearing a memory that is the only record of a game
is the kind of help nobody asked for.

A memory that does not decode, a reading the tracker cannot make sense of,
or anything else going wrong leaves the game as it was: the board's process
logs `board.history_failed` and goes on.

## Verified, and not

Verified against the real thing: the two memories read from boards 6310
and 12799 on 2026-10-12 (`test/fixtures/captures/real-loop-06-*.jsonl`),
1461 and 1313 bytes. Each replays in Arkab to the board that board showed
in the dump taken the same day, and 12799's replays in Alnasl to an 80-ply
game from 1. e4 c5, legal move by move, with its clock times.

Checked with synthetic memories only:

- **A memory that wrapped.** How much a board holds, and what a full one
  does (stops, wraps, drops the oldest), is not known. Wrapped memories are
  tested by cutting the real ones at clock and field bytes.
- **Power-up in the middle of a game**, made with Arkab's emulator.
- **`0x49` on a single board.** The command is in DGT's published protocol;
  no board on its own line has been asked it yet. Its reply is assumed to
  have the same layout as the loop's `0x86` reply.
- **Timing on a full loop.** Twelve memories one after another, with the
  polls in between, run against the emulator. How long a real full memory
  takes on a real loop, and whether a board answers its ordinary questions
  promptly right after sending one, is not measured.
- **Rotated starting position mark** (`0x7A`), end of data (`0x6B`) and
  empty board (`0x6D`): decoded as documented, never seen in a capture.

Before relying on this in a hall: read a memory from a board that played a
whole game with the cable out, from one switched off mid-game, and from one
whose memory has been filling for weeks; and watch a loop of twelve boards
come back at once.
