Hi Jason,

I implemented your FactoryResetConnectionStressTest.txt verbatim (same curl parameters,
the "result":"OK" + DeviceRestart accept criteria, your ping/wait timing, exit-code-only
factory.cgi verdict, and the dual-homed wired+Wi-Fi topology with the loop over Wi-Fi).

37 consecutive resets on M60PW-HK (S/N 67A10M24F00060, FW 1.2.3.26071709), no power cycle:
factory.cgi returned CURL_EXIT_CODE=0 and "Idle" every time. **Not reproduced.**

Two notes that affect how a cycle gets scored:

1) Our units take 86-133 s to drop off after an accepted FactoryReset (worst: 139 s).
   Your disconnect window is 90 s, so most of our cycles would time out at step 4.3
   before the reset even takes effect. We raised it to 180 s.

2) curl exit 7 covers two different failures: ECONNREFUSED ("Connection refused",
   the real bug - nothing listening on :443) and EHOSTUNREACH ("No route to host",
   the packet never left the PC). We hit the second twice; both times the DUT was
   healthy and the curl simply fired 1-13 s before the Wi-Fi DHCP lease completed
   after re-association - failing in ~250 ms while ping still reported UP, which
   looks exactly like the bug. **Could you log curl's error text, not just the code?**
   Your PC is dual-homed on the same subnet as ours, so some of the "4th-5th reset"
   failures may be this artifact.

Two asks:

1) **Could you set up AnyDesk on a DUT currently in the failed state so I can debug it
   live?** Once it is power-cycled the evidence is gone, and the state itself is what we
   need. A serial console capture from the failed unit would also work.

2) Your build is from April (1.0.18.26042406). **Does the issue still occur on the latest
   July builds?** If not, a recent commit may have addressed it and we should identify
   which. Caveat: the suspected root cause is still present in our current tree - lighttpd
   has no rc.d boot symlink, so its only start trigger is the one-shot LAN-ifup hotplug
   (/etc/hotplug.d/iface/50-lighttpd). If July passes for you it may be a timing shift
   rather than a fix. Either answer helps.

Thanks,
Jianrong
