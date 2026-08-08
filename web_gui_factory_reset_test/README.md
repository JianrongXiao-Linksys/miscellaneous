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

## Failure mechanism (proven) vs first cause (still open)

The web server is **lighttpd** (`/usr/sbin/lighttpd`, serves `:80` redirect→`:443`,
JNAP + CGI). Feed source: `qsdk/qca/feeds/packages/net/lighttpd/files/lighttpd.init`
(`START=50`, `USE_PROCD=1`).

**Mechanism (PROVEN).** `start_service()` runs `validate_conf || exit 1` *before*
`procd_open_instance`. That is the only fatal exit on the path, and when it trips the
service leaves **no procd instance, no `/var/log/lighttpd/error.log`, and no
respawn** — exactly the observed state. Ping keeps working because ICMP is
kernel-side. `curl`/JNAP cannot self-recover: they all talk to the dead lighttpd
(catch-22). A manual `/etc/init.d/lighttpd start` brings it all back.

**Two earlier claims in this README were wrong and have been removed:**

- ~~"lighttpd is not enabled at boot; only the LAN-ifup hotplug starts it"~~ —
  `/etc/rc.d/` ships **both** `S50lighttpd` and `K50lighttpd`. It *is* a boot service.
- ~~"cert generation races S50lighttpd"~~ — `uci_apply_defaults()` in
  `/etc/init.d/boot` (`START=10`) is synchronous and finishes before `S20network`
  and `S50lighttpd`; `/etc/uci-defaults` is fully consumed.

**Still open:** *why* `start_service` failed on the first boot that broke. It never
reaches syslog, so it needs a serial capture of that boot.

**The real delta in the April production image is RECOVERY, not the first failure.**
That build lacks `/etc/hotplug.d/iface/50-lighttpd`, so a failed `S50lighttpd` had
**zero** retrigger ⇒ web dead until power cycle. The handler was added 2026-05-12
(`d6c7c15`, `qsdk-spf12.5_csu1/sdk_patches/3027_lighttpd-hotplug-bridge-handler.patch`).
SDK14 fixed it properly instead — Architecture issue **#171**, moving cert generation
into `start_service()`/`reload_service()` and adding respawn — **not backported to 12.5**.

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
#   --no-wan        factory Born-On SOP: WAN unplugged, no Auto_Master, pw stays 'admin'
#   --factory-cgi   also require /factory.cgi Born-On status == 'Idle' after each reset
#   --factory-flow  our aggressive timing: next reset on first ping (implies the two above)
#   --grace N       seconds after ping before the factory checks (default 10)
#   --jason-flow    the reporter's own documented sequence, verbatim (see below)
#   --jf-down-timeout N  raise the doc's 90s disconnect window (our units need up to ~140s)
#   --iface IF      bind pings + curl to this interface (reporter ran the loop over Wi-Fi)
#   --ssid SSID     SSID to reconnect to on a ping timeout (the doc 4.5 retry path)
#   --extra-pass P  add another per-unit default_passphrase candidate
```

## `--jason-flow` — the reporter's exact stress test

The reporter (Jason) could not share the C++ source, but provided a command and
sequence reference: `reference/FactoryResetConnectionStressTest.txt`. `--jason-flow`
implements that document verbatim so our runs are comparable 1:1. It implies
`--no-wan` and `--factory-cgi`.

| Step | Doc § | Behaviour |
|---|---|---|
| 1 | 1, 4.1 | `POST http://IP/JNAP/` (**plain :80**), `--connect-timeout 5 --max-time 20` |
| 2 | 4.2 | Response must contain **both** `"result": "OK"` **and** `DeviceRestart` |
| 3 | 4.3 | Confirm unreachable: **2 failed pings**, 90 s timeout |
| 4 | 4.4 | Wait **20 s** after the DUT is confirmed unreachable |
| 5 | 4.5 | Wait pingable: **3 successful pings**; on timeout, **reconnect Wi-Fi** and retry 60 s |
| 6 | 4.6 | Wait **10 s**. No Auto_Master check |
| 7 | 2, 4.7 | `GET https://IP/factory.cgi` with `Authorization: Basic`, `--connect-timeout 5 --max-time 15` |
| 8 | 4.8 | Judge the **curl exit code only** — their tool does *not* check for `Idle` |
| 9 | 4.9 | Wait **10 s**, then next cycle |
| — | 5 | 20 cycles |

### How this differs from our own `--factory-flow`

These were the gaps between the two harnesses, and each one narrows the race window
differently:

- **Traffic path.** The reporter's PC had **both** wired and Wi-Fi connected to the DUT;
  connectivity was pre-checked on wired, but the *stress loop itself* ran over **Wi-Fi**.
  A Wi-Fi client must re-associate after every reset, so its first successful ping comes
  later and from a different path than a wired client's. `--iface`/`--ssid` match this.
- **Reset scheme.** Theirs posts to `http://` (:80); ours tried `https://` first.
- **Accept criteria.** Theirs additionally requires `DeviceRestart` in the response.
- **Disconnect confirmation.** Theirs requires 2 failed pings within 90 s; we had no
  explicit requirement and once mistook a slow shutdown for a completed reset.
- **20 s post-disconnect wait**, which we did not have at all.
- **3 successful pings** before proceeding, vs our single first ping.
- **`factory.cgi` verdict.** Theirs judges the curl exit code only, so a reachable CGI
  returning an unexpected body would *pass* for them. We log both, and still note when
  the body is not `Idle`.

### ERRNO discrimination — why curl exit 7 alone is not enough

curl exit code **7 covers two very different failures**, and only one of them is #451:

| ERRNO | curl text | Meaning | #451? |
|---|---|---|---|
| `ECONNREFUSED` | `Connection refused` | Packet reached the DUT; nothing is listening on :443 → **lighttpd is dead** | **Yes** |
| `EHOSTUNREACH` / `ENETUNREACH` | `No route to host` / `Network is unreachable` | The packet never left / ARP unresolved → **the client's path was not ready** | No |

On a dual-homed test PC (wired **and** Wi-Fi both on `192.168.1.0/24`, as the reporter's
setup requires) the Wi-Fi client re-associates after every reset, and for a short window
after the DHCP lease the neighbour entry for `192.168.1.1` on that link is not yet
resolved. A `factory.cgi` GET fired in that window fails with `EHOSTUNREACH` in ~250 ms —
while ping (already warm on the wired link, or satisfied moments earlier) still reports UP.
That is exactly the "ping OK but curl fails" pattern of the bug, with a completely
different cause.

The tool therefore checks the ERRNO text: on `EHOSTUNREACH`/`ENETUNREACH` it settles 15 s
and retries once, and a successful retry is recorded as a **PASS with an explicit
"path artifact" note**. Only a persistent failure — or `Connection refused` — is scored as
a reproduction. Since the reporter's tool judges the exit code alone, some of its
"4th–5th reset" failures may be this artifact rather than the lighttpd start race.

### Usage (matching the reporter's topology)

```bash
# Both links up: wired stays connected, the loop runs over Wi-Fi.
nmcli device wifi connect Linksys00002 password '<passphrase>' ifname wlp0s20f3

./reset_web_test.sh -i 192.168.1.1 -p '<passphrase>' -n 20 --jason-flow \
    --iface wlp0s20f3 --ssid Linksys00002 --no-ssh
```

A 20-cycle run takes ~80 minutes, so wrap it in `systemd-inhibit` — a host suspend
mid-loop silently kills the run and looks like an unexplained stall in the log:

```bash
systemd-inhibit --what=sleep:idle:handle-lid-switch --why="451 stress test" \
    ./reset_web_test.sh ... &
```

### Firmware note

The reporter's reproduction used **M60PW-HK firmware 1.0.18.26042406**. Our units run
**1.2.3.26072311**. That is an unresolved difference between the two environments and
should be stated with any result from this tool.

## No-WAN mode (factory Born-On validation SOP)

The reporter's scenario comes from the **Linksys Industrial Cloud / Born-On Date factory
validation SOP**, not from normal end-user use. On the production line the factory
connects WAN for cloud (Born-On) validation, then **removes the WAN cable**, factory-resets
the unit, and re-checks `factory.cgi` to confirm the status returns to `Idle` before the
unit leaves the line.

With the WAN cable removed the device behaves differently, which changes the test:

| | WAN connected | **WAN unplugged (`--no-wan`)** |
|---|---|---|
| Auto_Master | Runs; promotes unit to master | **Never runs** (no WAN IP to obtain) |
| `linksys.smart_mode.mode` | becomes `2` (master) | stays **`0` (unconfigured)** |
| Web/admin password | default passphrase (`8xPghzqdr@`) | stays **`admin`** permanently |
| Auto_Master gate | tool waits for completion | **skipped** (nothing to wait for) |
| JNAP auth order | master pw first | **`admin` / no-auth first** |

`--no-wan` therefore skips the Auto_Master wait entirely (it would just burn the timeout
every iteration), logs the observed `mode`/password so a *non*-zero mode is flagged, and
reorders the JNAP + SSH credential attempts to try `admin` first.

### `factory.cgi` Born-On check (`--factory-cgi`)

`/www/factory.cgi` is a 20-line shell CGI that prints the Born-On state from uci
`dbon.bootstatus`:

| uci state | Output |
|---|---|
| `success=1` | `Success` |
| `success=-1` | `Failure` |
| `running=1` | `Running` |
| otherwise | **`Idle`** |

A factory reset wipes `/etc/config/dbon`; `etc/uci-defaults/dbon.defaults` then recreates it
with `running=0`/`success=0`, so the post-reset SOP expectation of **`Idle`** is confirmed by
the source. `--factory-cgi` asserts that after every reset — and because it goes through
lighttpd's `mod_cgi` handler, it is a stronger web check than a bare TCP/socket probe.

### Usage for the factory SOP scenario

```bash
./reset_web_test.sh -i 192.168.1.1 -p admin -n 15 --no-wan --factory-cgi --recover
```

The default password is `8xPghzqdr@` (the master-mode passphrase for this build);
the unconfigured-mode password is `admin`, used only in the brief window before
Auto_Master completes — which the tool gates past, so it never needs it.

Exit code `1` = bug reproduced (or DUT unreachable); `0` = all N resets recovered.

## `qca_skipcnss_stress.sh` — QCA case 08621084 (kernel panic, separate issue)

A **second, unrelated** defect surfaced on the same reset loop: some boots panic with
`kernel BUG at qca-cnss-local/main.c:5868` in `cnss_register_subsys+0x2ec/0x378`,
reached via `modprobe wifi_3_0` → `pld_register_driver` → `cnss_wlan_probe_driver`.
Line 5868 is `CNSS_ASSERT(0)` on the `rproc_boot()` failure path, and `r5 = fffffffe`
in the register dump is that return value = **-ENOENT** (the case subject says
-ENOMEM; that is wrong). Escalated to Qualcomm as **case 08621084**.

`qca_skipcnss_stress.sh` implements the debug procedure QCA asked for, deliberately
kept separate from `reset_web_test.sh`:

| QCA step | Implementation |
|---|---|
| 1 — boot arg `cnss2.skip_cnss=1` | set out-of-band with `fw_setenv` (see below); the script *verifies* it every iteration |
| 2 — console capture | `serial_console_log.py`, or `minicom` |
| 3 — 15 reset iterations | reset via JNAP → wait offline → wait online → confirm SSH **and** HTTP/HTTPS → wait **10 s** → next |
| 4 — watch for `overlayfs` / `-116` | `dmesg` pulled after every iteration and scanned for `overlayfs`, `ESTALE`, `-116` |
| 5 — `jffs2reset -y` on a hit | automatic (`AUTO_JFFS2RESET=1`) |

```bash
./qca_skipcnss_stress.sh          # constants at the top: ITERATIONS, DOWN_WAIT, BOOT_WAIT, CYCLE_WAIT
```

Exit codes: `0` clean, `1` failure/abort, `2` incomplete, `3` an `overlayfs`/`-116` hit.

The boot argument goes in the **U-Boot environment** (`u_env`, mtd20), so it survives
both reboot *and* factory reset — the overlay is wiped every iteration, so an overlay
based method would not last:

```sh
fw_setenv bootargs "console=ttyMSM0,115200n8 cnss2.enable_mlo_support=1 cnss2.skip_cnss=1"
reboot
# rollback: same command without the last token
# verify:   cat /sys/module/ipq_cnss2/parameters/skip_cnss   # 1
#           cat /sys/class/remoteproc/*/state                # all offline
```

No image rebuild is needed: `load_cnss2` parses `cnss2.*` tokens out of
`/proc/cmdline` and passes them to `insmod ipq_cnss2`.

**Caveat on the result.** `skip_cnss=1` keeps the WLAN driver from attaching at all,
so Wi-Fi never comes up and the panicking path is never entered. A clean run under
it is expected and does **not** show the panic is fixed — it only isolates the
overlayfs question QCA wanted answered.

## `serial_console_log.py` — timestamped console capture (QCA step 2)

Writes `[HH:MM:SS.mmm +oooo.ooo] line` and live-flags `OVERLAYFS`, `ESTALE-116`,
`PANIC`, and `RESET-REASON`. Needed because a panicking boot never gets far enough
to answer SSH, so `dmesg` can never capture it.

```bash
sudo ./serial_console_log.py                       # /dev/ttyUSB0 @ 115200 → logs/console_<ts>.log
sudo ./serial_console_log.py -d /dev/ttyUSB1 -b 115200
```

`sudo` is required — the device is `root:dialout`. Requires `pyserial`.

## Reports

- `crash/panic_cnss_register_subsys.md` — the panic, decoded, with questions for QCA
- `crash/qca_skipcnss_run1_result.md` — full internal result of the `skip_cnss=1` run
- `crash/qca_reply_console_log.md` — the trimmed, de-branded reply sent to QCA

## Dependencies

`sshpass`, `curl`, `ping` (all present on this host); `pyserial` for
`serial_console_log.py`. Logs are written to `./logs/`.

## Log artifacts for QCA case 08621084

| File | Contents |
|---|---|
| `logs/qca_skipcnss_20260808_112546.log` | run log of the 15-iteration loop (per-iteration timings, verdicts) |
| `logs/qca_skipcnss_20260808_112546_dmesg.txt` | 16 `dmesg` snapshots (baseline + one per iteration), 480 KB |
| `logs/serial_console_20260808_skipcnss_INTERNAL_raw.log` | serial capture, all 16 `skip_cnss=1` boots — **internal only**, contains MAC/serial/UUID/credentials |
| `logs/serial_console_20260808_skipcnss.log` | the same capture, sanitized — this is the copy sent to QCA |

Send `serial_console_20260808_skipcnss.log` only (the one without `INTERNAL` in the name). Sanitization masks host identifiers (`<MAC>`,
`<SERIAL>`, `<UUID>`, `<HOSTNAME>`, `<SSID>`, `<REDACTED>`) and replaces
vendor-proprietary log tags (`[Linksys][*]` → `[vendor][*]`, `[Auto_Master]` →
`[provisioning]`); all kernel and driver messages are left verbatim. Verify before
sending:

```bash
grep -ciE "8xPghzqdr|12345Asdf|74:12:13|67A10M24|linksys|Auto_Master" \
    logs/serial_console_20260808_skipcnss.log     # must print 0
```

Note the earlier capture in `~/Downloads/08621084/` (`kp.log` plus `dump/` and
`vmlinux` artifacts) is from the **previous** build's panic run, not from this
`skip_cnss=1` test — do not attach it to this reply.
