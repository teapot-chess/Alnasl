# A spare box

A box in a hall is a small computer, and small computers die: a power supply, a memory card, a cup of coffee. This chapter is about keeping a copy of the hall in the cloud while the box runs, and a second box beside it that takes over with that copy when the first one stops.

## A spare box {#a-spare-box}

Two boxes, one hall in the cloud:

- the **active** box reads the boards, as it always did, and sends every move, clock time and result to its hall in the cloud as it happens. It does not need the cloud to run the hall: without a line it carries on and keeps what it could not send;
- the **spare** stands by. It reads no boards and sends nothing. It only asks the cloud, every few seconds, whether the active box is still there.

When the active box has been silent for longer than the cloud allows (45 seconds unless the cloud says otherwise), or when somebody presses **Take over**, the spare copies the hall from the cloud - the tournaments, the round, which board plays which game, and every move up to the last one the active box sent - and runs it. Plug the boards into the spare when it takes over: a board is recognised by its serial number, so it gets its own table and game back on whatever port it lands.

Moves played while no box was running are in the boards themselves; reading them back is part of what happens after a takeover.

The cloud is a backup and the place where the hand-over happens, not a second hall. Only one box runs a hall at a time.

## Pairing a box with a hall {#pairing}

1. In the cloud, open the hall, then its **Boxes** tab, and press **Pair a box**. It shows a code and a link, good for one box and fifteen minutes.
2. On the box, open **Cloud and spare** (in the menu, under Manage), paste the link or type the code, and press **Pair**.

The box fetches its own key and keeps it in its data folder. Nobody sees it, types it or copies it. A box paired this way starts as the active box, unless it was set up to start as a spare. Pair the box that runs the hall first, then the spare the same way; on the spare, press **Make this box a spare** if it did not start as one.

Pairing needs the box's admin. Pairing in the cloud and **Take over** need an arbiter of the hall; removing a box needs its owner.

## What the status line says {#status}

A paired box says in the bar at the top of every page how it stands:

- **Streaming to the cloud** - all is well;
- **Offline, 23 events queued** - the line is down. The box keeps running the hall and sends what waits, in order, when the line is back. The queue survives a restart;
- **Queue full** - the box has queued as much as it will (50,000 events). Nothing is lost on the box itself; when the line is back it sends its whole state once instead of every event it missed;
- **Standing by as a spare** - this is the spare;
- **Another box took over** - see below.

## Taking over {#taking-over}

On the spare, **Cloud and spare**, **Take over**. Or in the cloud, the hall's **Boxes** tab, **Take over** beside the spare. Either way the spare gets the hall at once, copies it, and starts. The box that ran the hall before is told at its next word with the cloud, and stops.

A spare takes over by itself when the active box has been silent too long. If the active box is only cut off from the internet and still running the hall, that is two boxes for one hall for a while; untick **Take over by itself** on the spare when the hall's internet is unreliable, and press Take over by hand when the box has really died.

What the spare does not get from the cloud: the keys to the results site, Lichess and the pairing program. Those stay on the box they were given to. Connect the spare to the pairing program once, before the tournament, so that results go on arriving after a takeover.

## Another box took over {#superseded}

A box that finds another box running its hall stops: it reads no boards, sends no results, and says **Another box took over**. That holds even when it comes back after a long time without a line, with moves it never sent: the hall has moved on without it, and two boxes writing one hall is worse than one box missing some moves.

It offers one thing: **Stand by as a spare**. Then it is the spare of the box that took over.

## Leaving {#leaving}

**Leave the hall** on the box forgets the cloud and the key; the box runs its hall on its own, as before it was paired. **Remove** on the hall's Boxes tab in the cloud does the same from the other side: the key stops working at once, and the box notices at its next word.
