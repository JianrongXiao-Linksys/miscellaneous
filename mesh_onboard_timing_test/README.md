# Mesh onboarding timing test

Measures, repeatably, how long a Pinnacle 2.0 (OpenWrt ED6) agent takes to go from "BLE
onboard command received" to "can actually reach the controller and the internet" — and where
that time goes.

The number this produces is comparable between firmware builds, which is the point. It is not
"did onboarding succeed" (the controller will tell you that, optimistically); it is "how long
until the node is useful, measured from the node itself".

## Topology

```
                     ┌──────────────────────┐
                     │   Linux test host    │
                     │                      │
     192.168.1.254 ──┤ NIC A (USB ethernet) │
                     │ "Wired connection 2" │
     192.168.1.9   ──┤ NIC B (USB ethernet) │
                     │ "Wired connection 3" │
                     └──────────────────────┘
                         │              │
                         │              │
              ┌──────────▼───┐   ┌──────▼────────┐
              │  CONTROLLER  │   │     AGENT     │
              │ LAN port     │   │ LAN port      │
              │ 192.168.1.1  │   │ 192.168.1.1   │  ← while UNCONFIGURED
              │ 74:12:13:    │   │ 192.168.1.111 │  ← once onboarded (DHCP)
              │   21:53:88   │   │ 74:12:13:     │
              │              │   │   21:55:e6    │
              │ WAN ─► internet   │             │
              └──────────────┘   └───────────────┘
                      ▲                   │
                      └───── 5 GHz wireless backhaul (bhsta1)
```

- **NIC A** is cabled to a LAN port on the controller. **NIC B** is cabled to a LAN port on the
  agent. Neither NIC talks to both nodes; that separation is what makes the run deterministic.
- The controller has the WAN uplink. The agent reaches the internet only through the mesh
  backhaul, which is exactly what the test is measuring.

### The 192.168.1.1 collision — read this before running anything

An **unconfigured** agent serves `192.168.1.1`, and so does the controller. With both NICs up on
the same `/24`, "192.168.1.1" resolves to whichever node wins the ARP race — which changes
between runs. A factory reset issued against the wrong one costs you the controller.

Two mitigations, both built into the script and both required:

1. **One NIC at a time.** `onboard-timing-test.sh nic ctrl` downs the agent NIC and brings the
   controller NIC up, and vice versa. `nic both` exists but is only safe once the agent holds a
   DHCP lease and is therefore no longer at `.1`.
2. **MAC guard every destructive call.** `uci -q get devinfo.info.hw_mac_addr` is the identity;
   the script refuses to flash or reset unless the box that answers is the one you named.

Two further facts that surprised us on this bench:

- **NetworkManager deactivates a profile when carrier drops.** After a DUT reboot,
  `nmcli connection show --active` can list neither NIC even though both are cabled. The script
  re-`up`s and then prints the actual addresses instead of assuming.
- **Once the agent is onboarded, the whole controller LAN is reachable through it.** So with only
  the agent NIC up, `192.168.1.1` answers as the *controller*. That is not a bug, it is the mesh
  working — but it means the collision is live in both directions.

## Usage

```bash
# Where the host can talk
./onboard-timing-test.sh nic ctrl
./onboard-timing-test.sh nic agent

# Who is actually there (never act on an IP alone)
./onboard-timing-test.sh identify 192.168.1.1
# -> mac=74:12:13:21:53:88 ver=26082216 mode=Multi-AP-Controller-and-Agent uptime=613

# Flash, with the expected MAC as a third argument so a wrong-node flash is impossible
./onboard-timing-test.sh flash /path/FW_Pinnacle2.0_v2.0.1.26082216_release.img \
    192.168.1.111 74:12:13:21:55:e6

# Factory reset (rm -rf /var/config + firstboot), MAC-guarded
./onboard-timing-test.sh reset 192.168.1.111 74:12:13:21:55:e6

# Fire the onboarding trigger on the controller and report its readiness first
./onboard-timing-test.sh trigger

# Harvest the agent and print the timeline for a round that already happened
./onboard-timing-test.sh measure -o /tmp/round-1

# One full round: reset agent -> wait for boot -> trigger -> wait for online -> measure
./onboard-timing-test.sh round -o /tmp/round-1

# N rounds back to back
./onboard-timing-test.sh run -n 5 -o /tmp/soak
```

Everything is env-overridable for a different bench:

| variable | default | meaning |
|---|---|---|
| `CTRL_NIC_CONN` | `Wired connection 2` | NetworkManager profile cabled to the controller |
| `AGENT_NIC_CONN` | `Wired connection 3` | NetworkManager profile cabled to the agent |
| `CTRL_MAC` | `74:12:13:21:53:88` | controller label MAC, lowercase |
| `AGENT_MAC` | `74:12:13:21:55:e6` | agent label MAC, lowercase |
| `CTRL_IP` | `192.168.1.1` | controller LAN address |
| `AGENT_DHCP_IP` | `192.168.1.111` | where the onboarded agent lands |
| `DEADLINE` | `300` | seconds to wait for a round to converge |
| `POLL` | `2` | seconds between convergence probes — this is the only error term in the headline number |
| `POLL_REPORT` | `10` | seconds between progress lines, so a fine `POLL` is not a wall of output |
| `SETTLE_WATCH` | `60` | seconds to keep watching after the agent is reachable, before harvesting |
| `OUTROOT` | `~/code/claude/onboard-tests` | where artefacts go |
| `BACKHAUL_SSID` | unset | if set, redacted out of every harvested file |

## What "onboarded" means here

The bar is the one a user would apply, checked **from the agent**, not from the host:

```
ping 192.168.1.1   # the controller, i.e. the backhaul carries traffic
ping 8.8.8.8       # the internet, i.e. the controller is routing for it
```

A host-side ping proves only that the host's own NIC works. The controller's own
`onboarding::state=done` is also not the bar: it goes `done` while the agent is still bringing
its fronthaul BSSes up.

**The probe reads the agent's own `/proc/uptime` in the same ssh session, right after the pings
answer.** That is what makes the headline comparable with the `[t=NNN.NN]` markers in the log. A
host wall-clock stamp would have to be mapped onto the agent's clock afterwards — and the agent's
clock jumps forward when NTP lands mid-onboard, so that mapping is guesswork on exactly the rounds
that matter. The number is an upper bound by one `POLL` interval plus the ping time, nothing more.

**Reachable is the headline, not the end of the round.** The M2 credentials reach the radio that
carries the bSTA *after* the agent is pingable, and that is where the HT40 legalisation, the
back-out trigger and the post-credential backhaul dip live. So the harness waits `SETTLE_WATCH`
seconds before harvesting. Harvesting on the online edge cut one 26082217 artefact off at `t=211`
and lost a bSTA drop at `t=237`: the saved logs said the round ended clean, and the live log read
minutes later said it had not.

## Reading the clock — three log sources, and why

No single source survives a whole round.

| source | why it is needed |
|---|---|
| `logread` | the live ring. **syslog-ng reloads after NTP sync and restarts the ring**, so the middle of a round silently vanishes from it minutes later. Harvest early. |
| `/tmp/log/messages.1.gz` | the rotated ring — i.e. precisely what `logread` just threw away. |
| `/tmp/wifi-monitor.log` | wifi-monitor's own 128 KB ring, unaffected by syslog rotation, and the only durable record of the backhaul module's decisions. |

**Use the `[t=NNN.NN]` uptime markers, never wall-clock timestamps.** The DUT boots with an
unsynced clock — you will see dates months in the past — and jumps forward mid-onboard when NTP
lands. Sorting by wall clock interleaves lines from before and after the jump into nonsense.
Every Linksys-authored log line on this platform carries `[t=]` for exactly this reason.

Two more busybox traps the script works around:

- `ls --time-style=...` is **not supported**. Use `date -r <file> -u +%s`.
- `pgrep -c` is **not a busybox option**. Use `pgrep -f ... | wc -l`.

## Milestones the timeline reports

| marker | what it means |
|---|---|
| `GATT command received` | **t0.** The agent has the onboard command over BLE. |
| `stopping advertisement, starting WPS-PBC` | BLE handoff begins |
| `triggering WPS-PBC on bhsta1` | WPS actually starts — the gap from t0 is pre-WPS UCI/bridge work |
| `WPS-PBC completed — backhaul connected` | the bSTA has an association |
| `fronthaul credentials persisted to UCI` | the controller's credentials reached UCI |
| `sta-iface-repair ... killing beerocks_agent` | the one-shot `sta_iface` latch is being repaired |
| `replacement beerocks_agent up ... after Ns` | the respawn completed |
| `legalised HT40 ...` | an illegal HT40 pair was corrected before hostapd refused the interface |
| `back-out trigger now holds` | the runtime SSID looked wrong; a repair is pending unless it self-clears |
| `bhsta1 is ... inside the Ns activation grace` | the bSTA went down; wifi-monitor is watching, not acting |
| `backhaul: recovered (was disconnected ~Ns)` | the last backhaul settle — usually the end of the round |

### Do not trust the settle line on its own

`GATT -> last logged backhaul settle` is a *secondary* number and the harness prints a `WARNING`
next to it when it is not trustworthy. wifi-monitor deliberately emits no
`recovered (was disconnected ~Ns)` for a dip that falls inside its 30 s activation grace, because a
reassociate that soon after WPS is measured harmful. On builds where that gap is open, the settle
therefore reads *earlier* than a drop the same log reports a line later. The harness now detects
"an activation-grace dip after the settle" and says so rather than quoting a number that is not one.

Note the converse, which is easy to misread the other way: an activation-grace line **before** the
`WPS-PBC completed` row is just the bSTA scanning before it ever associated. That is not a dip and
gets no warning.

## Secrets

The harvested logs contain plaintext credentials. `beerocks_agent.*.log` prints fronthaul and
bSTA PSKs; `/var/run/hostapd-*.conf` carries `wpa_passphrase`.

- Export `BACKHAUL_SSID` before running and it is replaced with `<backhaul-ssid>` in every
  harvested file.
- `key=` / `passphrase=` / `psk=` / `password=` values are replaced with `<redacted>`
  unconditionally.
- **Do not publish the artefact directories.** Redaction is best-effort; treat the harvest as
  bench-internal and quote only the specific lines you need.

A grep filter caveat worth repeating, because it has bitten us: `grep -vE "key|passphrase|psk"`
also hides `encryption='psk2+aes'`, and a filter anchored `^(wpa|...)` *matches*
`wpa_passphrase=`. Check what your filter removes as well as what it keeps.

## Reference numbers

Two-node bench, 5 GHz backhaul on channel 161, agent factory reset before each round.

| build | GATT → agent online | notes |
|---|---|---|
| 26082215 | 136.9 s | `sta_iface` latch repair cost 41 s; a stale-hostapd reading then armed a back-out repair that cost a further 59 s and three backhaul drops |
| 26082216 | 62.8 s / 64.1 s | latch repair down to ~10 s; back-out repair never fires |
| 26082217 | ≤44 s / ≤35 s | measured with `POLL=10`, hence the `≤`; this is what `POLL=2` and the agent-clocked probe exist to sharpen |

Where the 62–64 s goes on 26082216:

| segment | cost |
|---|---|
| GATT received → WPS-PBC actually starting | ~20 s |
| WPS association | ~9 s |
| credential persist + `sta_iface` latch repair | ~10 s |
| beerocks cold start → `Backhaul Type: Wireless` | ~11 s |
| radio-1 churn as the M2 credentials are applied to the radio carrying the bSTA | ~12 s |

Controller-side BLE scan and connect happens *before* t0 and is not counted in the number above.
Measured separately at 16–36 s, so budget ~80–100 s for a full trigger-to-online cycle.
