# Tailscale authentication recovery for an unattended host

This owner-attended runbook restores an explicitly identified Linux host whose
local Tailscale client reports `NeedsLogin`. It also makes node-key expiry a
declared, monitored policy. Keep live hostnames, addresses, account identifiers,
authentication URLs, and credentials in the protected operator record, not in
this repository.

Tailscale documents that an expired node key stops connections and that
`tailscale up --force-reauth` can drop the very Tailscale connection used to run
it. Do not start recovery through a Tailscale-only SSH session. Establish and
test a separate LAN or console path first, and keep it open throughout the
ceremony.

## 1. Confirm the target and failure mode

From the tested fallback session, confirm the host's local identity using the
owner inventory. Then collect a sanitized status that does not print the DNS
name, addresses, authentication URL, or tailnet identifier:

```bash
sudo tailscale status --json | python3 -c '
import json, sys
s = json.load(sys.stdin)
self_status = s.get("Self") if isinstance(s.get("Self"), dict) else {}
print("backend=" + str(s.get("BackendState")))
print("online=" + str(self_status.get("Online") is True).lower())
print("has_current_identity=" + str(bool(s.get("TailscaleIPs"))).lower())
print("expired=" + str(self_status.get("Expired") is True).lower())
print("expiry_observable=" + str(bool(self_status.get("KeyExpiry"))).lower())
'
```

Continue only if the exact owner-approved host still reports
`backend=NeedsLogin`. A different state is a new diagnosis; do not force an
unnecessary authentication cycle.

## 2. Reauthenticate interactively

Run the documented recovery command from the fallback session:

```bash
sudo tailscale up --force-reauth
```

Open the generated authentication URL only in the owner's normal trusted
browser session and complete the expected identity-provider flow. Never paste
the URL into a ticket, chat, shell history note, or tracked file. If device
approval is enabled, complete that approval in the Tailscale admin console.

If the host cannot authenticate, stop with fallback access intact. Do not log
out, delete local Tailscale state, replace the machine, or use an auth key as an
unreviewed shortcut.

## 3. Verify the restored identity

Run the sanitized status command from step 1 again. It must report:

```text
backend=Running
online=true
has_current_identity=true
expired=false
```

Privately compare `Self.DNSName` with the owner inventory. Do not copy either
value into this repository. Then run the Brokkr check through the installed
health unit and confirm a fresh successful push reaches Heimdall:

```bash
sudo systemctl start brokkr-health.service
sudo systemctl status brokkr-health.service --no-pager
sudo journalctl -u brokkr-health.service -n 20 --no-pager
```

The `tailscale-auth` row must be `pass` or an expected policy `warn`; Heimdall
must show fresh NAS telemetry and Online state. A local pass without a fresh
remote observation is not delivery evidence.

## 4. Choose and record the expiry policy

Make one explicit security decision for this unattended host:

- `monitored`: retain node-key expiry. Brokkr warns through the normal 15-minute
  health snapshot before the key expires (14 days by default). The protected
  runtime environment must set
  `BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=monitored`.
- `disabled`: after reviewing the host's physical security, access policy,
  patching, and decommissioning path, use the Tailscale admin console's
  **Disable Key Expiry** action for this machine. The protected runtime
  environment must set
  `BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=disabled`. Brokkr warns if a future expiry
  later appears, exposing policy drift.

In both cases, store the current private `Self.DNSName` only in the protected
runtime source as `BROKKR_TAILSCALE_EXPECTED_DNS_NAME`. The NAS deployment
accepts these assignments alongside the existing Heimdall values:

```text
HEIMDALL_HUB_URL=https://heimdall.example/api/panels
HEIMDALL_FLEET_TOKEN=replace-with-protected-runtime-value
BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=monitored
BROKKR_TAILSCALE_EXPECTED_DNS_NAME=nas.example.ts.net
# Optional; default is 1209600 seconds (14 days):
BROKKR_TAILSCALE_EXPIRY_WARN_SECS=1209600
```

The completed source must remain a root-owned, non-symlink regular file with
mode `0400` or `0600`. The deployer validates and copies only the allow-listed
assignments; it never sources or prints the file.

## 5. Verify reboot persistence

During an owner-approved maintenance window, reboot through the normal host
procedure while retaining local recovery access. After the host returns, repeat
steps 1 and 3. Acceptance requires `Running`, Online, a current identity, a
passing Brokkr check, and fresh Heimdall telemetry after that reboot.

If the tailnet identity fails after reboot, preserve the local journal and
Tailscale status in the private incident record. Do not claim recovery from
pre-reboot evidence.

## References

- [Tailscale key expiry and renewal](https://tailscale.com/docs/features/access-control/key-expiry)
- [Tailscale auth keys and node-key expiry](https://tailscale.com/docs/features/access-control/auth-keys)
