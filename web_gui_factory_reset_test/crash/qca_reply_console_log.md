# Reply to QCA case 08621084 — `cnss2.skip_cnss=1` run, console log attached

Hi Pranjal,

We ran the procedure you gave us. All five steps below, with the relevant console
excerpts.

## Result

**15/15 iterations passed. No `overlayfs` error, no `-116`/`ESTALE` anywhere in the
console capture.** Step 5 (`jffs2reset -y`) was therefore never triggered.

One observation to flag: with `skip_cnss=1`, **Wi-Fi does not come up** — the
radios never appear, and our bring-up scripts then retry the driver load in a
loop. Excerpt in section 4. Please confirm whether that is expected for this
debug setting, and whether a run in that state still gives you the data you
wanted.

## Step 1 — boot argument

Set from the running system into the U-Boot environment (`u_env`, mtd20), so it
survives both reboot and factory reset:

```sh
fw_setenv bootargs "console=ttyMSM0,115200n8 cnss2.enable_mlo_support=1 cnss2.skip_cnss=1"
reboot
```

Confirmed active on every boot of the run:

```
[    0.000000] Kernel command line: console=ttyMSM0,115200n8 cnss2.enable_mlo_support=1 cnss2.skip_cnss=1 \
               ubi.mtd=rootfs root=mtd:ubi_rootfs rootfstype=squashfs rootwait \
               clk_ignore_unused vmalloc=1G
...
Loading cnss2:  enable_mlo_support=1 skip_cnss=1
[    8.232093] Skipping cnss_probe for device 0xfff9
[    8.232231] Skipping cnss_probe for device 0xfff7
```

and on the running system:

```
/sys/module/ipq_cnss2/parameters/skip_cnss = 1
/sys/class/remoteproc/{0,1,2}/state        = offline  offline  offline
ath* netdevs                               = 0
```

The Wi-Fi firmware partition still mounts normally under this setting:

```
[CBT] wifi_fw_mount: primaryboot=[], rootfs_primaryboot=[0]
[CBT] wifi_fw_mount: wifi fw partition is correct
[    8.486925] ubi: mtd23 is already attached to ubi0
 WIFI FW mount is successful
```

## Step 2 — console capture

Serial console captured from a Linux PC on `/dev/ttyMSM0` @ 115200 for the whole
run (attached). Setup under test:

| Item | Value |
|---|---|
| Board | `Qualcomm Technologies, Inc. IPQ5332/AP-MI01.3-C2` |
| Kernel | 5.4.213, SDK `spf12.5_csu1` |
| Firmware | 1.2.3.26080709, built 2026-08-07T16:23:17Z |
| Bootloader | U-Boot 11.7.31 `[IPQ5312].[SPF12.5].[CSU1]` |
| Run | 2026-08-08 11:25:46 → 11:51:33 local (~26 min) |

## Step 3 — 15-iteration factory-reset loop

Exactly as specified: trigger factory reset via the management API → wait for the
DUT to go offline → wait for it to come back online → confirm SSH **and**
HTTP/HTTPS → wait **10 s** → next reset.

| # | offline after | online after | SSH up | HTTP/HTTPS up | log scan |
|---|---|---|---|---|---|
| 1 | 5 s | 12 s | 0 s | 3 s | clean |
| 2 | 41 s | 12 s | 0 s | 3 s | clean |
| 3 | 41 s | 14 s | 0 s | 0 s | clean |
| 4 | 32 s | 14 s | 0 s | 0 s | clean |
| 5 | 24 s | 13 s | 0 s | 3 s | clean |
| 6 | 55 s | 14 s | 0 s | 0 s | clean |
| 7 | 28 s | 12 s | 0 s | 3 s | clean |
| 8 | 49 s | 13 s | 0 s | 3 s | clean |
| 9 | 31 s | 14 s | 0 s | 3 s | clean |
| 10 | 1 s | 0 s | **63 s** | 3 s | clean |
| 11 | 40 s | 14 s | 0 s | 3 s | clean |
| 12 | 40 s | 13 s | 3 s | 0 s | clean |
| 13 | 33 s | 12 s | 0 s | 3 s | clean |
| 14 | 48 s | 14 s | 0 s | **45 s** | clean |
| 15 | **147 s** | 13 s | 0 s | 3 s | clean |

Three timing outliers, none with any error in the log: **#10** dropped off 1 s
after the reset was accepted and answered ping immediately, then took 63 s to
accept SSH; **#14** took 45 s for HTTP/HTTPS against 0–3 s elsewhere; **#15**
took 147 s from accepted reset to going offline against 24–55 s elsewhere.

## Step 4 — monitoring for `overlayfs` and `-116`

Scanned the serial capture and 16 `dmesg` snapshots (baseline + one per
iteration, 480 KB) for `overlayfs`, `ESTALE`, and `-116`. **Zero matches.**

The only overlay-related messages are the expected UBIFS journal replay on each
boot after the reset:

```
[    6.518822] UBIFS (ubi0:3): recovery needed
[    6.582577] UBIFS (ubi0:3): recovery completed
[    6.582648] UBIFS (ubi0:3): UBIFS: mounted UBI device 0, volume 3, name "rootfs_data"
[    6.621151] mount_root: overlay filesystem has not been fully initialized yet
[    6.632213] mount_root: switching to ubifs overlay
```

Overlay and flash state after the run are healthy:

```
/dev/ubi0_3 on /overlay type ubifs (rw,noatime,assert=read-only,ubi=0,vol=3)
overlayfs:/overlay on / type overlay (rw,noatime,lowerdir=/,upperdir=/overlay/upper,workdir=/overlay/work)
ubi0: good PEBs: 1296, bad PEBs: 0, corrupted PEBs: 0
ubi1: good PEBs: 1220, bad PEBs: 0, corrupted PEBs: 0
```

## Step 5 — `jffs2reset -y`

Not executed: no `overlayfs -116` occurred, so the trigger condition was never
met.

## Observation — Wi-Fi does not come up with `skip_cnss=1`

Every boot in the run shows the same sequence. The radios are absent, VAP
creation fails, and the bring-up is then retried repeatedly:

```
wifi, wifi_physical_start(ath0)
cat: can't open '/sys/class/net/wifi0/mldphy_name': No such file or directory
[mlo] Fatal error, re-load driver
module is already loaded - qdf
ath0      No such device
Invalid tag '-cfg80211' for current mode.
cat: can't open '/sys/class/net/wifi0/phy80211/name': No such file or directory
command failed: No such file or directory (-2)
creating vap ath0
wlanconfig: ioctl: No such device
Device "ath0" does not exist.
FAIL
```

```
err athdiag_open_sys_interface failed (2) to open DIAG file (unknown_DIAG_device)
interface ath0 does not exist!
```

`brctl show` in this state has no `ath*` member, only the wired port. So the
15 clean iterations were run with the WLAN stack down throughout.

Two things we would like to confirm:

1. Is a down WLAN stack the intended state for `skip_cnss=1`, i.e. is this run
   still valid evidence for the overlayfs question you are chasing?
2. Since `skip_cnss=1` keeps the driver from attaching at all, it also keeps the
   original failure path out of the boot. Do you want a follow-up run **without**
   `skip_cnss` and with the serial console attached, so we capture the console
   log of a failing boot as well?

## Artifacts attached

- serial console capture for the full run
- 16 `dmesg` snapshots (baseline + per iteration)
- the loop script implementing steps 3–5

Thanks,
Jianrong
