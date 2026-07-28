# Issue #451 — Web GUI not accessible after factory reset (M60PW / Pinnacle 2.0)

Reproduction + diagnosis tool for LinksysWRT issue **#451**:
*"[M60PW] Sometimes web GUI is not accessible after DUT is reset to default."*

## The bug (from the issue)

With the LAN cable connected the whole time and **no power cycle**, repeatedly
triggering a JNAP Factory Reset eventually (typically the **4th–5th** consecutive
reset) leaves the DUT in a state where:

- `192.168.1.1` **still pings**, but
- the web UI returns **Connection Refused** on both browser and `curl` (curl code 7),
- and it never recovers on its own, even after long waiting.

## Root cause (confirmed against `pinnacle/develop` source)

The web server is **lighttpd** (`/usr/sbin/lighttpd`, serves `:80` redirect→`:443`,
JNAP + CGI).

- lighttpd is **NOT enabled at boot** — there is *no* `rc.d` `S*` symlink, so procd
  does not start it on boot. (Verified: `etc/rc.d/` has no `*lighttpd*` entry;
  init script has `START=50` but is never `enable`d.)
- Its **only** start trigger is the one-shot LAN ifup hotplug
  `/etc/hotplug.d/iface/50-lighttpd`, which runs `/etc/init.d/lighttpd start` when
  `ACTION=ifup && INTERFACE=lan`.
- If that single start is missed or fails on a given boot, **nothing re-triggers it**
  until the next LAN ifup — which only a power cycle provides. Ping keeps working
  because ICMP is kernel-side, independent of lighttpd.
- `curl`/JNAP **cannot** self-recover: they all talk to the dead lighttpd (catch-22).

Factory console capture confirmed the smoking gun: in the failed state
`lighttpd -tt` returns **exit 0 (config VALID)**, there is **no lighttpd process**,
`:80`/`:443` are **not LISTENing**, and `/var/log/lighttpd/error.log` **does not
exist** (start_service never ran this boot). A manual `/etc/init.d/lighttpd start`
brings it all back — proving the start was simply *missing*, not broken config.

**Proper firmware fix:** enable lighttpd at boot (ship the `rc.d` enable symlink /
`enable`) so procd starts+respawns it, and/or make `50-lighttpd` idempotent with a
retry independent of a single ifup event.

## Post-reset device state (important for the test logic)

After every factory reset the DUT reboots **unconfigured**:

- `linksys.smart_mode.mode = 0`, admin password = **`admin`**.
- lighttpd is brought up early by the LAN-ifup hotplug, so the web server may
  answer **before** the device is actually configured — "any HTTP response" is
  *not* the same as "Web UI loads properly" (issue step 4).

Because a WAN link is present, **Auto_Master** then runs
(`auto_master_start.sh`): after a ~30 s settle it waits for a WAN IP, and if no
existing master is found it promotes this node to **master**
(`smart_mode.mode = 2`), applies the default passphrase as the admin password
(so the login password becomes **`8xPghzqdr@`** on this build), and sets
`auto_master::status = stopped`. This can take up to ~3 minutes.

So the tool treats "step 4 = Web UI loads properly" as **"Auto_Master has
completed"** and, before each web check / next reset, **gates** on:
`mode != 0` AND `auto_master::status ∈ {stopped,failed}` AND admin password
`!= admin`. It also authenticates the JNAP FactoryReset call with the master
password (`admin:8xPghzqdr@`), since in master mode JNAP requires auth.

## What this tool does

`reset_web_test.sh` reproduces the exact issue loop:

1. Baseline: confirm ping + web are up.
2. Trigger a JNAP `core/FactoryReset` **with basic auth** `admin:$JNAP_PASS`
   (falls back to SSH `jffs2reset` if JNAP is rejected/undeliverable). Only a
   `"result":"OK"` counts as accepted — `_ErrorUnauthorized` is a failure, not
   success.
3. Wait for the DUT to reboot and become pingable again.
4. **Wait for Auto_Master to complete** (SSH-gated as above), so the web check is
   fair and the next reset has the right password.
5. Verify ping (expected always OK) and web (`:443`/`:80`).
6. Repeat, **without power cycling**, until the web fails or N iterations pass.

When the web fails it **SSHes in and captures the proof** (lighttpd status, process
list, listening sockets, config validation, missing `error.log`, absent boot
symlink, hotplug logread) into `logs/diag_*.txt`, and prints a verdict when the
known root-cause signature (config valid + no process + not listening) is matched.

With `--recover` it then runs `/etc/init.d/lighttpd start` over SSH to confirm the
web comes straight back — demonstrating that the start was merely missing.

## The three factory-reset methods

All three ultimately do the **same thing**: clear the writable overlay
(`firstboot -y`) and reboot. On the next boot `boot_linksys` finds no
`/etc/config/linksys` and runs `restore_factory_defaults`. They differ only in
the *trigger* and the *channel*:

| Method | Trigger / channel | Auth | Path in source | Notes |
|---|---|---|---|---|
| **Hardware reset** | Physical reset button held (GPIO). `hotplug2_functions.sh` counts the hold, then runs `firstboot -y && sync && reboot`. | none (physical) | `service_init/files/hotplug2_functions.sh` (`FactoryResetAfter`) | Cannot be scripted remotely. Also power-cycles LAN, so lighttpd's LAN-ifup start fires cleanly — this is *why a power cycle recovers #451*. |
| **JNAP** (this issue) | HTTPS/HTTP `POST /JNAP/` with `X-JNAP-Action: …/core/FactoryReset`. Backend fires the `device_reset` sysevent → `service_node-mode.sh` runs `firstboot -y && sync && reboot`. | **Yes** — HTTP basic auth (`admin:<passphrase>`) once in master mode | JNAP handler → `node-mode/files/service_node-mode.sh` (`device_reset`) | What the test/issue use. **No power cycle**, LAN stays up → relies on the single LAN-ifup hotplug that boot, which is the failure trigger. |
| **USP / TR-369** (also TR-069) | `FactoryReset()` operate command on the USP/TR data model, handled by obuspa/bbfdm. Sets reboot cause `FactoryReset`, performs DB factory reset + reboot. | Yes — USP controller / ACS credentials | `feeds/tr069_tr369/bbfdm/bbfdm_service.json` (`FactoryReset()`), `obuspa/files/etc/init.d/obuspa` | Remote-management channel (ACS/controller). Same overlay-clear outcome; different management plane and auth. |

**Key takeaway for #451:** the *outcome* of all three is identical (overlay
cleared → reboot → unconfigured → Auto_Master). The bug only reproduces with
**JNAP** (and would with **USP**) because they reset **without a power cycle**,
so the LAN link never bounces and lighttpd depends entirely on the one-shot
LAN-ifup hotplug of that boot. The **hardware** method tends to *not* reproduce
it if it coincides with a power/link cycle that re-fires the hotplug — which is
exactly the "power cycle recovers it" behavior in the report.

## Usage

```bash
cd /home/jianrong/code/claude/miscellaneous/web_gui_factory_reset_test

# Basic: 15 resets, SSH diagnostics + recovery on failure.
# -p sets BOTH the SSH login password and the JNAP basic-auth password.
./reset_web_test.sh -i 192.168.1.1 -p '8xPghzqdr@' -n 15 --recover

# Options
#   -i IP           DUT IP                                   (default 192.168.1.1)
#   -p PASS         SSH + JNAP master password               (default 8xPghzqdr@)
#   -P PASS         JNAP password only (override -p)
#   -u USER         SSH user                                 (default root)
#   -n N            iterations                               (default 15)
#   -w SECONDS      max boot wait                            (default 180)
#   -t SECONDS      web reach timeout after ping returns     (default 90)
#   -a SECONDS      max Auto_Master completion wait          (default 240)
#   --recover       on failure, `/etc/init.d/lighttpd start` to confirm recovery
#   --no-ssh        skip SSH gating/diagnostics (repro only; fixed-waits Auto_Master)
```

The default password is `8xPghzqdr@` (the master-mode passphrase for this build);
the unconfigured-mode password is `admin`, used only in the brief window before
Auto_Master completes — which the tool gates past, so it never needs it.

Exit code `1` = bug reproduced (or DUT unreachable); `0` = all N resets recovered.

## Dependencies

`sshpass`, `curl`, `ping` (all present on this host). Logs are written to `./logs/`.
