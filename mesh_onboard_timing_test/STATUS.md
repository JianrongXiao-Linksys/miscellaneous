# Status — 2026-08-25, midday (America/Los_Angeles)

Nothing is running: no harness round, no build, no `ssh` session held open. The last activity was a
four-round `run -n 4` on `26082511` that finished at 11:10.

Both nodes are flashed with **26082511**, and this is the first series where that statement rests on
the artefacts rather than on the flash sequence: `BUILD=26082511` is in every `check-*.txt`, and
`build_version=26082511` is in both `agent-meta.txt` and `ctrl-meta.txt`.

The agent is left **onboarded** (round 04 passed): both fronthaul BSSes on the controller's
`Linksys00003`, backhaul `COMPLETED`, internet and gateway `ok`.

## Bench state as left

| node | address | version | state |
|---|---|---|---|
| controller `74:12:13:21:53:88` | `192.168.1.1` behind `Wired connection 2` (host `192.168.1.254`) | 26082511 | up, WAN up, 3 BSSes (2.4 fBSS, 5 fBSS, 5 bBSS) |
| agent `74:12:13:21:55:e6` | leased `192.168.1.111` behind `Wired connection 3` (host `192.168.1.9`) | 26082511 | onboarded — `agent_onboarded=yes`, `_elapsed=78`, `_uptime=243` |

**Both host NICs are up at once**, both on `192.168.1.0/24`, and the agent NIC wins the default
route. So an unqualified `ssh root@192.168.1.1` from this host reaches **whichever node answers on
the agent segment**, not necessarily the controller. Run `nic ctrl` before touching the controller,
and never act on `192.168.1.1` without the MAC guard (`identify <ip>`).

## Where the work stands

Reachability stopped being the interesting number a while ago; on these two builds the *harness's*
number stopped being the interesting one too. The node publishes its own verdict
(`onboarding::agent_onboarded*`), and every field the harness now harvests comes off the node.

### The seven rounds on 26082510 and 26082511

`ready_at` is the harness's number, measured from **its** trigger; `_elapsed` is the node's, measured
from the GATT onboard command. The difference is how long the box takes to accept the BLE request
after the harness fires it, and it is still where most of `ready_at`'s variance lives.

| artefacts | build | `ready_at` | node `_elapsed` | serviceable | prplMesh `READY` | node verdict |
|---|---|---|---|---|---|---|
| `260825-1015/round-01` | 26082510 | 117 s | 82 | — | — | `yes` |
| `260825-1015/round-02` | 26082510 | 89 s | 87 | — | — | `yes` |
| `260825-1015/round-03` | 26082510 | never | — | — | — | fail — see firmware-bugs 078 |
| `260825-1049/round-01` | 26082511 | 105 s | 61 | t=206 | t=260 | `yes` at t=206 |
| `260825-1049/round-02` | 26082511 | 132 s | **50** | t=233 (**re-stamped**) | t=287 | `yes` at t=198 |
| `260825-1049/round-03` | 26082511 | 121 s | 83 | t=227 | t=281 | `yes` at t=227 |
| `260825-1049/round-04` | 26082511 | 117 s | 78 | t=243 | t=297 | `yes` at t=243 |

Read that as: **four rounds, four passes on `26082511`, and 50 s is the best agent-side onboard ever
measured here** (previous best 62 s). The four `_elapsed` values are 61 / 50 / 83 / 78 against a
150 s budget.

**prplMesh `OPERATIONAL` lands exactly 54 s after serviceable, in all four rounds** — 206→260,
233→287, 227→281, 243→297. That is firmware-bugs 074's fixed per-radio timeout, now measured four
times on one image with no variance at all, which is a stronger statement than the single 48 s figure
074 carries. It is also only visible because of the settle window: at harvest (t≈209 on round 01)
`agent_ready_uptime` was still empty in all four rounds, and every one of the four values above comes
from `agent-verdict-settle.txt`.

### One finding the new fields produced immediately — `::agent_serviceable_uptime` is not latched

`260825-1049/round-02` is the fastest round and it is the one that exposes this. The node latched
`agent_onboarded` at t=198.79 (50 s from GATT). Then:

```
[t=214.51] backhaul: disconnected (state=DISCONNECTED) — starting recovery
[t=214.52] backhaul: wpa_supplicant has 0 networks — injecting from UCI
[t=218.09] backhaul: reconnect attempt 1/5
[t=223.17] backhaul: recovered (was disconnected ~19s)
[t=233.81] onboard: SERVICEABLE — every enabled Multi-AP BSS is on air with the controller's credentials
```

`backhaul.sh` sets `onboarding::agent_serviceable_uptime` on **every** `no → yes` transition, so the
tuple now reads **233** and the true first-serviceable time (198) is gone from it. The onboarded
tuple is latched and still reads 198 correctly, so the two disagree by 35 s on the same round.

That matters because `::agent_serviceable_uptime` is the number firmware-bugs 071 is about — "when
did this node become usable". As shipped it answers "when did it most recently become usable", which
is a different question and, on any round with a backhaul flap, a later answer. Not a harness gap:
it needs either a latched `_first` companion tuple or the semantics stated in the northbound
contract. **Owed:** its own ledger entry — held back only because another session is currently
allocating numbers in `firmware-bugs/` and 078 was taken while this was being written.

The same round is also a second reminder that a passing round is not a quiet one: `wpa_supplicant
has 0 networks` after a *successful* onboard, twice (`recovered (was disconnected ~20s)` at t=198.96
as well), is the 064/065 class of fault recovering on its own.

## Harness state

The live harness is **`~/bin/onboard-test.sh` + `~/bin/onboard-check.sh`**, which are **untracked and
outside any git repo**. This directory tracks an older, different `onboard-timing-test.sh`. Every gap
fix below was made in the live scripts, because that is where a round actually reads them from — so
the fixes are currently unversioned, and vendoring them in here is the open decision.

### Harness gaps — all seven now closed, and each one proven by a round

Every claim here is verified against `260825-1049/round-01`'s artefacts, not against the diff.

1. **`build_version` in every artefact** — closed. `onboard-check.sh` emits
   `BUILD=$(sed -n 's/^build_version=//p' /etc/routerinfo)`, and `harvest()` writes `build_version`
   into `agent-meta.txt` and `ctrl-meta.txt`. Reads `26082511` in all four rounds. `devinfo.info.
   sw_version` is *not* a substitute: it is the marketing version (`11.7.31`) and identical across
   builds.
2. **`VAP_ORPHAN`** — closed (already done in the live script before this pass). A VAP whose ifname
   does not parse as `<phy>.<radio>-<bss>` is reported and never scored, matching `fronthaul.sh`'s
   `_fh_netifd_owned` and firmware-bugs 076. Reads empty in all four rounds — no orphan recurred, so
   the field is verified as *silent*, not as *catching* one.
3. **`onboarding::agent_serviceable_uptime` harvested** — closed. `_verdict_tuples()` is now a single
   definition used by both the verdict poll and the settle window, and reads back
   `agent_serviceable`, `agent_serviceable_uptime` and `agent_ready_uptime` alongside the
   `agent_onboarded*` set. This is what produced the 54 s and the 35 s findings above; both were
   invisible before.
4. **`REPAIR_ATTEMPTS` distinguishes absent from zero** — closed. `/var/run/lsmesh-sta-iface-repair.
   attempts` only exists once a repair has fired, so an empty field used to mean either "never fired"
   or "this build does not write it". It now prints `none` when the file is absent, and all four
   rounds read `none` — so lsmesh's repair ladder still has **no** DUT round exercising it (066).
5. **The timeline's uptime header** — closed. It now prefers `agent_uptime_at_trigger` read from the
   agent, falls back to `trigger_epoch - boot` only when that is missing, labels which one it used,
   and prints an IMPLAUSIBLE warning plus a clock-skew NOTE instead of a number. Regenerating
   `260825-0856/round-01` turned `t=1992058s` into
   `t=101.08s of agent uptime (read from the agent)`.
6. **A post-pass settle window** — closed. `SETTLE_WATCH=60` (override to `0` to skip) re-runs the
   check and the tuple readback, re-dumps `uci show wireless`, and says so if the config changed
   under it. Taken on failed rounds too, since that is where a late fold matters most. It is what
   captured all four `agent_ready_uptime` values; `agent-wireless-settle.uci` was byte-identical to
   `agent-wireless.uci` in all four rounds.
7. **The uplink guardian's rungs were unrecorded** — closed, and this one was not on the old list.
   `wifi_monitor`'s uplink ladder writes no counter and no tuple; its only record is one log line per
   rung. `UPLINK_RUNGS` now reports the rung numbers in order and `UPLINK_PASSES` the full-pass
   count. Both read empty / `0` in all four rounds, which is the expected reading on a healthy round
   and is now a statement rather than a missing field.

Also fixed on the way: `AGENT_STATE` was **silently empty in every artefact ever taken**. Its pattern
was `grep -ao 'FSM: [A-Z_]*'` against `beerocks_agent.log`, which contains `STATE_NOTIFICATION` lines
and never an `FSM: <STATE>` one. It now reads `wifi-monitor.log`'s own
`the prplMesh agent is <STATE> (<n>)` and falls back to the old pattern, reporting `none-logged` when
neither is present — an `OPERATIONAL` agent stops printing the line, and that is expected rather than
unknown. Reads `WAIT_FOR_AUTO_CONFIGURATION_COMPLETE(14)` in all four rounds.

### Remaining harness gaps

1. **The scripts are not in this repo** (above). Until they are, a round's harness version is
   unattributable in exactly the way the firmware's was before gap 1 was closed.
2. **`check-last.txt` is easy to misread.** It is the last *failing* poll, written on every
   non-passing poll, so a passing round still leaves a `VERDICT=fail` file next to `check-pass.txt`.
   Nothing is wrong; the name is. Reading it as the round's verdict is a mistake this file has now
   made once.
3. **The pass criterion still cannot see an extra VAP.** `VAP_ORPHAN` reports one, but the round
   verdict does not consider it, which is deliberate per 076 — recorded here so it is a decision and
   not an oversight.

## Firmware git state

| tree | state |
|---|---|
| feed `premium` | branch `fix/076-orphan-vap-not-our-business`, **three commits** ahead of `origin/develop` (`d81399d`) and unpushed: `b84e27d` (076, orphan sections are none of our business), `be57443` (078, hold the `ieee1905_transport` restart down before acting on it), `918ec7c` (docs). `b84e27d` and `be57443` are both **in the flashed `26082510`/`26082511` images** |
| feed `core` | `48ef213`, at `origin/develop` — merged as feed_core#11 |
| targets tree | one local-only commit `69547d5` on `fix/065-bhsta-cred-single-instance-sdk-patch`, no PR — the `pgrep -f` single-instance guard for `prplmesh-bhsta-cred` as an `sdk_patches` entry. A fresh checkout still builds without it |

## Not in scope

TR-181 / bbfdm / wifidmd and GUI code are out of scope for the PR — the delivered contract is
sysevent-over-ubus (`onboarding::pair` / `::state`), not a TR-181 or EasyMesh object.
