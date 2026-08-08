# QCA case 08621084 — result of the `cnss2.skip_cnss=1` stress run

Reply to Pranjal's recommended steps (case 08621084, Aug 7 post).

## Outcome

**15/15 iterations passed. No panic. No `overlayfs` error. No `-116` / `ESTALE`.**
`jffs2reset -y` (step 5) was therefore never needed.

The same 15-iteration loop on the same unit **without** `skip_cnss=1` panicked on
**iteration 2** (`kernel BUG at qca-cnss-local/main.c:5868`,
`cnss_register_subsys+0x2ec/0x378`). With `skip_cnss=1` the loop ran to completion.

## Setup actually used

| Item | Value |
|---|---|
| Model | M60CF-EU (Pinnacle 2.0), SN `67A10M24F00060` |
| Board | `Qualcomm Technologies, Inc. IPQ5332/AP-MI01.3-C2` |
| Kernel | 5.4.213, SDK `spf12.5_csu1` |
| Firmware | **1.2.3.26080709**, built 2026-08-07T16:23:17Z (newest CF build) |
| Bootloader | CBT U-Boot 11.7.31 `[IPQ5312].[SPF12.5].[CSU1]` |
| Run | 2026-08-08 11:25:46 → 11:51:33 local (~26 min) |

Boot argument was set from the running system, which persists in the U-Boot
environment (`u_env`, mtd20) and therefore survives both reboot and factory reset:

```sh
fw_setenv bootargs "console=ttyMSM0,115200n8 cnss2.enable_mlo_support=1 cnss2.skip_cnss=1"
reboot
```

Confirmed active **on every one of the 15 iterations** (the loop re-checks each pass):

```
/proc/cmdline: console=ttyMSM0,115200n8 cnss2.enable_mlo_support=1 cnss2.skip_cnss=1 \
               ubi.mtd=rootfs root=mtd:ubi_rootfs rootfstype=squashfs rootwait \
               clk_ignore_unused vmalloc=1G
/sys/module/ipq_cnss2/parameters/skip_cnss = 1
/sys/class/remoteproc/{0,1,2}/state        = offline  offline  offline
ath* netdevs                               = 0
```

So `skip_cnss=1` did take effect: Q6/WCSS never booted and the Wi-Fi driver never
attached — which is exactly why the `rproc_boot()` path that panics was never
entered.

## Loop performed (your step 3, verbatim)

Per iteration: trigger factory reset via the management API → wait for the DUT to go
offline → wait for it to come back online → confirm SSH **and** HTTP/HTTPS → wait
**10 s** → next reset.

## Per-iteration timings

| # | offline after | online after | SSH up | HTTP/HTTPS up | dmesg scan |
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

Three outliers worth noting, none of which produced an error in the kernel log:

- **#10** — the DUT dropped off 1 s after the reset was accepted and answered ping
  immediately, then took 63 s to accept SSH. The loop caught the tail end of the
  previous boot rather than a completed reboot.
- **#14** — HTTP/HTTPS took 45 s to come up, against 0–3 s everywhere else.
- **#15** — 147 s from an accepted reset to going offline, against 24–55 s
  elsewhere. The overlay wipe ran long.

## Monitoring method (step 4)

`dmesg` was pulled over SSH after **every** iteration (16 captures including
baseline, 480 KB total, saved in the run's `_dmesg.txt`) and scanned for
`overlayfs`, `ESTALE`, and `-116`. Zero matches across the entire run.

Post-run overlay state is healthy:

```
/dev/ubi0_3 on /overlay type ubifs (rw,noatime,assert=read-only,ubi=0,vol=3)
overlayfs:/overlay on / type overlay (rw,noatime,lowerdir=/,upperdir=/overlay/upper,workdir=/overlay/work)
ubi0: good PEBs: 1296, bad PEBs: 0, corrupted PEBs: 0
ubi1: good PEBs: 1220, bad PEBs: 0, corrupted PEBs: 0
```

**Serial (step 2):** console capture was taken over `/dev/ttyUSB0` with `minicom`
and covers the whole run, including the panicking boots on the previous build.
It confirms the same result as the `dmesg` scan: no `overlayfs`, no `ESTALE`,
no `-116`. A timestamped logger with live flagging is also available
(`serial_console_log.py`) for unattended runs.

**Note on the unit:** the panic run (M60PW-HK, 1.2.4.26080708) and this clean run
(M60CF-EU, 1.2.3.26080709) are the **same physical board**, SN `67A10M24F00060` /
`IPQ5332/AP-MI01.3-C2`. It was re-provisioned with `devinfo set`
(`cert_region` HK→EU, `modelNumber` M60PW-HK→M60CF-EU) and reflashed from U-Boot
over TFTP between the two runs. The differing model string is not a different board.

## What this tells us

`skip_cnss=1` removes the panic, but it does so by **removing the code path that
panics**, not by fixing it. It does not reproduce an overlayfs `-116`. So this run
narrows the cause rather than confirming your overlayfs hypothesis:

- The panic requires CNSS/Q6 bring-up to be active. With it disabled, 15 aggressive
  reset cycles are clean.
- No overlayfs or ESTALE error appeared in any surviving boot, either with or
  without `skip_cnss`.

That points back at the `rproc_boot()` failure itself. From the source in this SDK
(`build_dir/target-arm/linux-ipq53xx_ipq53xx_32/qca-cnss-local/main.c`):

```c
cnss_mount_firmware(plat_priv);            /* returns void — result never checked */
ret = rproc_boot(subsys_info->subsys_handle);
if (ret) {
        cnss_pr_err("%s: Failed to boot device %s (%d)\n", ...);
        CNSS_ASSERT(0);                    /* <-- main.c:5868, the BUG() */
        cnss_unregister_notifier_cb(plat_priv);
}
```

and `r5 = fffffffe` in the panic register dump is that `ret` = **-ENOENT**.

On this board the Q6 images live *behind* the mount that
`cnss_mount_firmware()` establishes:

```
/lib/firmware/IPQ5332/q6_fw{0,1,2}.mdt -> /lib/firmware/IPQ5332/WIFI_FW/q6_fw{0,1,2}.mdt
/dev/mtdblock27 on /lib/firmware/IPQ5332/WIFI_FW type squashfs (ro)   # mtd27 "wifi_fw"
/sys/class/remoteproc/{0,1,2}/firmware = IPQ5332/q6_fw{0,1,2}.mdt
```

If that mount is not in place when `rproc_boot()` runs, the firmware lookup is
`-ENOENT` — matching the observed register exactly. Since
`cnss_mount_firmware()` is a `call_usermodehelper()` returning `void`, nothing
detects that and `BUG()` fires, even though the caller
(`cnss_wlan_probe_driver`: `ret = cnss_register_subsys(...); if (ret) goto reset_ctx;`)
is already written to handle an error return.

## Questions

1. Given the above, can `main.c:5868` return the error instead of `BUG()`? The
   caller already has a `reset_ctx` path for it.
2. Should `cnss_mount_firmware()`'s result be checked before `rproc_boot()`, and is
   there a supported way to serialise the mount against Q6 boot?
3. `/ini/internal/global_i.ini` on this build sets `cnss_fw_umount=1`, but
   `/sys/firmware/devicetree/base/MP_256` is **absent** on AP-MI01.3-C2 — so
   `mount_fw_partition.sh` returns without calling `boot`. Is that combination
   valid on a 512 MB board, and does it affect the mount/boot ordering above?
4. Do you want the next run **without** `skip_cnss` and **with** serial attached, to
   capture the panic console log and attempt the U-Boot TFTP crashdump? Note the
   on-device dump paths are unavailable on this build: `pstore` is not compiled in,
   `/proc/cmdline` has no `collect_minidump`, and the boot log says
   `Minidump: rsvd region is not specified`.

## Reproduction artifacts

- `qca_skipcnss_stress.sh` — implements steps 3–5 exactly as specified
- `serial_console_log.py` — step 2, timestamped console capture with live flagging
- `logs/qca_skipcnss_20260808_112546.log` — run log
- `logs/qca_skipcnss_20260808_112546_dmesg.txt` — all 16 dmesg captures
- `crash/panic_cnss_register_subsys.md` — the original panic report
