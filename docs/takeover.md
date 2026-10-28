# A spare box takes over

Status (2026-10-28): built, tested in one process (a box and its cloud in
the same test run). Not yet tried with two real Pis: see the end.

Code: `Alnasl.Takeover` (the box's record and status),
`Alnasl.Takeover.Stream` (what a saved game queues),
`Alnasl.Takeover.Link` (the box's process), `Alnasl.Takeover.Snapshot` and
`Alnasl.Takeover.Restore` (the whole state, out and in),
`Alnasl.Takeover.Cloud` and `AlnaslWeb.TakeoverController` (the cloud),
`Alnasl.Takeover.Hooks` (what runs after a takeover). Pages: `/spare` on a
box (`AlnaslWeb.SpareLive`), the hall's Boxes tab in the cloud
(`AlnaslWeb.HallsLive`), the status line in the bar. Manual: "A spare box"
(`priv/manual/09-spare-box.md`, and `nl/`).

## The shape

- The box in the hall is primary. It runs the hall with or without a line
  to the cloud, as it always did.
- The cloud is a backup and the place where the hand-over happens. It runs
  no hall of its own for these boxes.
- One active box per hall, any number of spares. Not a mesh: boxes never
  talk to each other, only to the cloud.

A box is paired with one hall in the cloud. The active box streams to it;
a spare stands by and asks the cloud, every few seconds, whether the
active box is still there. When it is not (silence past the lease), or
somebody presses **Take over** (on the spare, or on the hall's Boxes tab),
the spare gets the lease, pulls the state and the events after it, writes
them into its own database, and runs the hall.

## The stream

`Alnasl.Games.save/2` is the one place a game changes; it tells
`Alnasl.Takeover.Stream.game_saved/2` the game before and after. On an
active box that becomes events, appended to the `takeover_queue` table:

| kind | when | data |
|---|---|---|
| `start` | the first move of a game | white, black, start_fen |
| `ply` | each new move (`ply` = its number) | san, clock, at, flags |
| `truncate` | a take-back or a new start position | keep, start_fen |
| `end` | the game got its result | result |
| `result` | status, result or suggestion changed otherwise | status, result, suggestion |

Every event also carries `where` (tournament, round, board, game number
on the sending box), the board's serial when there is one, the time, and
the game's key `"<box uid>/<game id>"`.

An event's id is `"<box uid>-<seq>"`, `seq` being the queue row's id.
The table's key is `INTEGER PRIMARY KEY AUTOINCREMENT`, so a number is
never given twice, even after the queue was emptied; the cloud keeps an
id once (unique on hall and id, insert-or-ignore). A batch sent twice,
because an answer was lost, changes nothing.

The queue is on disk (the box's SQLite database, WAL, synchronous FULL):
it survives a restart and a power cut, and goes out oldest first, 500 a
batch, up to 20 batches a step. The cloud answers with the highest
`seq` it has; the box deletes up to there.

**The cap.** 50,000 events (`ALNASL_TAKEOVER_QUEUE_CAP`). Past it, new
events are not queued: the box says **Queue full** on its status line,
logs it once, and remembers to send its whole state as soon as the queue
is empty again. Nothing is lost on the box; the cloud's copy is whole
again after that one state.

**The state.** When the queue is empty, the box sends its whole state
(`Snapshot.build/1`: tournaments without their secrets, placements, its
own boards, the games of each current round plus any live game, a few
settings) when it changed, at most every 15 seconds, and at once after an
overflow. The cloud stamps it with the highest event id it holds for the
hall (`mark`). A restore is that state plus the events after `mark`.

## The lease

One row a hall in the cloud (`takeover_leases`): the box that holds it,
the epoch, and when it runs out.

- The active box renews it every 5 seconds (a step). It runs for 45
  seconds after each renewal (`ALNASL_TAKEOVER_LEASE_SECONDS` on the
  cloud, at least 15).
- A box that holds it, renewing with its own epoch: renewed.
- Anyone else while it is live: refused (`held`).
- Once it has run out, the next box to claim it gets it, with the epoch
  one higher. A spare claims as a box that holds none (epoch `null`).
- **Take over** on a spare, or on the hall's Boxes tab (owner or
  arbiter), grants it at once, epoch one higher, live or not.
- A box claiming with an epoch older than the lease's is never given it
  back, even when it has run out: it steps down (below).
- A box removed from its hall loses the lease with its key.

Decisions are made in one `BEGIN IMMEDIATE` transaction, so two spares
asking at once cannot both win.

A spare paired with a hall in which no box holds the lease takes it on
its first step (with "Take over by itself" on): a hall with only a spare
in it has nobody else to run it.

## Fencing

Every write (`events`, `state`) and every restore carries the epoch the
box believes it holds. The cloud checks it against the lease's box and
epoch; anything else is a 409 with the lease as it is (who holds it, by
name). Nothing of a refused batch is kept.

An active box that is refused (a write, or a renewal that is `held` or
`stale`) **steps down**: it marks itself superseded, stops its boards and
its senders (`Alnasl.Boards.start` and `Alnasl.Destination.Sender` both
check `Alnasl.Takeover.driving?/0`), queues nothing more, and says
**Another box took over** with the other box's name. Its only button is
**Stand by as a spare**. It does this also when it comes back after a long
time offline with moves it never sent: two boxes writing one hall is
worse than one box missing some moves, and those moves are on the boards.

## After a takeover

`Alnasl.Takeover.Hooks.after_takeover/1` runs once the restore is
committed, with `%{games, boards, tournaments, epoch}` - `boards` being
the serials restored. It broadcasts `{:takeover, {:took_over, summary}}`
on the `"takeover"` topic and calls `config :alnasl, :after_takeover,
{Module, :function}` when set. That is the seam for reading back the
moves the boards stored while no box was running; nothing is wired to it
here.

How it sits beside board memory (`Alnasl.BoardHistory`, docs/board-memory.md):
the restore is committed and the boards are started (`drive/0`) before the
hook runs, so the restored games are already what each `BoardServer` loads.
A board that connects to the spare and sends its memory (`{:history,
events}`) is held up against the restored game by the existing path, with
no help from the hook. The hook is the place for an explicit "send me your
memory" to boards already connected, once a driver can be asked for it;
today memory arrives only when the driver offers it.

## Pairing and the key

1. In the cloud, the hall's Boxes tab, **Pair a box** (an arbiter): a code
   like `K7P-3QXM`, good for one box and 15 minutes, and a link
   `https://<cloud>/takeover/join/K7P-3QXM`.
2. On the box, **Cloud and spare**, paste the link or type the code (the
   box's admin). A bare code goes to the default cloud
   (`ALNASL_TAKEOVER_SERVER`).

The box sends who it is (a random uid made at pairing, its name, its
version) and gets a key: `<uid>.<32 random bytes>`. The cloud keeps only
its SHA-256 and compares it in constant time. The box keeps it in
`<data dir>/takeover.key`, mode 600, on the data partition. It is never
logged, never shown, never in a page or in the database. **Remove** on the
Boxes tab (the hall's owner) revokes it at once; the box notices at its
next request (401 `revoked`), forgets the hall and the key, and runs on its
own. **Leave the hall** on the box does the same from its side.

A box paired with one hall cannot be paired with another until it is
removed there (403 `elsewhere`).

The keys of the results site, Lichess and the pairing program are not in
the state: a spare does not get them. Connect the spare to the pairing
program once before the tournament.

## The endpoints

All on the cloud, JSON, under `/takeover`. Off (404, nothing read) unless
this Alnasl is a cloud: a server edition, or `ALNASL_TAKEOVER_CLOUD=1`.

| | auth | in | out |
|---|---|---|---|
| `POST /takeover/join/:code` | the code, once | `{uid, name, software}` | `{key, hall, hall_id}`; 410 used or expired, 403 elsewhere, 422 bad uid |
| `POST /takeover/lease` | key | `{action: claim\|standby\|take_over\|release, epoch, queued, role}` | `{granted, why, previous, lease}` or `{lease}` |
| `POST /takeover/events` | key | `{epoch, events: [...]}`, at most 500 | `{acked: seq}` |
| `PUT /takeover/state` | key | `{epoch, state}`, at most 4 MB | `{ok: true}`; 413 too large |
| `GET /takeover/restore?epoch=&after=` | key | | `{state, events, next}`, 1000 a page |

`lease` as a box is told it: `{holder: you|other|none, holder_name, epoch,
live, expires_in_ms, lease_ms}`.

- **Key:** `Authorization: Bearer <key>`, nowhere else (not in the URL,
  not in the body). 401 `key` for an unknown one, 401 `revoked` for a
  removed box.
- **Scope:** the hall is the key's, never a parameter. A box reaches its
  own hall's lease, events and state, and nothing else.
- **Rate:** 240 requests a minute a box (a step every 5 s is 12, plus
  catching up), ten pairing attempts in ten minutes an address (the
  Cloudflare header counts only from the loopback address). 429 with
  `retry-after`.
- **Input:** an event's id must be the box's own uid and its `seq`; kind
  one of the five; data a map, at most 16 KB as JSON; game at most 120
  bytes, serial 64; ply 1 to 9999; time an integer. One bad event refuses
  the batch (422). Payloads are stored and returned as JSON data and are
  never rendered as HTML.
- **Escalation:** 409 `stale` with the lease for any write with the wrong
  epoch.

## Failure cases

| What happens | What the boxes do |
|---|---|
| The line goes down at the active box | It runs the hall, queues, says "Offline, N events queued"; catches up in order when the line is back. The spare sees the lease run out after 45 s and, with "Take over by itself" on, takes the hall: the active box steps down at its next word with the cloud |
| The active box dies | 45 s later the spare takes over with everything the cloud had. Moves made after the last event that reached the cloud are on the boards |
| The cloud is down | The active box runs the hall and queues; the spare waits (it cannot take over without the lease). Nobody takes over until the cloud is back |
| The hall's internet is unreliable | Two boxes may run the hall for a while: the active one offline, the spare that took over. The active one steps down when it comes back. Untick "Take over by itself" on the spare in such a hall and press Take over by hand |
| Two spares | The first to claim wins (one transaction); the other stays a spare |
| A takeover cannot write the hall here | The restore is one transaction: nothing is written, the lease is released, the box stays a spare and says why |
| The queue fills | See the cap above |
| A key leaks | Remove the box on the Boxes tab; pair it again |

## What the image must set

On the box (the Pi image), in the service's environment:

| variable | value | default |
|---|---|---|
| `ALNASL_TAKEOVER_ROLE` | `active` or `spare` - the role a box takes **when it is paired**. After that the box's own record decides, so a spare that took over stays active across reboots | `active` |
| `ALNASL_TAKEOVER_SERVER` | the cloud a bare pairing code goes to (a pasted link names its own) | `https://alnasl.zerotwo.cloud` |
| `ALNASL_TAKEOVER_QUEUE_CAP` | events kept while offline | `50000` |

The key file lands in the data directory (`<data dir>/takeover.key`); the
data directory must be on the persistent data partition, which it already
is for the database. Nothing listens for takeover on the box: it only
calls out, HTTPS to the cloud on port 443. No inbound port, no VPN.

On the cloud: nothing if it is a server edition (`ALNASL_NO_LOCAL_BOARDS`);
`ALNASL_TAKEOVER_CLOUD=1` otherwise. `ALNASL_TAKEOVER_LEASE_SECONDS` (at
least 15, default 45) sets the silence after which a spare may take over.
The `/takeover/*` paths must reach Alnasl through the tunnel without an
interactive login in front of them (they authenticate per box); the
`/halls` pages stay behind whatever protects them.

## What needs two real Pis

The tests run a box and its cloud in one process (Req's `plug:` option
into the real endpoint, one database). That checks the protocol, the
fencing, the queue, the restore and the pages. It does not check:

- the boards moving: unplugging the DGT boards from the dead box,
  plugging them into the spare after it took over, and the serial-number
  match finding each its table and game on new ports;
- a real power cut mid-write: that the queue on the SD card survives and
  goes out in order (the SQLite settings say it does; a Pi has not);
- real network failure: a cable pulled at the active box, the spare
  taking over at 45 s, the active one stepping down when the cable is
  back, and nothing double-sent to the results site or OpenPairings
  meanwhile;
- the timings on a Pi under a full hall: a step every 5 s with the boards
  running, a restore of a long day (thousands of events) and how long the
  hall is without a box during it;
- the image setting `ALNASL_TAKEOVER_ROLE=spare` and the key surviving an
  OS update on the data partition;
- the cloud behind its tunnel (Cloudflare in front of `/takeover/*`).
