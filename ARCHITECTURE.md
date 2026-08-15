# Architecture

Peloton is a macOS / iOS app that syncs its data across devices through a
shared folder (iCloud Drive), with no server and no account.

This document explains **how** and, above all, **why**. It reads in ten
minutes and should be enough to start working on the project.

---

## Split into two halves

```
Peloton/Peloton/
├── duel-crpe-2027.html      ← ALL the domain logic (~2,900 lines)
├── Sync/                    ← generic synchronization engine
├── Bridge/                  ← the bridge between the two
├── ContentView.swift        ← the window
└── PelotonApp.swift         ← the entry point
```

| | HTML | Swift |
|---|---|---|
| Knows about the CRPE | yes, entirely | **no, nothing at all** |
| Decides what to record | yes | no |
| Stores, merges, writes, reads back | no | yes |
| Changes when a feature is added | yes | **never** |

The Swift side carries "facts" whose meaning it never learns. That is what
makes it possible to add a feature without ever opening Xcode: you add a fact
type to the HTML projection, you emit it, and you are done.

---

## The principle: facts, not state

The app **never** saves "here is my data". It records
**"here is what happened"**:

```
session recorded · chapter turned green · exam date changed · session deleted
```

The displayed state is always recomputed from that list:

```
state = project(journal)
```

`project()` (in the HTML, *STATE* section) is a **pure function**: same
journal ⇒ same state, everywhere, whatever order the files arrive in.

> **Absolute rule:** `state` is never modified by hand. To change something,
> you write `Peloton.record(type, data)`. There is no other way, and that is
> what makes the whole thing predictable.

### Why this removes bugs rather than moving them around

Merging two devices = **taking the union of two sets of facts**. That
operation is commutative, associative and idempotent. So there is nothing to
arbitrate, nothing to choose, nothing to overwrite — and so nothing to lose.

The old version did the opposite: "the most recent save wins". Working the
same evening on two devices made the loser's work disappear entirely.

---

## One file per device

In the shared folder:

```
peloton-a1b2c3d4.json              the Mac's journal
peloton-9f8e7d6c.json              the iPhone's journal
peloton-backup-a1b2c3d4-2026-08-13.json    safety net, 7-day rolling window
peloton-sync.json                  the old format, imported once then inert
```

**A device writes nothing but its own file.** It reads the others, never
modifies them, never deletes them.

Since two devices never write to the same place, iCloud has no conflict to
arbitrate: "conflict copies" (`peloton-sync 2.json`) become **impossible by
construction**. All the code that used to read and then *delete* those copies
— at the risk of losing data if the app crashed in between — is gone.

---

## An order that does not depend on the clock

Every fact carries a logical counter (Lamport): `max(everything I have seen) + 1`.
Two devices whose wall clocks are ten minutes apart still produce a
consistent order.

The total order is `(counter, device, id)` — three criteria, so never an exact
tie, so never any ambiguity. The wall-clock date stays in the file, but
**for display only**.

---

## Local copy first

```
action ─▶ local journal (always, immediate) ─▶ shared folder (best effort)
```

The app keeps a complete copy of the journal outside the iCloud folder
(`Application Support/Peloton/journal.json`). It starts instantly, works
offline, and a failed write to iCloud loses **nothing**: it is a delay, not a
loss.

iCloud is a **means of transport**, not the memory.

The old version had no local copy at all: with no network, or as long as
iCloud had not downloaded the file, the app sat frozen on a waiting screen
with no data at all.

---

## The edge cases, and how they disappear

| Situation | Handling |
|---|---|
| Two devices change the same chapter | the last gesture wins for the status; the edits are merged |
| Two devices create a peloton | the first in the total order wins — everywhere, with no question asked |
| Deletion on one device | a permanent fact, never capped: nothing comes back to life |
| Reset | it is a fact: it propagates, and the projection ignores everything before it |
| Setting changed on both sides | the last one wins — that is what you expect from a setting |
| Import of the old file | ids derived from the content: both devices import it, the facts deduplicate |

What **does not travel** (device-local): the running stopwatch and the
last-opened date. A timer started on the Mac has no reason to run on the
iPhone.

---

## Change detection

Two mechanisms, because neither is reliable on its own:

1. `NSFilePresenter` — the system wakes the app when a file in the folder
   changes. Immediate, but iCloud does not always notify.
2. A poll every 15 seconds, as long as the app is in the foreground.

Measured: under 4 seconds between another device's write and the screen
refreshing.

---

## Adding a feature

Everything happens in `duel-crpe-2027.html`:

1. declare the new fact type in **THE FACT CATALOGUE**;
2. handle it in `project()`;
3. emit it with `await Peloton.record("monFait", {…})`.

The display updates on its own (`onStateChanged`), and so do saving and
syncing. **No line of Swift to write.**

---

## Checking

```bash
node Tests/projection.test.mjs Peloton/Peloton/duel-crpe-2027.html
node Tests/notifications.test.mjs Peloton/Peloton/duel-crpe-2027.html
```

The first one pins down syncing, the second the reminder contract handed to
Swift. See `Tests/README.md`.

---

## Log of traps already hit

These defects were found by exercising the real app, not by re-reading the
code. They are written down here so they do not get reintroduced.

| Trap | What was happening | Guard now in place |
|---|---|---|
| `onStateChanged` did not re-evaluate the home screen | after picking the folder, the app stayed frozen on "Choisir le dossier…" even though everything had worked | `onStateChanged()` calls `openSession()`: the home screen is a **consequence of the state**, never a decision taken once at startup |
| SwiftUI's `.fileImporter` | the folder picker did not open at all on iOS, silently | direct presentation in UIKit / AppKit (`WebBridge.presentFolderPicker`) |
| stale read of `state` | two taps in quick succession on a chapter only advanced it one step | `Peloton.update(build)` serializes calls and invokes `build` only at the last moment |
| response arriving late | a fresh action vanished from the screen until the next sync | revision number (`SyncStatus.revision`); older envelopes are ignored |
| failed save | the user believed their work was safe | red banner + toast, `Peloton.failure` |
| daily backup taken too early | the day's safety copy was frozen at zero facts | we never back up an empty journal |
| facts imported from the old file | published in no file in the folder | `EventLog.publishable(by:)` carries them along with our own |
| poisoned save queue | a single error in one link and **nothing was ever saved again**, without the slightest sign | `Peloton.update` never fails: the whole link is guarded |
| exception coming back from a native call | at startup, the app sat frozen and mute | `Peloton.ask` turns any failure into a message on screen |
| read warning overwritten | a successful publish erased "un fichier n'a pas pu être lu" | the two causes kept apart (`readProblem` / `pushProblem`) |
| daily backup ticked by mistake | a failed write left us with no safety net until the next day | the day is ticked only if the file really exists |
| rejected promises with no owner | failures disappeared silently | `Peloton.tell` for calls with no expected response |
