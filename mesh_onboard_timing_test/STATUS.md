# Status — paused 2026-08-22, evening (America/Los_Angeles)

Testing is **paused** at Jianrong's request. Nothing is running: no harness round, no build.
Both nodes are flashed with **26082225** (`md5 41858dc969c2ddad0698bc327f686149`).

## Bench state as left

| node | address | version | state |
|---|---|---|---|
| controller `74:12:13:21:53:88` | `192.168.1.1` behind `Wired connection 2` (`192.168.1.254`) | 26082225 | up, WAN up, 3 BSSes (2.4 fBSS, 5 fBSS, 5 bBSS) |
| agent `74:12:13:21:55:e6` | `192.168.1.1` behind `Wired connection 3` (`192.168.1.9`) | 26082225 | **unconfigured** — r13 was factory reset and its onboarding failed |

The host NIC left up is the **agent** one. `./onboard-timing-test.sh nic ctrl` before touching the
controller — and never act on `192.168.1.1` without the MAC guard.

## Where the work stands

Reachability is basically solved: 136.9 s (26082215) → 21.2 s (26082225). The open problem is that
reachability was never the whole bar.

### The live bug — the bSTA supplicant control socket

`/var/run/wpa_supplicant/bhsta1` does not exist after the pair press, and everything downstream of
prplMesh needs it.

Evidence, agent, 26082225 r13 (`/tmp/ble-onboard.log`):

```
[t=68.77]  pre-arm: bhsta1 netdev up (0s after the apply); supplicant socket present
[t=191.94] onboarding method=pbc — stopping advertisement, starting WPS-PBC
[t=191.95] switching br-lan to DHCP client before WPS (nothing associated yet)
[t=211.39] still short after 15s: bhsta1 supplicant socket — the br-lan reload undid the
           pre-arm, so applying the radio after all
[t=239.86] pre-WPS apply incomplete after 15s (absent: bhsta1 supplicant socket) — re-applying
[t=268.35] ERROR: still absent after 15s: bhsta1 supplicant socket — continuing to WPS anyway
[t=293.43] ERROR: bhsta interface bhsta1 failed to come up
```

So the socket is present at boot, is destroyed by `agent_lan_to_dhcp`'s netifd reload, and **two
full `wifi reload` passes do not bring it back**. That is new information: it is not a race we can
out-wait, and the fix-4 diagnostics in the daemon are what made it legible.

What is known about the shape of it, from the agent, live:

- one supplicant, netifd's global instance: `/usr/sbin/wpa_supplicant -n -s -g /var/run/wpa_supplicant/global` — no `-i`
- `/var/run/wpa_supplicant/` contains **only** `global`
- `/var/run/wpa_supplicant-bhsta1.conf` exists and **does** contain `ctrl_interface=/var/run/wpa_supplicant`, plus `wps_cred_processing=2`, `update_config=1`, `freq_list=...` — and **no `network={}` block**
- `ubus list` **does** show `wpa_supplicant.bhsta1`, offering `reload`, `get_features`, `wps_start`, `wps_cancel`
- the socket directory is `network:network drwxr-xr-x` and the supplicant runs as `network`, so permissions are not it
- `logread` on the agent has no supplicant-side complaint about the control interface at all — the only lines are the consumer failing to open it

That combination is the puzzle to start from tomorrow: the interface is registered with the
supplicant (ubus object present) and its config asks for a control socket, yet no socket is created.

### What it costs — r12, the round that looked best and was not onboarded

26082225 r12: reachability at **21.15 s**, and:

- 89,643 identical `beerocks_backhaul: wpa_ctrl_open() failed, ctrl_iface_path: /var/run/wpa_supplicant/bhsta1` lines in an **11-second** window — a hot spin that also explains why `logread` loses every round
- prplMesh agent stuck in `WAIT_FOR_BACKHAUL_MANAGER_CONNECTED_NOTIFICATION (12)`, never reaching `WAIT_FOR_AUTO_CONFIGURATION_COMPLETE (14)`
- therefore **no WSC M2**, therefore no credential: the agent kept its factory `Linksys2155E6` on both fBSSes and a factory random SSID on its bBSS, while the CAP runs `Linksys00003`
- so: no client could roam to that node, and no third node could onboard through it

Correlation across saved rounds (`agent-state.txt` in each artefact dir):

| round | build | agent fronthaul SSID | prplMesh state |
|---|---|---|---|
| r4 | 26082217 | `Linksys00003` (CAP's) | 14 |
| r5 | 26082217 | `Linksys2155E6` (factory) | — |
| r6, r7 | 26082220 | `Linksys00003` (CAP's) | 14 |
| r10 | 26082223 | `Linksys2155E6` (factory) | 12 |
| r12 | 26082225 | `Linksys2155E6` (factory) | 12 |

The rounds that lost the credential are the ones that reached state 12 and stopped. Both pre-arm
builds are in that group, and so is r5 — so the pre-arm is a strong suspect but not the only case.

## Two candidate directions for tomorrow

1. **Do not tear the socket down.** `agent_lan_to_dhcp` runs a netifd reload *before* WPS purely to
   have a lease ready. Moving it after the association would keep the socket and also cut ~6.5 s
   (4.46 s reload + 2 s guard) off the critical path. Risk: a reload while associated has dropped
   the backhaul before — check the fix history first, this is exactly the area the "back and forth"
   warning covers.
2. **Make the socket come back.** Understand why a registered interface with `ctrl_interface=` set
   produces no socket. `ubus call wpa_supplicant.bhsta1 reload` is the cheap thing to try, and
   `wps_start` on that same object is a better arming path than `wpa_cli` regardless.

Whatever the fix, the acceptance bar is now both bars, not one: reachability **and**
`./onboard-timing-test.sh creds` reporting `aligned` on every fronthaul and backhaul BSS.

## Harness state

Pushed through `a09ac00`. `creds` / `creds -o <dir>` is new and a round now fails on it.

## Firmware commits — LOCAL ONLY, not pushed

`premium` feed (`store/sdk/qsdk/feeds/premium`):
`31e0208, 2b50fdf, 07bd022, 091744b, a3f1829, d091bd1, e670269, 84fd7ef, 0d0c125, 7e797de,
33704f4, af6f8f1, 82c4d65, 68f41b6` — and `core` feed `95e3039`.
