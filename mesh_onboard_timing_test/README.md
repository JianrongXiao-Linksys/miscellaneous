# Mesh onboarding timing test

Measures, repeatably, how long a Pinnacle 2.0 (OpenWrt ED6) agent takes to go from "BLE
onboard command received" to "can actually reach the controller and the internet" — and where
that time goes.

The number this produces is comparable between firmware builds, which is the point. It is not
"did onboarding succeed" (the controller will tell you that, optimistically); it is "how long
until the node is useful, measured from the node itself".

**Paused as of 2026-08-22 — see [STATUS.md](STATUS.md)** for the bench state, the open bug (the
bhsta1 supplicant control socket) and where to pick it up.

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

# Compare every fronthaul and backhaul BSS on the agent against the controller
./onboard-timing-test.sh creds -o /tmp/round-1

# Enumerate the agent's VAPs and check them against the six inventory rules
./onboard-timing-test.sh inventory -o /tmp/round-1

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

## The inventory check — the right credentials on the wrong VAP is not a pass

`creds` answers *are the credentials right?* It cannot answer *are they on the interfaces the
product is bound to?*, and on `26082410` round 33 the difference was the whole bug: the agent
reached `OPERATIONAL`, `bhsta1` was `COMPLETED`, every SSID matched the controller — and five AP
BSSes were on the air, because prplMesh had applied radio 1's M2 to two brand-new VAPs
(`wlan1_2`, `wlan1_3`) instead of the existing ones. The GUI, JNAP, TR-181 and WPS are all bound to
the netifd sections, which were still beaconing the factory SSID. See ledger bug 070.

`inventory` enumerates what is actually there — on-air BSSes with their `multi_ap` role and owning
UCI section, the bSTA's supplicant state, the generated hostapd confs, and the UCI AP sections — and
applies six rules. Any violation prints a `PROBLEM:` line and fails the round.

| rule | what it asserts | what it catches |
|---|---|---|
| R1 | every AP BSS is named `phy<n>.<n>-<n>` | a VAP bwl allocated behind netifd's back — the exact 070 signature, since bwl's allocator names them `wlan<radio>_<n>` and nothing else produces either form |
| R2 | exactly one fronthaul BSS per radio | a duplicate fronthaul; both naming forms fold onto the same radio key first, or the duplicate counts as its own radio and the rule is silently satisfied |
| R3 | exactly one backhaul BSS on the node | a second bBSS, or none |
| R4 | exactly one bSTA, in `COMPLETED` | a backhaul that never associated, or a duplicate supplicant interface |
| R5 | one generated conf per radio, `hostapd-phy<n>.<n>.conf` | a conf written for a VAP netifd never asked for |
| R6 | no orphan UCI AP section, and no on-air AP without one | the config-side half of R1, in both directions |

Note that R4 is about the *station*, not a BSS: the bSTA is deliberately excluded from the
firmware's own BSS verdict, because `wireless.bhsta` carries `multi_ap='1'` and is therefore
enumerated as a backhaul section even though its `ifname` is a station interface. Judging it as a
BSS is what made a healthy round-34 node report `incomplete` permanently — same ledger entry, the
regression section.

## What "onboarded" means here

Two bars, and a round has to clear both.

**1. Reachability**, checked **from the agent**, not from the host:

```
ping 192.168.1.1   # the controller, i.e. the backhaul carries traffic
ping 8.8.8.8       # the internet, i.e. the controller is routing for it
```

**2. Credential alignment** — every fronthaul and backhaul BSS on the agent carries the
controller's credential:

```bash
./onboard-timing-test.sh creds            # standalone
./onboard-timing-test.sh creds -o /tmp/x  # also writes x/creds.txt
```
```
role  radio    controller ssid / pskfp     agent ssid / pskfp        verdict
fh    phy00.0  Linksys00003 / f2af139e     Linksys2155E6 / 9d6e4d26  MISMATCH: ssid, psk
fh    phy00.1  Linksys00003 / f2af139e     Linksys2155E6 / 9d6e4d26  MISMATCH: ssid, psk
bh    phy00.1  <backhaul-ssid> / 5a84fa69  O3sNB...k0F / c6483c63    MISMATCH: ssid, psk
```

Bar 2 exists because 26082225 r12 cleared bar 1 in 21.15 s — the fastest round measured — and was
running its own **factory** SSID on every BSS. `beerocks_backhaul` could not open
`/var/run/wpa_supplicant/bhsta1` (89,643 identical `wpa_ctrl_open() failed` lines in an 11-second
window), the prplMesh agent never left `WAIT_FOR_BACKHAUL_MANAGER_CONNECTED_NOTIFICATION (12)`, so
no WSC M2 ever arrived and no credential was ever applied. The bSTA was associated, DHCP worked and
the internet answered — but no client could roam to that node and no third node could onboard
through it. Reachability alone cannot see this.

How the check works, and why each part is the way it is:

- **Records come from hostapd's runtime config** (`/var/run/hostapd-phy*.conf`), because that IS
  the credential rather than a report about it. `iw dev` is read too and a config the radio never
  took is flagged `not-on-air`.
- **Roles come from hostapd's `multi_ap` field** — `1` = backhaul BSS, `2` = fronthaul, `3` = both.
  Never from the SSID: on r12 both of the agent's SSIDs looked plausible and neither was right.
- **Keyed on (role, radio), not on interface name.** The CAP runs an extra bBSS, so the indices do
  not line up. Radio-index equality assumes identical hardware on both nodes; on a mixed bench
  compare by band instead.
- **The passphrase never leaves the DUT.** It is reduced there to the first 8 hex of its md5.
  Enough to see "same" or "different", nothing more.
- **`wpa` version and pairwise cipher fail the round; `wpa_key_mgmt` only prints a note.** A CAP
  legitimately advertises more key_mgmt suites than an agent (`WPA-PSK-SHA256` for 11w), so a
  difference there is worth seeing and not worth failing on.

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

**The credential bar is polled, not sampled once.** A round ends with `creds_wait`, which
re-runs the credential comparison every `CREDS_POLL` seconds (15) for up to `CREDS_DEADLINE`
(180 s) after the settle window, and reports the agent uptime at which every BSS finally matched
(also written to `creds-uptime` in the artefact dir). It is a poll because the credentials do not
always arrive on the agent's first registration pass: on `26082314` r17 the agent was reachable at
uptime 216.4, its registration stalled in `WAIT_FOR_BACKHAUL_MANAGER_REGISTER_RESPONSE (7)`,
`lsmesh-sta-iface-repair` killed `beerocks_agent` (attempt 1/2) — and the CAP's SSIDs landed on all
three BSSes about 70 s after the 60 s settle window had closed. The single-shot check recorded that
round as FAIL; a re-check minutes later was a clean PASS. A single shot measures when we happened
to look, not when the event happened.

**Which console line means "everything is ready"?** Neither of the two obvious candidates.
`fronthaul credentials persisted to UCI` is `wifi_monitor` stashing what it learned from the
backhaul — in r17 the fronthaul BSSes were still on the factory `Linksys2155E6` at that moment.
`legalised HT40 ...` is a side effect of hostapd being reconfigured, so it correlates with the
apply but states nothing about the result. The two authoritative facts are `prplmesh_cli -c status`
reporting `current state: OPERATIONAL (15)` with a `Fronthaul: interface` entry per radio, and the
driver carrying the controller's SSIDs on every BSS (`iwinfo <bss> info`) — which is exactly what
`creds` checks and what `creds_wait` now times.

From firmware build `26082316` the agent says it itself. `wifi_monitor` publishes
`onboarding::agent_state` (`ready`|`incomplete`), `onboarding::agent_detail` (why not, empty when
ready) and `onboarding::agent_ready_uptime`, and prints one console line per change:

```
[t=220.06] onboard: still not complete — the prplMesh agent is WAIT_FOR_BACKHAUL_MANAGER_CONNECTED_NOTIFICATION (12)
[t=276.93] onboard: READY — prplMesh agent OPERATIONAL and every enabled Multi-AP BSS on air with the controller's credentials
```

Every round now ends by reading those tuples back (`agent self-verdict: ...`, also saved as
`agent-verdict.txt` in the artefact dir). It is reported **after** the credential bar and is never
allowed to change the round's pass/fail: the harness owns the verdict, the node's self-report is
evidence. The two tests are deliberately not identical — the node's own test additionally requires
the prplMesh FSM to be `OPERATIONAL` — so a disagreement is a finding worth chasing, not noise.
On builds without the tuples the line says so and the round is unaffected.

**A failed round aborts on the controller's verdict, not on `DEADLINE`.** Every progress line now
carries `onboarding::state`, `onboarding::result` and `onboarding::counters` read from the
controller, and `state=done` with `result=failed` ends the round immediately. This matters twice
over: 26082220 r8 spent the full 300 s polling an agent the controller had already given up on at
36 s, and those extra four minutes of syslog churn are why that round's evidence had to be
recovered from `messages.1.gz` instead of `logread`. Only `failed` is terminal — `done` with a
success result arrives well before the agent has a route, so treating `done` alone as the end
would abort every good round.

**Progress seconds are wall clock.** They used to be a count of poll intervals, which undercounts
by however long each probe's ssh took — and on a failing round every probe waits out
`ConnectTimeout`. 26082222 r9 printed `...40s` at a moment the controller's own uptime put at 81 s,
so `DEADLINE=300` really meant closer to ten minutes. The headline number was never affected (it
comes from the agent's `/proc/uptime`), but the progress lines and `DEADLINE` now mean seconds.

**A failed round is harvested from the other NIC.** An agent that did not onboard has no lease, so
it is not at `192.168.1.111`; it is unconfigured at `192.168.1.1` behind `AGENT_NIC_CONN`. The
harvest falls back there, MAC-guarded, and says so. Without that fallback, r9's artefact dir was
four files with three of them empty — and the failed rounds are exactly the ones whose logs matter.
The controller side (including its `messages.1.gz`) is pulled first, while its NIC is still up.
The agent is looked for in four places, in order: its DHCP address on the current NIC, the same
address on the agent NIC (direct cable, so it works with the backhaul down), `192.168.1.1`
MAC-guarded, and finally its IPv6 link-local derived from `AGENT_MAC`. The last one is not
belt-and-braces: on r10 the agent had reverted to a static `192.168.1.1` while the controller was
*also* reachable at `192.168.1.1` through the agent's own bridge, so no v4 address on the bench
meant "the agent". A link-local is per-interface — whatever answers it on this cable is the box on
the other end of this cable.

**Readiness is two facts, not one.** A round can fail with the bSTA netdev present the whole
time: `wpa_supplicant`'s control socket for that netdev is owned by a different process, and
`agent_lan_to_dhcp`'s netifd reload destroys the socket while leaving the netdev alone. 26082224 r11
lost the round exactly there — the pre-armed fast path read "netdev up, nothing to apply", skipped
the `wifi reload` that is the only thing which recreates the socket, and then spent 15 s waiting for
a socket that was never coming. So when a timeline shows `no radio apply needed` immediately
followed by `appeared in wpa_supplicant Ns after the netdev`, that is the failure, not a slow start.
The converse is normal and expected: the socket goes unreadable *during* the WPS association
(the supplicant is restarting), which is why success is read from `iw dev <if> link`, not from
`wpa_cli status`.

**The daemon's own log mirror is harvested first.** `ble-onboard` writes every line it logs to
`/tmp/ble-onboard.log` (64 KB, one generation kept) precisely because the 128 KB syslog ring drops
an onboarding within minutes. On r10 `logread` had already lost the whole sequence and that file
still had it complete, so it is now the first source both for the harvest and for the timeline.

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
| 26082220 | 38.1 s / 32.6 s | first `POLL=2` numbers, so the first ones comparable to ±2 s |
| 26082223 | 20.8 s | the backhaul STA is now armed at boot instead of after the pair press, so the WPS trigger falls at +4.7 s instead of +20.1 s |
| 26082225 | 21.2 s **but not onboarded** | reachability in 21.2 s with the agent still on its factory SSIDs — see "Credential alignment" above. This is the round that added bar 2 |

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
