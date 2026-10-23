# Link-health fixtures

Synthetic `journalctl -k -o short-unix` and `ethtool` output for
`scripts/test/link-health.test.sh`, observed at epoch 1792497600
(2026-10-20T12:00:00Z). Each scenario has `journal`, `enp1s0.link`
(`ethtool enp1s0`), and `enp1s0.stats` (`ethtool -S enp1s0`).

- `healthy`: 2.5 Gb/s, partner advertises up to 2.5G, no link events.
- `incident-flapping`: reproduces the cable fault's first phase. A ~2 s
  `Link is Down`/`Link is Up` cycle every five minutes for 24 h (288 drops,
  12 in the last hour), each renegotiation logging a PHY downshift from 2.5G to
  1G under the PHY device name, and one older drop outside the window.
- `incident-stable-100`: the second phase. The port settled at 100 Mb/s more
  than 24 h ago, the partner now advertises only 10/100 modes, and the journal
  shows no recent drops. Only the speed check can catch it.
- `volatile-after-reboot`: healthy NIC, but the kernel journal begins two
  hours ago (one drop since). With no record from before the 24 h window the
  count is only a lower bound, so the result must not be OK.

Identifiers (`fixture-node`, PCI address, PHY name) are generic placeholders.
