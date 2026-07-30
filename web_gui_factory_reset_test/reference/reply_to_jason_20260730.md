Hi Jason,

Thanks for the command and sequence reference — I implemented your document verbatim
into our test harness (same curl parameters, the "result":"OK" + DeviceRestart accept
criteria, the 2-failed-ping / 20 s / 3-good-ping timing, the exit-code-only factory.cgi
verdict, and the dual-homed wired+Wi-Fi topology with the loop running over Wi-Fi).

Result: I have now run a large number of consecutive JNAP factory resets and I still
cannot reproduce the failure.

  Unit under test : M60PW-HK, S/N 67A10M24F00060
  Firmware        : 1.2.3.26071709 (2026-07-17)
  Topology        : test PC has both wired and Wi-Fi on the DUT LAN; ping + curl over Wi-Fi
  Sequence        : your FactoryResetConnectionStressTest.txt, step for step
  Result          : 36 consecutive resets, factory.cgi returned CURL_EXIT_CODE=0 and
                    "Idle" every time. No power cycle at any point.

Two findings from the runs that are worth sharing, because they affect how your tool
scores a cycle:

1) Our units take 86-133 s to actually drop off the network after an accepted
   FactoryReset (worst observed: 139 s). Your documented disconnect window is 90 s, so
   on hardware like ours the majority of cycles would time out at step 4.3 before the
   reset has even taken effect. We had to raise that window to 180 s to get clean runs.

2) curl exit code 7 covers two different failures, and only one of them is this bug:
     - ECONNREFUSED ("Connection refused") - the packet reached the DUT and nothing is
       listening on :443. This is the real issue.
     - EHOSTUNREACH ("No route to host") - the packet never left the test PC.
   We hit the second one twice, and both times it was our own Wi-Fi client: the DUT was
   completely healthy, but the curl fired 1-13 seconds before the Wi-Fi DHCP lease
   completed after re-association. It failed in ~250 ms, while ping still reported UP -
   which looks exactly like the bug signature. A 15 s settle and one retry succeeded
   both times.
   Since your tool judges the exit code alone, and your test PC is dual-homed on the
   same subnet as ours, it is possible that some of the "4th or 5th reset" failures are
   this artifact rather than the web server being down. Could you log curl's error
   *text* (not just the code) on failure? That would settle it in one run.

For clarity: we did reproduce a genuine failure once, on a different M60PW-HK, under
more aggressive timing than your sequence (next reset fired as soon as ping returned).
In that state ping was UP while :443, :80 and :22 were all refused - so the whole
late-boot service batch for that boot had failed, not only lighttpd. That is consistent
with our root-cause theory: lighttpd has no rc.d boot symlink, so procd never starts it;
its only trigger is the one-shot LAN-ifup hotplug (/etc/hotplug.d/iface/50-lighttpd).
If that single event is missed on a given boot, nothing re-fires it until the next LAN
ifup, which in practice means a power cycle.

Two requests so we can close this out:

1) Could you set up an AnyDesk session on a DUT that is currently in the failed state,
   so I can debug it live? Once the unit is power-cycled the evidence is gone, and the
   state itself is what we need - which services are running, what is listening, and
   what the boot log shows. If AnyDesk is not possible, a serial console capture from
   the failed unit would also work.

2) Your reproduction used firmware 1.0.18.26042406, built in April. Have you seen the
   same failure on the latest July builds? If it does not reproduce there, a recent
   commit may already have addressed it, and we would want to identify which one.
   I should flag that the suspected root cause is still present in our current tree -
   there is still no rc.d enable symlink for lighttpd - so if July passes for you, it
   may be a timing shift rather than a real fix. Either answer is useful.

Thanks,
Jianrong
