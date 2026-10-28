# Simple mode, and the compact layout

Status (2026-10-28): built. Code: `AlnaslWeb.Mode`, the frame in
`AlnaslWeb.Layouts`, the compact rules at the end of `assets/css/app.css`
and of `assets/js/theme.js`. Manual: Getting started, "Simple mode and
everything" and "Small screens".

Two independent things. **Simple mode** decides which pages are in the
menu. **Compact** decides how the frame and the live boards are drawn on a
4 to 7 inch screen. A large TV can be in simple mode; a small screen can
show everything.

## Simple mode

The default. It is for somebody running a hall without having been shown
Alnasl: see the boards and the games, connect and check the boards, know
which round is on and that the results go where they go, find the manual,
and get out of the menu.

### What is in

| Page | Why |
| --- | --- |
| Live (`/`, `/round/..`, `/t/..`) and a board's page | The boards and the games, live; the round buttons say which round is on |
| Boards (`/boards`) | Connecting and checking boards: what is plugged in, table numbers, "Ready for round N?" |
| The numbering run (`/boards/number`) | Touch the boards in table order and each gets its number. This is how boards get connected to tables, so it counts as connecting boards even though it lives in the walk module (`WalkLive`); the setup wizard sends people there |
| Halls (`/halls`, its tabs) | On the server boards arrive through bridges, which are a hall's tab; an account in no hall is sent to `/halls` and must find it |
| Setup: wizard, Tournaments, Connections, Updates (a box) | What gets a tournament onto the boards; Updates because the new-version notice links there and a box that cannot update is a support call |
| Cloud and spare (`/spare`, a box) | When the box dies the arbiter needs Take over on the spare, not a switch to find it first; the status line in the bar links there (docs/takeover.md) |
| Help | The manual |
| The frame | Hall picker, account menu (language, colour theme, sign out, the switch), the connection badges, the notices |

"Where the results go" is shown by the badges in the bar (pairing program,
results site) and the offline notice. In simple mode the results badge is a
badge, not a link: the outbox it led to is full mode's.

### What is hidden, and why

| Page | Why it waits for full mode |
| --- | --- |
| Games (`/pgn`) | Reading, attaching and comparing PGN is a repair tool, not part of a round that runs |
| Results (`/outbox`) | The queue, its destinations and switches. The badges already say whether results arrive |
| Log, Recordings | Looking back at what happened, for whoever investigates |
| Finding a board on a phone (`/boards/find`) | The walk through the hall with a phone; the Boards page's own "Show me" stays |
| Fair play (`/fair-play`, `/halls/:id/fair-play`) | Screening is the hall owner's specialist tool. Its owner-only rule (`Alnasl.FairPlay.Access`) is untouched: simple mode only takes it out of the menu, it never lets anybody in |
| Support (`/support`) | For the support admins of a server |
| Setup: Results and Lichess, This box / This server, Access, Advanced | The own hall's results page and Lichess, the box's name and default language, the PIN and hall network, the tracker |
| Theme packs | Installed packs are left out of the colour picker; the six built-in themes stay. A pack chosen earlier keeps working |
| The tour's steps on hidden pages | The tour walks what is in the menu |

Hidden is not removed. Every hidden page still answers its address. In
simple mode the frame draws a calm note instead of the page ("This page is
part of full mode", with the switch and a way back to Live). The page has
mounted behind it; pressing the switch shows it in place, without a reload.
Links inside the pages that would lead straight into a hidden page (the
results badge, "What is waiting" in the offline notice, "Open this on a
phone-sized page" on Boards) are left out in simple mode; links that are
the next step of a plan (a wizard step that needs Results and Lichess)
stay, and lead to the note.

Simple mode is about what is shown, not about who may do what. The roles
(`AlnaslWeb.Permit`) work exactly as before in both modes.

### The switch, and where it is kept

"Show everything": a switch in the account menu, plus a button at the foot
of the rail (and under More on a phone) while simple mode is on, plus the
one on the note. All send the same event, `ui_mode`, which anybody who has
the page may send (it is a personal choice, like the tour).

The settings model already had the shape for this: the guided tour keeps
its state on the account (`users.tour`) and, on a box without accounts, in
the settings. Simple mode does the same:

- **With accounts:** on the account (`users.ui_mode`), so each person has
  their own. Arbiters setting up and a viewer following the games want
  different things on the same server. An account that never chose has
  `nil` and follows the installation.
- **Without accounts (a box in open mode):** the installation's setting
  (`settings.ui_mode`). Such a box cannot tell people apart, and the kiosk
  and the arbiter's laptop are the same hall; the open pages follow a
  change at once.

Per hall was considered and rejected: a hall is a place, not a person, and
the same person moves between halls with the hall picker; their menu
should not change under them when they do.

### Upgrades: new installs simple, existing ones keep everything

The migration `ui_mode` writes `settings.ui_mode = "full"` when the
database was already in use (it has an account, a board, a game or any
setting), and writes nothing on a fresh database, where the default
("simple") counts. So:

- a new box, or a new server, starts in simple mode;
- a hall that has been using the full UI keeps every page after the
  update, menu included. Losing half the menu overnight, an hour before a
  round, is not a feature;
- accounts on an existing server follow the installation, so they keep
  full mode too, until someone switches.

A box that was installed but never used counts as new. It had nothing to
lose.

## Compact layout

For 4 to 7 inch screens: 800x480 (the official Pi DSI panels), 1024x600,
720x720. A layout of the same pages, not another app.

### When it is on

`data-compact` on `<html>`, set by `assets/js/theme.js` before the first
paint, like the colour theme. Automatic: the window is at most 620 px high,
or at most 760 by 760 and not portrait (720x720 squares, not phones). On a
phone held upright nothing changes; turned sideways it is compact, which
is what that shape needs too.

The size of the window cannot tell a 7-inch panel with 1920x1200 pixels
from a monitor, so the account menu has **Screen: Automatic / Small screen
/ Large screen**, kept in that browser (`localStorage`), because it is
about that screen. The box's kiosk also has its own scale setting; the
two together cover a panel at any density.

### What it changes

- One bar along the top: the places on the left (Live, Boards, Results in
  full mode, More), the hall picker and the account button on the right.
  No rail, no bottom bar, no brand. Every tap target is at least 44 px.
- The page header is one tight line; the latency number and the "Live
  boards" link text go.
- Live: tiles of 14rem minimum, so 3 columns at 800 px, 4 at 1024, 3 at
  720; each tile keeps the board number, its state, the players, the
  clocks and the last move or result, and drops the position diagram and
  the reconstruction marks (the board's own page has both). The counts by
  state go; the list view drops the clock column and gets 44 px rows.
- Text: 16 px body, 16 px names and clocks, 26 px board numbers, for a 5"
  screen at arm's length.

The frame fits the screen. With more boards than fit, the tiles scroll
under the bar; with dozens, the list view (one 44 px row per board) shows
the most.

### Not done

- The other pages (Setup, Halls, a game) get the frame and the larger
  targets but no layout of their own; they scroll as on a phone.
- The guided tour's pop-ups are positioned for the desktop frame.
