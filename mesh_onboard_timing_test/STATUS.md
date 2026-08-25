# Status — 2026-08-25, morning (America/Los_Angeles)

Nothing is running: no harness round, no build, no `ssh` session held open. The last activity was a
four-round `run -n 4` that finished at 09:14.

Both nodes are flashed with **26082508**
(`FW_Pinnacle2.0_v2.0.1.26082508_release.img`, `md5 fb6269987b08c4ec9f256009e435324b`,
45,777,720 bytes, built 08:09 today). No round artefact records the build version — see
*Harness gaps* — so that attribution rests on the flash sequence, not on the evidence in the
artefacts.

The agent is left **onboarded** (round 04 passed): both fronthaul BSSes on the controller's
`Linksys00003`, backhaul `COMPLETED` to `74:12:13:21:53:8c`, internet and gateway `ok`.

## Bench state as left

| node | address | version | state |
|---|---|---|---|
| controller `74:12:13:21:53:88` | `192.168.1.1` behind `Wired connection 2` (host `192.168.1.254`) | 26082508 | up, WAN up, 3 BSSes (2.4 fBSS, 5 fBSS, 5 bBSS) |
| agent `74:12:13:21:55:e6` | leased `192.168.1.111` behind `Wired connection 3` (host `192.168.1.9`) | 26082508 | onboarded — `agent_onboarded=yes`, `_elapsed=79`, `_uptime=255` |

**Both host NICs are up at once**, both on `192.168.1.0/24`, and the agent NIC wins the default
route (`192.168.1.1 dev enx24f5a2f17025 metric 50` vs `... enx24f5a2f20603 metric 500`). So an
unqualified `ssh root@192.168.1.1` from this host reaches **whichever node answers on the agent
segment**, not necessarily the controller. Run `./onboard-timing-test.sh nic ctrl` before touching
the controller, and never act on `192.168.1.1` without the MAC guard
(`./onboard-timing-test.sh identify <ip>`).

## Where the work stands

The bug this file used to describe as live — `/var/run/wpa_supplicant/bhsta1` missing after the pair
press — is **fixed and no longer reproducing**. On all six rounds below the bSTA associates 4.0 s
after `wps_pbc`, and the credential is persisted.

Reachability is no longer the interesting number either. The node now publishes its own verdict
(`onboarding::agent_onboarded*`), and on 26082508 that verdict is **stable**: 78, 79, 88 and 133 s
from the GATT onboard command, against a 150 s budget.

### The six rounds on 26082508

`ready_at` is measured by the harness from **its** trigger; `_elapsed` is measured by the node from
the GATT command. The difference is the time the box takes to accept the BLE onboard request after
the harness fires it, and it is where nearly all of `ready_at`'s variance lives.

| artefacts | `ready_at` | node `_elapsed` | BLE-accept latency | harness verdict | node verdict |
|---|---|---|---|---|---|
| `260825-0832/round-01` | 172 s | 133 | 39 s | pass, **over the 150 s budget** | `yes` at t=278.41 |
| `260825-0845/round-01` | never | — | — | **fail** at the 300 s deadline | `no` at the deadline, latched `yes` 1.6 s later (t=301.75) |
| `260825-0856/round-01` | 140 s | 88 | 52 s | pass, in budget | `yes` at t=249.82 |
| `260825-0856/round-02` | 116 s | 78 | 38 s | pass, in budget — **best of the series** | `yes` at t=218.41 |
| `260825-0856/round-03` | 68 s | — | — | pass (fastest `ready_at` ever recorded) | **`no`** at harvest — see below |
| `260825-0856/round-04` | 154 s | 79 | 75 s | pass, 4 s over budget | `yes` at t=255.27 |

Read that table as: **the node's onboarding is now consistent (78–88 s) and the two over-budget
rounds are over budget because of BLE-accept latency (75 s on round 04), not because onboarding got
slower.** Only `260825-0832/round-01` (133 s) is a genuinely slow onboard, and it is the round with
the VAP fold → rebuild → bhsta drop → prplMesh state 0 sequence.

### The live problem — the orphan VAP (`wlan1_2`)

Two of six rounds hit it, and it is prplMesh-side; the fix is QCA's.

`beerocks_ap_manager` applies the M2 to a **brand-new VAP** rather than to the netifd section the
product is bound to:

```
ap_wlan_hal_nl80211.cpp[3344] --> NEW VAP Ifname: wlan1_2 Index: 2 BSSID: 42:12:13:21:55:e8
bpl_cfg_wifi.cpp[878]        --> Configuration for interface wlan1_2 not found
bpl_cfg_wifi.cpp[967]        --> Section not found for interface wlan1_2, creating new section
bpl_cfg_wifi.cpp[1249]      --> UCI credentials for wlan1_2 changed, updating
```

- `260825-0845/round-01`: the orphan is created at t=189.4, terminated at t=192.3 and removed at
  t=195.3. That **lifecycle** — created, given the credentials, then torn down — is what cost the
  round; the round failed 1.6 s past the deadline.
- `260825-0856/round-03`: the orphan is created at t=226.3 and is **still on air at harvest**
  (`VAP_PRESENT=… wlan1_2@5180=<backhaul-ssid>`), with its own UCI section
  `wireless.iface_wlan0` (`ifname='wlan1_2'`, `multi_ap='1'`).

Round 03 is the one to look at, because the two verdicts disagree and both are behaving as
designed:

- The **harness** said `pass` at 68 s. Its inventory checks that every expected VAP is present and
  carries the right SSID; an *extra* VAP is not something it looks for (`VAP_MISSING=` empty, and
  there is no `VAP_EXTRA` field).
- The **node** said `agent_onboarded=no`, `detail=the Multi-AP BSSes do not yet carry the controller
  credentials`. `_backhaul_bss_gap` runs `_backhaul_netifd_owned_iface` before any SSID test, and a
  Multi-AP BSS on a name netifd never produced disqualifies the section outright — deliberately, per
  firmware-bugs 070: the GUI, JNAP, TR-181 and WPS are all bound to the netifd sections.

The harvest is 6.5 s after the orphan appeared, so this round does **not** prove the marker would
have stayed `no` indefinitely — the orphan fold had not run inside the round window, and the round
ended before it could. Settling that needs a round that is left alone for a minute past the pass,
which the harness currently does not do.

`26082508`'s own recovery did work on that round: at t=224.19 the back-out trigger armed (UCI had
the controller's fronthaul credentials while the runtime did not, agent in state 14), and at
t=229.52 it cleared itself — "the runtime picked the controller's credentials up on its own after
5s, no repair needed".

## Harness state

Pushed through `9373dcb`; `main` == `origin/main`. `inventory` (the exact-VAP-set check) and the
per-round `agent-verdict.txt` readback are the newest additions.

### Harness gaps — worth fixing before the next series

1. **No `build_version` in any artefact.** Nothing in a round directory says which firmware
   produced it; build attribution is by flash sequence and memory only. Stamp
   `/etc/routerinfo`'s `build_version` into `round-meta.txt` for both nodes.
2. **No `VAP_EXTRA`.** An orphan VAP passes the inventory check silently (round 03). The check
   should report VAPs present that are not in the expected set, and a round with one should not read
   as clean.
3. **`onboarding::agent_serviceable_uptime` is not harvested.** `agent_onboarded*` is read back, but
   the serviceable timestamp — the number firmware-bugs 071 is about — still has to be dug out of
   the timeline by hand.
4. **`REPAIR_ATTEMPTS` is never written.** It is empty in all six rounds' `check-pass.txt`. Either
   the field is not being populated or no repair has ever fired in a harvested round; both readings
   need distinguishing, because the uplink guardian's recovery ladder is unverified on the DUT
   precisely for this reason.
5. **The uptime line in the timeline header can be nonsense.** `260825-0856/round-02` prints
   `pairing triggered at t=1992324s of agent uptime` while `round-meta.txt` correctly records
   `agent_uptime_at_trigger=101.04` — the header derives it from epochs, and the box's clock is
   pre-NTP at that point (that round's boot epoch reads `2026-08-02`).
6. **A round ends at the pass.** No post-pass settle window, which is what round 03 needed.

## Firmware git state

| tree | state |
|---|---|
| feed `premium` (`store/sdk/qsdk/feeds/premium`) | `d81399d`, at `origin/develop` — merged as feed_premium#10 |
| feed `core` (`store/sdk/qsdk/feeds/core`) | `48ef213`, at `origin/develop` — merged as feed_core#11 |
| targets tree | one **local-only** commit `69547d5` on `fix/065-bhsta-cred-single-instance-sdk-patch`, no PR — the `pgrep -f` single-instance guard for `prplmesh-bhsta-cred` as an `sdk_patches` entry. A fresh checkout still builds without it. |

## Not in scope

TR-181 / bbfdm / wifidmd and GUI code are out of scope for the PR — the delivered contract is
sysevent-over-ubus (`onboarding::pair` / `::state`), not a TR-181 or EasyMesh object.
