# Kernel panic — cnss_register_subsys BUG during factory-reset stress

> **Update 2026-08-08 — also reproduces on CF.** With `cnss2.skip_cnss=1` rolled
> back, firmware **1.2.3.26080709 (`build_target=CF`, M60CF-EU)** panicked on
> **iteration 2** of `reset_web_test.sh --factory-flow`, same `main.c:5868`, same
> `modprobe`/`init_ath_ahb_3_0` call path. That run reported
> `r5 = fffffff4` = **-ENOMEM**, where the capture below reports
> `r5 = fffffffe` = **-ENOENT** — so the `rproc_boot()` error value **varies between
> runs**. Details: `repro_cf_20260808.md`.

## Summary

Repeated factory reset via the network API triggers a **kernel BUG in the Qualcomm
CNSS platform driver** while the Wi-Fi module is being loaded. The unit panics, the
next boot reports `HLOS Panic [0x47]`, U-Boot finds crashdump magic, and the board
stops at the U-Boot prompt (does not auto-recover).

Reproduced on the **2nd** factory-reset iteration.

## Environment

| Item | Value |
|---|---|
| Model | M60PW-HK (Pinnacle 2.0) |
| SoC | IPQ5332 — kernel reports `CPU: IPQ5322, SoC Version: 1.1` |
| Board | `Qualcomm Technologies, Inc. IPQ5332/AP-MI01.3-C2`, machid `0x8060102` |
| Kernel | Linux 5.4.213, ARMv7, SMP PREEMPT, 4 CPUs |
| SDK | `spf12.5_csu1` |
| Firmware | `fw_version=1.2.4`, `build_version=26080708`, built Fri Aug 7 15:41:20 UTC 2026 |
| Bootloader | U-Boot 2016.01 (Mar 24 2025), CBT U-Boot 11.7.31 `[IPQ5312].[SPF12.5].[CSU1]` |
| XBL | `BOOT.XF.0.3.1.1-00111-IPQ90xxLZB-1`, `IPQ5332LA` |
| cmdline | `console=ttyMSM0,115200n8 cnss2.enable_mlo_support=1 ubi.mtd=rootfs root=mtd:ubi_rootfs rootfstype=squashfs rootwait clk_ignore_unused vmalloc=1G` |
| Flash | Serial NAND GD5F4GM8REYIG, 512 MiB |
| RAM | 512 MiB (416 MiB available to kernel) |

## The panic

Occurs at **~41.6 s uptime**, i.e. during boot, while `modprobe` is inserting the
Wi-Fi module and userspace init is still running.

```
[   41.648034] ------------[ cut here ]------------
[   41.648054] kernel BUG at target-arm/linux-ipq53xx_ipq53xx_32/qca-cnss-local/main.c:5868!
[   41.651716] Internal error: Oops - BUG: 0 [#1] PREEMPT SMP ARM
[   41.962563] CPU: 1 PID: 13339 Comm: modprobe Tainted: P                  5.4.213 #0
[   41.992470] PC is at cnss_register_subsys+0x2ec/0x378 [ipq_cnss2]
[   41.997337] LR is at cnss_register_subsys+0x2ec/0x378 [ipq_cnss2]
[   42.003449] pc : [<3f15f140>]    lr : [<3f15f140>]    psr: 60000013
[   42.015589] r10: 3f1ae008  r9 : 00000000  r8 : 5f66c6c0
[   42.020810] r7 : 5efe5400  r6 : 00000000  r5 : fffffffe  r4 : 5e633040
[   42.026008] r3 : 00000000  r2 : 00000000  r1 : 00000007  r0 : 00000021
[   42.286861] ---[ end trace 8a00a3a19c048035 ]---
[   42.292941] Kernel panic - not syncing: Fatal exception
```

Call stack (faulting CPU):

```
cnss_register_subsys+0x2ec/0x378 [ipq_cnss2]
cnss_wlan_probe_driver+0xa8/0x21c  [ipq_cnss2]
pld_register_driver+0x11c/0x154    [qca_ol]
init_ath_ahb_3_0+0xc/0x80          [wifi_3_0]
init_module+0x70/0x1000            [wifi_3_0]
do_one_initcall+0x78/0x1bc
do_init_module+0x38/0x1c8
sys_init_module+0x160/0x1a0
ret_fast_syscall
```

`Code: e5941bf8 e59f008c e30126ec eb400f5a (e7f001f2)` — the trapping instruction
`e7f001f2` is the ARM `BUG()` encoding, so this is a deliberate `BUG_ON`/`BUG()` in
`main.c:5868`, not a stray dereference.

**Key register:** `r5 = fffffffe` = **-2 = -ENOENT**. A subsystem registration call
returned `-ENOENT` and the driver responded with `BUG()` instead of propagating the
error. `r0 = 0x21`, `r1 = 0x07`.

### The faulting line, from the source

`main.c:5868` in `cnss_register_subsys()` is the `CNSS_ASSERT(0)` on the
`rproc_boot()` failure path:

```c
subsys_info->subsys_handle = plat_priv->rproc_handle;
plat_priv->esoc_info.modem_notify_handler = cnss_register_notifier_cb(plat_priv);

cnss_mount_firmware(plat_priv);                 /* returns void — see below */
ret = rproc_boot(subsys_info->subsys_handle);
if (ret) {
        cnss_pr_err("%s: Failed to boot device %s (%d)\n",
                    __func__, plat_priv->device_name, ret);
        CNSS_ASSERT(0);                         /* <-- main.c:5868, the BUG() */
        cnss_unregister_notifier_cb(plat_priv);
}
```

So `r5 = -ENOENT` is **`rproc_boot()`'s return value**: the Q6/WCSS remoteproc
failed to boot with `-ENOENT` and the driver panicked instead of returning the
error to its caller. Note `cnss_wlan_probe_driver()` already has a working error
path for this — `ret = cnss_register_subsys(...); if (ret) goto reset_ctx;` — so
the `BUG()` fires *before* an error return that the caller is prepared to handle.

Two things make `-ENOENT` reachable here:

1. **`cnss_mount_firmware()` returns `void`.** It is a `call_usermodehelper()` of
   `/lib/wifi/mount/mount_fw_partition.sh` (`MOUNT_PATH`, `main.h:825`), which
   mounts the `wifi_fw` partition that holds the Q6 images. Its result is never
   checked, so if the mount has not completed, `rproc_boot()` is called anyway
   and cannot find its firmware.
2. **The Q6 firmware files live behind that mount.** On the DUT:
   `/lib/firmware/IPQ5332/q6_fw{0,1,2}.mdt` are symlinks into
   `/lib/firmware/IPQ5332/WIFI_FW/`, which is `/dev/mtdblock27` (`wifi_fw`)
   mounted squashfs read-only. `remoteproc{0,1,2}` name those exact `.mdt` files
   as their `firmware`. If the mount is absent or torn down, the firmware lookup
   is `-ENOENT` — matching `r5` exactly.

`CNSS_ASSERT` (`cnss_common/cnss_common.h:269`) is
`if (!cond && cnss_wait_for_rddm_complete(plat_priv)) { … BUG_ON(1); }`, which is
consistent with the ~13 s gap between the `[41.6]` BUG and the `[42.8]`
`APSS Panic: Sent shutdown request to Q6`.

Earlier in the same boot, two CNSS-relevant lines appear:

```
[    0.125997] Minidump: rsvd region is not specified
[    8.175706] cnss[2]:  INFO: Platform driver probed successfully. plat 0x0c399a54 tgt 0xfff9
[    8.178632] cnss[61]: INFO: Platform driver probed successfully. plat 0xedcf39d0 tgt 0xfff7
```

Also present every boot (may or may not be related, but worth QCA's attention):

```
[    0.000000] OF: reserved mem: OVERLAP DETECTED!
[    0.000000] q6_code_data@4A900000 (0x4a900000--0x4bd00000) overlaps with q6_mem_regions@4A900000 (0x4a900000--0x4ea00000)
[    0.000000] OF: reserved mem: OVERLAP DETECTED!
[    0.000000] q6_mem_regions@4A900000 (0x4a900000--0x4ea00000) overlaps with q6_ipq5332_data@4BD00000 (0x4bd00000--0x4ce00000)
```

Other CPUs at panic time were doing ordinary work, which confirms this happened
mid-init rather than at idle:

- CPU0 — PID 13850 `service_lldpd.s`, inside `squashfs_readpage` → `xz_dec_run` (executing a binary off squashfs)
- CPU2 — PID 13848 `pgrep`, in `lockref_put_return`
- CPU3 — idle

Post-panic:

```
[   42.792432] smem desc phys addr(0x4a83d1b8)
[   42.804402] APSS Panic: Sent shutdown request to Q6
[   47.833057] Rebooting in 3 seconds..
```

Next boot confirms the panic and stops for dump collection:

```
B -   1077870 - System Reset Reason : HLOS Panic [0x47]
...
Crashdump magic found, initializing dump activity..
Hit any key within 10s to stop dump activity...resetting ...
```

The unit then landed at the `IPQ5332#` U-Boot prompt with `boot_count=1` — it did
**not** return to a booted state on its own.

## Reproduction

Driver: `reset_web_test.sh --factory-flow` (this repo). 15–30 iterations configured;
panic hit on iteration **2**.

Loop per iteration:

1. **Trigger factory reset** — HTTP POST to the DUT management API (12 s timeout).
   SSH `jffs2reset -y; reboot` as fallback.
2. **Wait for DUT to go down** — ping 1/s until no reply, timeout 150 s.
3. **Wait for DUT to return** — ping 1/s. In `--factory-flow` this returns on the
   **first** successful reply (no confirmation delay).
4. **Confirm ping.**
5. *(skipped in `--factory-flow`)* wait via SSH for post-reset provisioning
   (Wi-Fi configuration and related init) to complete, timeout 240 s.
6. **Confirm web server listening** — `curl https://<DUT>/` then `http://`, 5 s each,
   polled up to 90 s.
7. **Next iteration immediately** — only a 10 s grace in `--factory-flow`.

Because step 5 is skipped and step 3 returns on the first ping, **reset N+1 is issued
while boot N is still initialising**. Flash erase and re-mount therefore overlap early
bring-up — network, Wi-Fi driver load, NSS/CNSS init. This matches production-line
station timing. The panic lands exactly in that window: `modprobe` of `wifi_3_0` at
~41 s while `service_lldpd.sh` and `pgrep` are still executing.

Observed timeline from the run log:

```
10:50:32  baseline: ping OK, web OK
10:50:32  ---- Factory Reset #1 / 30 ----
10:50:35  JNAP FactoryReset accepted (https, pw='12345Asdf@')
10:50:40  DUT went down after 3s
10:51:20  DUT reachable again after ~14s (first ping; factory-flow)
10:51:33  iteration 1 checks PASSED
10:51:33  ---- Factory Reset #2 / 30 ----
10:51:34  JNAP FactoryReset accepted (https, pw='admin')
10:51:37  DUT went down after 1s
          -> panic during the ensuing boot
```

Note iteration 1 returned to ping in **14 s** and reset #2 was fired **1 s** after
acceptance — the DUT was nowhere near finished initialising.

## What to ask QCA

1. **Why does `rproc_boot()` return `-ENOENT`** when a factory reset is issued 1 s
   after the previous boot began — and why is that a `BUG()` rather than an error
   return? `cnss_wlan_probe_driver()` already handles a non-zero return from
   `cnss_register_subsys()` (`goto reset_ctx`), so the `BUG()` at `main.c:5868`
   discards a recoverable path. Is there a reason this must be fatal?
2. **`cnss_mount_firmware()` returns `void`** and is called immediately before
   `rproc_boot()`. Since the Q6 `.mdt` files are symlinks into the `WIFI_FW`
   squashfs mount that this helper establishes, a failed or incomplete mount
   produces exactly the observed `-ENOENT`. Should the mount result be checked
   before `rproc_boot()`, and is there a supported way to serialise the two?
3. Is `cnss_register_subsys` safe to enter when the previous boot's CNSS/Q6 state was
   torn down abruptly (prior panic / reset during init)? Reset #2 was issued 1 s after
   the API accepted it, so shutdown was not orderly.
4. Are the `q6_*` reserved-memory OVERLAP warnings in the device tree expected on
   AP-MI01.3-C2, and can they affect CNSS subsystem registration?
5. Interaction with `cnss2.enable_mlo_support=1` on this 2-radio platform
   (`cnss[2]` tgt 0xfff9 and `cnss[61]` tgt 0xfff7 both probe).
6. The FW-umount feature is enabled in `/ini/internal/global_i.ini`
   (`cnss_fw_umount=1`) but `/sys/firmware/devicetree/base/MP_256` is **absent** on
   this board, so `mount_fw_partition.sh` returns without calling `boot`. Is
   `cnss_fw_umount=1` valid on a 512 MB AP-MI01.3-C2, and does the mismatch affect
   the mount/boot ordering above?

## Crash dump availability — IMPORTANT

On-device dump collection is **not** usable on this build:

- `pstore` is **not** in `/proc/filesystems` and `/sys/fs/pstore` does not exist —
  not built into this kernel.
- `/proc/cmdline` has **no** `collect_minidump` flag, so `/etc/init.d/minidump2nvmem`
  (`START=99`) exits immediately.
- Boot log: `Minidump: rsvd region is not specified`.

U-Boot **does** report `Crashdump magic found, initializing dump activity..` and offers
a 10 s window, with `serverip=192.168.1.254` in the U-Boot environment. So the
supported path is **TFTP dump upload to 192.168.1.254 from U-Boot** — a TFTP server must
be listening at that address, and the 10 s prompt must not be interrupted.

**Serial console capture is required** for the backtrace: the panic never reaches
syslog, and `logread` on this build wraps within seconds of boot.
