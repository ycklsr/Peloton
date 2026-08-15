# Peloton CRPE 2027 — native macOS Tahoe + iOS 26 installation

Three files are needed: `PelotonApp.swift`, `ContentView.swift` (provided alongside)
and your latest version of `duel-crpe-2027.html`.

> **A note on languages.** This guide is in English, and so are the macOS and
> iOS menus quoted here — adjust if your system runs in another language. The
> app's own interface is in French, since it prepares a French exam: its
> buttons are quoted verbatim, with an English gloss in brackets.

---

## Step 0 — Groundwork (once, ~30 min of downloading)

1. On the Mac: **App Store → Xcode** (free, ~15 GB, set aside some time).
2. Open Xcode once → accept the licence → let it install the components.
   When it offers you platforms, tick **iOS** (the simulators are optional,
   you can untick them to save 8 GB).
3. On the iPhone: plug it into the Mac over USB. If iOS asks for it:
   **Settings → Privacy & Security → Developer Mode → turn it on**
   (the iPhone restarts). That setting sometimes only shows up after the
   first launch attempt from Xcode — come back to it at step 8 if needed.

## Step 1 — Create the project (5 min)

4. Xcode → **File → New → Project…** → **Multiplatform** tab → **App** → Next.
   - Product Name: `Peloton`
   - Team: *None* for now
   - Organization Identifier: `fr.yannick.crpe2027` (a unique bundle from the
     very start — **you will NEVER change this identifier afterwards**: your data
     (local journal, bookmark for the sync folder) lives in a container keyed
     on it; changing it = starting over from an empty container)
   - Interface: SwiftUI · Language: Swift · Testing: None
   → Next → pick a folder (e.g. `~/Documents/Peloton`) → Create.

5. In the navigator on the left, open `PelotonApp.swift` → **select all,
   delete, paste** the contents of the `PelotonApp.swift` file provided.
   Same for `ContentView.swift`.

6. **Drag `duel-crpe-2027.html`** (your latest version) from the Finder into
   the project navigator, at the same level as the .swift files. In the
   dialog: tick **Copy items if needed** and check that the **Peloton** target
   is ticked → Finish.

7. Click the project (blue icon right at the top) → **Peloton** target →
   **Info** tab → hover over a row, click the **+** and add these two keys
   (they open the app up to Files on iPhone: the Documents folder — where the
   app re-copies `duel-crpe-2027.html` on every launch — becomes visible there, and
   the sync folder is worked on where it lives, with no intermediate copy):
   - `Application supports iTunes file sharing` → **YES**
   - `Supports opening documents in place` → **YES**

7b. **CRUCIAL for sync on the Mac**: **Signing & Capabilities** tab →
   **App Sandbox** section → **File Access → User Selected File** row →
   switch from *Read Only* (Xcode's default) to **Read/Write**. Without it, the
   sync folder is readable but not writable: permanent orange dot.

## Step 2 — Run it on the Mac (2 min)

8. At the top of the Xcode window, to the right of the scheme name, pick the
   **My Mac** destination → **⌘R**.
   - First launch: macOS asks for notification permission → **Allow**.
   - The app asks you to pick the sync folder (see the dedicated section
     further down). It is the only blocking screen, and only this once.
9. **Getting your data back**: it arrives all by itself as soon as the folder
   is picked — including an old `peloton-sync.json`, converted
   automatically. Nothing to import by hand.
10. Installing it properly: **Product → Show Build Folder in Finder** →
    `Products/Debug/Peloton.app` → drag it into **Applications**.
    No Apple account needed on the Mac.

## Step 3 — Run it on the iPhone (10 min the first time)

11. Xcode → **Settings → Accounts → +** → add your Apple ID (free).
12. Project → Peloton target → **Signing & Capabilities** →
    Team: **<your name> (Personal Team)** → Xcode generates the signature.
    If the identifier is refused (already taken), pick another one **now,
    before you have imported any data at all** — never after (cf. step 4:
    the data container is keyed on it). It is also why the import in
    step 9 is ideally done AFTER this signature has been accepted.
13. iPhone plugged in → destination **<your iPhone>** → **⌘R**.
    - iOS blocks the first launch: **Settings → General →
      VPN & Device Management → your Apple ID → Trust**.
    - Launch again from Xcode. Allow notifications.
14. Pick the **same** sync folder as on the Mac: your whole
    history arrives within seconds.

## What happens next (the notification contract)

- On **every launch** and **every action** (session, past paper, chapter,
  deletion), the web app calls `pushPlanToNative()` → the Swift side **clears
  every** pending notification and schedules the plan for the next 10
  days (60 max): the rivals' feed (deterministic, cannot be wrong) +
  conditional overtakes (“sauf si tu loggues” — *unless you log a session* —
  true by construction).
- If you don't open the app for 10 days: one last “Le peloton continue
  sans toi” alert (*the peloton rides on without you*), then silence until
  the next launch.
- With the sync folder set up (section further down), Mac and iPhone
  **merge automatically** on every launch. Still keep the habit of having a
  main device for notifications: each device reschedules its own at ITS next
  launch — so the one you don't open can show an “X te double”
  (*X is overtaking you*) that is already stale if you logged something elsewhere in the meantime.
  The device you open most is always right.

## Maintenance

- **Free iOS certificate: expires every 7 days.** The app stops
  launching (the data stays). Plug the iPhone in and run
  `./Tools/install-ios.sh` — it re-signs, reinstalls and relaunches, without
  Xcode being opened. (⌘R from Xcode still works, it is just the long way
  round.) A paid account ($99/year) takes the 7 days up to a year.
- **Updating the web app**: `./Tools/install-mac.sh` on the Mac,
  `./Tools/install-ios.sh` on the iPhone. Both rebuild in Release, install
  over the copy you actually use, and check that the HTML inside the bundle
  is the one in the working tree before declaring success. Your data is never
  in that file, so there is no risk. **Do not drag a build product out of DerivedData into
  `/Applications`**: that is how you end up with two copies (see below),
  and the second one is invisible until it silently serves you a version
  from a fortnight ago.
- **Backups**: the `peloton-backup-<device>-<date>.json` files (rolling
  7 days) are written into the sync folder itself — nothing to export by
  hand, nothing to go looking for elsewhere.

## Automatic Mac ↔ iPhone sync (free, no paid account)

The principle: **each device writes its own file** into a folder YOU
choose (`peloton-a1b2c3d4.json`, `peloton-9f8e7d6c.json`…) and reads the others'.
If that folder is in iCloud Drive (free account), iCloud handles the
transport. No Apple entitlement required — access goes through the system
file picker, which free accounts are allowed to use.

Since two devices never write to the same file, iCloud never has a
conflict to arbitrate: conflict copies (“peloton-sync 2.json”) can no
longer appear.

1. In **Files** (iPhone) or the **Finder** (Mac): create a
   `CRPE-Sync` folder in iCloud Drive.
2. In the app (Mac): on first launch the app asks you for it, otherwise
   the **Plus → Synchronisation → “Choisir le dossier de sync…”** tab
   (*More → Sync → “Choose the sync folder…”*) → select `CRPE-Sync`.
3. Same thing in the iPhone app → select the same folder.
   The iPhone pulls in your whole history; if it had already been working on
   its own, the two histories are **joined** — nothing is lost, ever.
4. Done. From then on everything is automatic, both ways, within
   seconds. “Synchroniser maintenant” (*Sync now*) forces a re-read if you
   want to see it right away.

**Your data does not depend on iCloud.** The app keeps a full copy on
the device: it starts instantly, works on a plane, and a failed
write loses nothing — it picks up again by itself at the next contact. The shared
folder only serves to carry the data across to your other device.

What deliberately **does not sync**: the running stopwatch (a timer
started on the Mac has no reason to run on the iPhone) and the date of the
last launch.

It works with Dropbox or Google Drive too, as long as they show up in
Files.

### Migrating from the old version

If a `peloton-sync.json` (old format) is sitting in the folder, it is
converted automatically on first launch. **Nothing to do.** Both
devices can each do it on their own without creating a duplicate.

### Safety nets

- Each device keeps a dated copy of its own file in the folder,
  over 7 days (`peloton-backup-<device>-YYYY-MM-DD.json`).
- Any anomaly (folder missing, unreadable file, write impossible) is
  shown in a red banner at the top of the app, with the cause — and never
  stops you from working, since the data is on the device.
- **Plus** tab: who contributed to the journal, how many actions, and when.
- “Tout effacer” erases on **every** device: the erasure is
  itself a piece of information, and it propagates.

## Installing the Mac version (and updating it)

```bash
./Tools/install-mac.sh
```

Builds in Release, quits the running copy, replaces
`~/Applications/Peloton.app`, relaunches. Nothing else to do.

**Your data never moves.** It lives in
`~/Library/Containers/fr.yannick.crpe2027.Peloton`, keyed on the app's
identifier and not on its location: moving or replacing the `.app` touches neither
the history, nor the chosen sync folder, nor the scheduled notifications.

⚠️ **One copy, in one folder.** macOS is quite happy to run side by side a
copy in `/Applications`, one in `~/Applications` and the one Xcode produces
with ⌘R. All of them share the same identifier, hence the same device
identity: they would write the same file in the sync folder, the very thing
the whole architecture works to make impossible.

The failure mode is quieter than a conflict, and worse. A second installed
copy is never updated, and nothing says so: you launch your Dock icon, the
app opens, everything works — it is simply not the version you just built.
`install-mac.sh` now refuses to run while two copies are installed, and
names them. To see which one your Dock actually opens:

```bash
defaults read com.apple.dock persistent-apps | grep -o 'file:///[^"]*Peloton[^"]*'
```

## Quick troubleshooting

| Symptom | Fix |
|---|---|
| “Untrusted Developer” on iPhone | Settings → General → VPN & Device Management → Trust |
| Developer Mode missing | Plug the iPhone in, try ⌘R once, the setting shows up |
| No notifications | Settings (OS) → Notifications → Peloton → allow; then reopen the app (the plan is rescheduled on launch) |
| The iPhone app stops launching after a few days | 7-day certificate expired → ⌘R from Xcode |
| Blank screen | The HTML is not in the target: click the file in Xcode → right-hand panel → Target Membership → tick Peloton |
| A change you just made is not in the app | You are launching a second, stale copy. Run `./Tools/install-mac.sh` — it refuses to run while two are installed, and names them |
