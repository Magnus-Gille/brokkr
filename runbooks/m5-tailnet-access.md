# M5 tailnet least-privilege staging and recovery

This runbook prepares Brokkr issue #91 without changing a live Tailscale
configuration. Every control-plane mutation below is an owner-attended future
step. Do not apply the policy, change tags, enable or disable approval, approve a
device, or change the M5 host firewall from an unattended session.

The tracked policy is intentionally free of account identities and network
locators. It contains a non-live operator-address marker and role tags for
non-human service machines. `scripts/render-m5-tailnet-policy.mjs` replaces that
marker from an owner-only role-binding manifest and writes a new mode-0600
candidate without printing the address or user binding. Strict JSON is also
valid HuJSON.

The rendered file is a minimal standalone example and a mergeable fragment; if
the tailnet already has policy, merge its `hosts`, `tagOwners`,
`grants`, `tests`, `ssh`, and `sshTests` entries into an owner-only complete
candidate. Never replace unrelated policy blindly. The owner-only merged
candidate, not the tracked template, is the expected input to the drift audit.

Current Tailscale grants are deny-by-default, but a newly created tailnet retains
an allow-all policy until an access policy is defined. The candidate must therefore
contain no wildcard or broad member grant that makes these M5-specific denies
ineffective. Tailscale runs embedded policy tests whenever policy changes and
rejects a change when a test fails.

Primary references:

- [Grant syntax and deny-by-default evaluation](https://tailscale.com/docs/reference/syntax/grants)
- [Policy tags, tests, and SSH tests](https://tailscale.com/docs/reference/syntax/policy-file)
- [Device tags](https://tailscale.com/docs/features/tags)
- [Default allow-all policy warning](https://tailscale.com/docs/reference/examples/acls)
- [Device approval and manual approval](https://tailscale.com/docs/features/access-control/device-management/device-approval)
- [Policy preview, debugging, and rollback](https://tailscale.com/docs/features/tailnet-policy-file/manage-tailnet-policies)
- [Read-only trust-credential scopes and API endpoints](https://tailscale.com/docs/reference/trust-credentials)
- [Current tailnet-settings API schema](https://tailscale.com/api#tag/tailnetsettings)

## Policy roles and paths

The M5 node receives both destination roles:

- `tag:m5-server` for normal OpenSSH and encrypted Samba.
- `tag:m5-inference` for gateway, Whisper, and the model runtime.

Sources receive only the role they require:

- `m5-operator-device` is a private rendered host selector for the exact
  user-authenticated operator workstation address. It reaches TCP 22, 445, and
  8080, but not Whisper or the model runtime.
- `tag:m5-gateway-client` reaches only TCP 8080.
- `tag:m5-whisper-client` reaches only TCP 8092.
- `tag:m5-runtime-client` reaches only TCP 8091.
- Ordinary and guest identities receive no grant. `tag:ordinary-client` and
  `tag:guest-client` exist only to make this denial executable in policy tests;
  do not assign them merely to obtain access.

Do not tag the operator laptop or another end-user device. Tailscale's current
tag guidance says tags are service identities for non-human machines; applying a
tag removes user authentication, and Tailscale explicitly advises against tags
for laptops and phones. The private exact-address binding preserves the laptop's
user identity and uses only the all-plan host-selector policy syntax. Owner
phones may share the user identity, but they have different device addresses and
therefore receive no operator grant. The drift audit binds the rendered address
to the expected stable device and observed user; an address moved to a phone is
drift.

The policy intentionally leaves Tailscale SSH disabled with an empty `ssh`
section and a denial regression. TCP 22 is for the M5 host's existing normal
OpenSSH service. Enabling Tailscale SSH later needs a separate review.

The example ports match the public example currently being prepared in Brokkr
#90: gateway 8080, runtime 8091, and Whisper 8092. Issue #90 owns the host-network
profile. Before #91 is applied, reconcile the accepted #90 profile with these
ports. If the accepted ports differ, update this policy and every allow/deny test
in a separate reviewed commit; do not edit or depend on #90's in-progress
worktree.

## 1. Local validation only

Run the hermetic structural regression from this checkout:

```bash
bash scripts/test/m5-tailnet-policy.test.sh
```

This proves the tracked policy has the exact role-to-port matrix, wildcard-free
grants, default-deny ordinary/guest cases, and a Tailscale SSH denial. It does not
prove the live control plane matches.

Create a mode-0600, current-user-owned, regular, non-symlink role-binding
manifest. It contains one binding per allowed device. Each binding records a
stable API device identifier, identity kind, exact roles, and exact managed tags.
The operator binding also records the API's observed user value and one exact
operator address. The five service roles each occur exactly once; the M5 server
and inference roles must resolve to the same device. Keep this file outside the
repository.

Render the public template without exposing the binding:

```bash
node scripts/render-m5-tailnet-policy.mjs \
  --template network/tailscale/m5-policy.example.json \
  --bindings /absolute/owner-only/role-bindings.json \
  --output /absolute/owner-only/rendered-m5-policy.json
```

The renderer refuses a loose-mode, wrong-owner, or symlinked binding and refuses
to overwrite an output. Merge the rendered entries with the current complete
policy, preserving unrelated least-privilege rules and tests. Keep the final
complete candidate mode 0600.
Review every existing grant: because grants combine as a union, a broader grant
can still authorize an M5 path even when this fragment is narrow. Store the
candidate and the prior complete policy in an owner-only mode-0600 directory.
Record their cryptographic digests, never their contents, in public evidence.

Use the admin console policy editor's preview and the official
`POST /api/v2/tailnet/:tailnet/acl/validate` endpoint to validate the complete
candidate without applying it. Confirm every embedded test passes. This API
validation cannot happen from the public template because its private operator
selector is deliberately absent, and it was not run in this unattended session.
A successful owner-attended validation receipt is a mandatory live acceptance
gate, not authorization to apply.

## 2. Prepare an owner-attended recovery window

Do not start without all of the following:

1. Physical-console access to M5 and a verified local login.
2. Two independent, currently working admin-console sessions.
3. The exact prior complete policy stored owner-only and its digest recorded.
4. The Configuration logs page open to the current policy revision.
5. The operator workstation, each required service client, one ordinary phone,
   and one guest/shared test identity available for probes.
6. The reviewed role-binding manifest. It maps every managed source role to its
   stable device and maps the M5 node to both destination roles. No managed role
   tag may appear on an unbound device.

Do not create an automatic approval webhook or a reusable pre-approved key for
this rollout. Recovery remains a manual identity-verification path.

## 3. Stage approval, tags, then policy

With the owner present:

1. Enable device approval in the admin console. Verify a newly joining test
   device remains in the approval queue and cannot send or receive tailnet
   traffic. Do not approve it for this test.
2. Review each existing device in the admin console. Approve only the devices
   mapped in the owner-only plan. Assign both M5 destination tags and only the
   required source tag to each non-human service client. Ordinary phones and
   guests stay untagged.
3. Keep the operator workstation user-authenticated. Match its stable identifier,
   observed user, and exact address against the reviewed binding and rendered
   host selector. Prove no owner's phone or guest has that address. If the
   address changed, stop and render, review, and validate a new candidate before
   continuing.
4. Re-run policy validation against the owner-only complete candidate after tag
   assignment. Confirm all built-in tests pass.
5. Apply the complete candidate from the admin console. Keep the old policy,
   both console sessions, and the M5 physical console open.

Stop and restore the prior policy immediately if validation or any required
allowed probe fails. Do not add a wildcard, broaden to `autogroup:member`, or
disable device approval to make a probe pass.

## 4. Probe every allowed and denied path

From a fresh session on the exactly bound, user-authenticated operator
workstation, prove normal OpenSSH, authenticated SMB over TCP 445, and the
gateway on TCP 8080 work. Prove direct Whisper and runtime connections fail.

From each tagged service identity, prove its one permitted endpoint works and
that SSH, Samba, and the other inference endpoints fail. From the ordinary phone
and guest/shared identity, prove all five endpoints fail. A TSMP ping does not
exercise access policy; use ICMP or real TCP probes as described in the official
policy debugging documentation. Sanitize probe evidence to outcomes and role
names before posting publicly.

Finally, verify the approval queue still contains the deliberately unapproved
test device and that it remains unable to exchange tailnet traffic. Remove that
test device after evidence capture; do not approve it merely to clean the queue.

## 5. Read-only drift audit

`scripts/m5-tailnet-drift-audit.mjs` reads complete policy, settings, and devices.
It compares every managed role tag to the exact stable-device binding and binds
the rendered operator address to the expected stable device and API user value.
A role or address moved to another device is drift even when aggregate counts are
unchanged. It emits only booleans and the aggregate pending-approval count. It
never emits response bodies, stable identifiers, tags, account identities,
network locators, or request URLs.

Use a short-lived trust credential restricted to the official read scopes:
`policy_file:read` plus its documented prerequisite read scopes,
`devices:core:read`, and `feature_settings:read`. Do not use a full-access API
credential. Acquire the
bearer value through the owner's approved credential flow and keep both it and
the tailnet identifier out of shell history and files.

```bash
read -r -p "Tailnet identifier: " TAILSCALE_TAILNET
read -r -s -p "Short-lived read credential: " TAILSCALE_API_TOKEN
printf '\n'
export TAILSCALE_TAILNET TAILSCALE_API_TOKEN
node scripts/m5-tailnet-drift-audit.mjs \
  --expected-policy /absolute/owner-only/complete-policy.json \
  --expected-bindings /absolute/owner-only/role-bindings.json \
  --live
status=$?
unset TAILSCALE_API_TOKEN TAILSCALE_TAILNET
exit "$status"
```

Outcomes are `pass` (exit 0), `drift` (exit 2), `attention` for pending approvals
only (exit 3), or a sanitized `error` (exit 1). `drift` covers policy mismatch,
device approval disabled, or any exact role/user/address binding mismatch. No
public evidence should include raw audit inputs.

For offline regression or an owner-only captured review, provide
`--observed-policy`, `--observed-settings`, and `--observed-devices` instead of
`--live`. The expected policy, role bindings, and
all observed inputs must be current-user-owned regular non-symlinks with exact
mode 0600; the auditor rejects anything else. Only the sanitized JSON result is
shareable.

## 6. Rollback and emergency recovery

For a policy failure, restore the exact prior complete policy from the open admin
session or use the Configuration logs rollback documented by Tailscale. Verify
its digest and re-run the former known-good probes. Keep device approval enabled,
keep the reviewed service role tags, and keep the operator's user identity. An
operator-selector change is reversed only from the exact owner-only snapshot. Removing the
policy restriction and disabling approval at the same time destroys the safety
boundary and the evidence needed to diagnose.

If remote access is lost, use the physical M5 console and an existing verified
admin-console session. A replacement recovery client must join normally, remain
blocked for approval, and be manually approved only after the owner verifies its
identity. Keep an end-user recovery client user-authenticated; never tag it. A
temporary exact-address binding needs the same stable-identifier and identity
review, and it must be removed after the incident. Never recover by adding an allow-all
rule, using an unreviewed shared identity, creating a reusable pre-approved key,
or disabling device approval.

Disabling device approval is a separate owner decision, not an automatic
rollback step. If the owner explicitly chooses it, record the reason and the
re-enable plan in owner-only incident evidence.
