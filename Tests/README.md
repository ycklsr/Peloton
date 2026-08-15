# Checks

```bash
node Tests/projection.test.mjs Peloton/Peloton/duel-crpe-2027.html
node Tests/notifications.test.mjs Peloton/Peloton/duel-crpe-2027.html
```

Both tests load the **real** HTML file (not a copy) and exit with code 1 as
soon as one line goes red.

## `projection.test.mjs` — synchronization

The properties the whole synchronization rests on:

- **convergence** — the order in which files arrive makes no difference;
- **idempotence** — merging an already known log again changes nothing;
- **no loss** — work done in parallel on two devices survives;
- **deletions are final** — nothing comes back;
- **reset** — it propagates, and old facts stay without effect;
- **picking the old file back up** — two devices importing it each on their
  own side produce identical facts, hence no duplicates.

## `notifications.test.mjs` — the contract with Swift

The page computes the reminder plan, Swift schedules it. Between the two sits
a contract nothing calls to order: Swift **silently** discards any reminder it
cannot read back. This test holds that contract:

- **the shape** — each reminder is exactly `{ at, title, body }`, with `at` in
  the `yyyy-MM-dd'T'HH:mm` format, the only one the scheduler's
  `DateFormatter` accepts;
- **the bounds** — plan sorted, capped at 60 (iOS keeps only 64 per app),
  never beyond the requested horizon, never after the written exams date;
- **the promise** — the rivals' sessions feed the plan, and the end of the
  horizon gives one last alert instead of silence;
- **determinism** — the plan is scheduled again on every action and every
  launch: replaying it must not make it drift.

The test log is dated **relative to today**, never hard-coded:
`buildNotifPlan` reads the real clock, so frozen dates would stop proving
anything the day they fell into the past.

## What these tests do not cover

They stop at the edge of the HTML. Crossing the bridge (`WebBridge`), the
scheduling of reminders by `NotificationScheduler` and the system's own
behavior are checked by running the app — on the iOS simulator, pending
reminders can be read in `PendingNotifications.plist`, under the device
container.

If one of these lines goes red, it is a core promise of the system that is
broken — not a display detail.
