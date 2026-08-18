# Case 08621084 — CNSS kernel panics on the CL_7200283 debug image, `skip_cnss` NOT set

Source: serial console capture (minicom), 2026-08-18.
Image under test: `fw_version=1.2.4  build_version=26081814  build_date=Tue Aug 18 21:41:43 UTC 2026`
`sdk_ver=spf12.5_csu1  build_target=CF  modelNumber=M60CF-EU`
Kernel: 5.4.213, IPQ5332, 32-bit ARM.

This image carries debug change CL_7200283, which removes the `CNSS_ASSERT()` from the
`rproc_boot()` failure path in `qca-cnss-local/main.c` (around line 5868).

## Precondition requested by QCA is satisfied

Every boot in the capture shows, verbatim:

```
[    0.000000] Kernel command line: console=ttyMSM0,115200n8 cnss2.enable_mlo_support=1 ubi.mtd=rootfs root=mtd:ubi_rootfs rootfstype=squashfs rootwait clk_ignore_unused vmalloc=1G
```

`cnss2.skip_cnss` is **absent**. The requested configuration (patch applied,
`skip_cnss` not set) is exactly what was under test.

## Result: the panic still reproduces, at TWO assert sites, neither of them the patched one

CL_7200283 removed the assert on the `rproc_boot()` error path only. Both panics
below fire from different `CNSS_ASSERT()` call sites, so the debug change could
not have prevented either.

### Panic A — `qmi/qmi.c:1735`, boot-time BDF download, t = 42.9 s

```
[   42.922743] ------------[ cut here ]------------
[   42.922764] kernel BUG at target-arm/linux-ipq53xx_ipq53xx_32/qca-cnss-local/qmi/qmi.c:1735!
[   42.926425] Internal error: Oops - BUG: 0 [#1] PREEMPT SMP ARM
[   43.259754] Hardware name: Generic DT based system
[   43.267786] Workqueue: cnss_driver_event cnss_driver_event_work [ipq_cnss2]
[   43.272368] PC is at cnss_wlfw_bdf_dnld_send_sync+0x1430/0x1460 [ipq_cnss2]
[   43.279224] LR is at cnss_wlfw_bdf_dnld_send_sync+0x1420/0x1460 [ipq_cnss2]
[   43.485278] [<3f174114>] (cnss_wlfw_bdf_dnld_send_sync [ipq_cnss2]) from [<3f15d830>] (cnss_driver_event_work+0x278/0x102c [ipq_cnss2])
[   43.559576] Code: ea000002 e51f0354 e30016c7 eb3fbb65 (e7f001f2)
[   43.572244] Kernel panic - not syncing: Fatal exception
```

Context: the stack area of the dump contains the string `IPQ5332/regdb.bin`, i.e.
this is the board-data / regdb firmware download step inside the CNSS driver
event workqueue during driver bring-up.

### Panic B — `main.c:3609`, userspace-triggered wifi start, t = 155.8 s

```
[  155.799862] ------------[ cut here ]------------
[  155.799878] kernel BUG at target-arm/linux-ipq53xx_ipq53xx_32/qca-cnss-local/main.c:3609!
[  155.803531] Internal error: Oops - BUG: 0 [#1] PREEMPT SMP ARM
[  156.117586] CPU: 2 PID: 15764 Comm: cfg80211tool.1 Tainted: P                  5.4.213 #0
[  156.148017] PC is at __cnss_subsystem_get+0x1b8/0x1f0 [ipq_cnss2]
[  156.561578] [<3f175e14>] (__cnss_subsystem_get [ipq_cnss2]) from [<67ba0038>] (ol_ath_soc_start+0x152c/0x15b4 [qca_ol])
[  156.569955] [<67ba0038>] (ol_ath_soc_start [qca_ol]) from [<67ba01d8>] (ol_ath_target_start+0x118/0x2b8 [qca_ol])
[  156.590843] [<67bdfec8>] (ol_ath_check_and_start_target [qca_ol]) from [<67b7c7d0>] (ol_ath_ucfg_setparam+0x288/0x1008 [qca_ol])
[  156.614520] [<675d1ff8>] (wlan_cfg80211_set_params [umac]) from [<675deb30>] (wlan_cfg80211_set_wificonfiguration+0x618/0x2904 [umac])
[  156.624723] [<675deb30>] (wlan_cfg80211_set_wificonfiguration [umac]) from [<3f6713c8>] (nl80211_vendor_cmd+0x158/0x744 [cfg80211])
[  156.754225] Code: eb3fb428 ea000001 e5940074 e8bd8070 (e7f001f2)
[  156.764990] Kernel panic - not syncing: Fatal exception
```

Context: this one is driven from **userspace**. A `cfg80211tool` vendor command
during wifi bring-up reaches `ol_ath_soc_start()`, which calls
`__cnss_subsystem_get()`; that function asserts instead of returning an error to
its caller. An unprivileged-to-root userspace configuration command can therefore
panic the box.

## Both panics take the same exit path

```
Kernel panic - not syncing: Fatal exception
... smem_panic_handler
APSS Panic: Sent shutdown request to Q6
Rebooting in 3 seconds..
```

and the following boot reports:

```
System Reset Reason : HLOS Panic [0x47]
Crashdump magic found, initializing dump activity..
```

followed by U-Boot TFTP of `EBICS0.BIN` (0x20000000 bytes) to the collection host.

## Observed trigger correlation

Both panics occurred on boots where the device configuration tree was empty or
unreadable — the console shows a flood of `uci: Entry not found`, `uci: I/O error`,
`Failed to commit config`, `Region= not found in list.`, and `SKU is ` (empty)
before each panic. That is consistent with the CNSS error paths being entered
because board-data / regulatory selection has no valid parameters to work with;
the driver then asserts rather than failing the operation.

## Secondary observation (separate defect, tracked separately)

After the panics the unit entered a repeating ~65-80 s boot→reboot cycle:

```
cat: can't open '/etc/hostname'
/usr/lib/lua/platform.lua:711: attempt to concatenate local 'name' (a nil value)
[/etc/rc.common] Region= not found in list.
cat: can't open '/sys/class/net/wifi0/mldphy_name'
[mlo] Fatal error, re-load driver
/lib/service_wifi/service_wifi.sh: return: line 612: Illegal number:
reboot: Restarting system
```

`firstboot -y` did not clear it (`/dev/ubi0_3 is mounted as /overlay, only erasing
files`). This is a platform config-recovery defect, not a CNSS defect; it is
recorded on our side and is not part of the CNSS report.

## Ask for QCA

1. `qmi.c:1735` (`cnss_wlfw_bdf_dnld_send_sync`) and `main.c:3609`
   (`__cnss_subsystem_get`) both `CNSS_ASSERT()` on recoverable error paths.
   Please confirm the failing condition at each line for this SPF12.5 CSU1
   `qca-cnss-local` revision.
2. A userspace vendor command (`cfg80211tool` → `ol_ath_soc_start`) reaching a
   `BUG()` is a denial-of-service on the platform. Please advise whether
   `__cnss_subsystem_get()` can return `-EIO`/`-ENODEV` to `ol_ath_soc_start()`
   instead of asserting.
3. CL_7200283 covers only the `rproc_boot()` site. Is a broader change planned
   that converts the remaining `CNSS_ASSERT()` sites in `main.c`/`qmi.c` into
   error returns?
