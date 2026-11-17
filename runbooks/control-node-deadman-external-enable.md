# Enable and drill the external dead-man heartbeat

Owner-attended runbook for BROKKR-97. It sequences the steps already implemented and documented in
[`docs/control-node-deadman.md`](../docs/control-node-deadman.md); it adds no new mechanism. Run it
yourself on the monitoring host, as its service user (never root). Nothing here should be run
unattended.

**Never** paste the heartbeat URL into a shell command, ticket, commit, chat or transcript. Edit it
in an editor only. Record metadata only (revisions, timestamps, booleans).

## 0. Preconditions (read-only)

```bash
cd ~/repos/brokkr
git fetch origin && git status -sb          # clean checkout
git rev-parse HEAD                          # note the accepted 40-char SHA
systemctl --user list-timers brokkr-control-node-deadman.timer
stat -c '%a %U' ~/.config/grimnir/notify.env   # expect 600 <you>
ls ~/.config/grimnir/deadman-external.env 2>&1 # expect: No such file (not provisioned yet)
```

Record the SHA and the current timer enabled/active state: that is the rollback baseline.

## 1. Provision the provider check (provider UI)

Create one missed-ping monitor:

- accepts unauthenticated GET on its secret HTTPS URL;
- period 1 minute, grace of at least 5 minutes;
- alerts through a channel independent of the home site, tailnet, control node and the local
  Telegram path (email, provider push or SMS);
- URL can be rotated.

Create a **second, disposable** check with the same notification integration for the drill in
step 5. Do not copy either URL anywhere except the file in step 2.

## 2. Install the protected env file

```bash
cd ~/repos/brokkr
install -m 0600 scripts/lib/deadman-external.env.example ~/.config/grimnir/deadman-external.env
${EDITOR:-vi} ~/.config/grimnir/deadman-external.env   # one line, the production URL only
stat -c '%a %U' ~/.config/grimnir/deadman-external.env  # expect 600 <you>
```

## 3. Deploy through the guarded installer

```bash
./scripts/deploy-control-node-deadman.sh
```

It refuses to change units unless every gate passes (host, notify.env, target probe, env file,
user manager, direct provider 2xx) and restores the snapshot on any failure. Re-running is safe.

## 4. Verify (no URL printed)

```bash
systemctl --user list-timers brokkr-control-node-deadman.timer
systemctl --user is-enabled brokkr-control-node-deadman.timer
systemctl --user start brokkr-control-node-deadman.service
cat ~/.local/state/brokkr/control-node-deadman/state              # expect pass
test -s ~/.local/state/brokkr/control-node-deadman/last-external-success && echo external-ok
journalctl --user -u brokkr-control-node-deadman.service -n 20 --no-pager
```

In the provider UI, confirm pings arrive about once per minute (note the last-ping time only).
Wait 10 minutes and confirm the check stays up with no flapping.

## 5. Missed-ping drill (disposable check only)

Do not pause or blackhole the production timer or URL.

1. Use the provider's built-in test notification on the production check, if it has one.
2. Otherwise let the **disposable** check lapse (no pings) through its period and grace; confirm
   the down notification arrives through the independent channel.
3. Send one ping to the disposable check by the provider's own UI/test feature; confirm exactly one
   recovery notification and no repeat storm.
4. Delete the disposable check.

## 6. Local alert-path drill (isolated state)

```bash
cd ~/repos/brokkr
./scripts/control-node-deadman-acceptance-drill.sh --confirm-live-alerts
```

Confirm you received three Telegram messages: threshold alert, recovery, and the
Ratatoskr-blackhole/direct-fallback message. The receipt records them as `attempted`; your
confirmation is the delivery evidence. The helper leaves the production timer untouched and ends
with `provider_missed_window_drill=required` (satisfied by step 5).

## 7. Evidence to record on BROKKR-97 (metadata only)

- brokkr revision (40-char SHA) deployed;
- timer enabled/active before and after;
- `state=pass` and the `last-external-success` timestamp;
- provider: last-ping time, test/lapse down time, recovery time, count of notifications;
- helper receipt and your three delivery booleans;
- final production timer state (enabled, active).

No URL, check UUID, project key, chat ID or credential.

## Rollback

To restore the prior configuration exactly:

```bash
systemctl --user disable --now brokkr-control-node-deadman.timer   # only if it was disabled before step 3
rm ~/.config/grimnir/deadman-external.env                          # removes the external leg
./scripts/deploy-control-node-deadman.sh                           # reinstalls units without the leg
```

If the installer itself fails mid-run it restores its snapshot and, if rollback is incomplete,
keeps a mode-0700 recovery directory and prints its path: preserve it and inspect before
retrying. Rotate the URL in the provider if you suspect it was exposed.
