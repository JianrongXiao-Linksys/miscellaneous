#!/bin/bash
#
# reset_web_test.sh — Reproduce & diagnose LinksysWRT issue #451
#   "[M60PW] Sometimes web GUI is not accessible after DUT is reset to default"
#
# Repro (from the issue): with the LAN cable kept connected and NO power cycle,
# repeatedly trigger a JNAP Factory Reset and after each reboot verify:
#   - DUT still pings          (expected: always OK, ICMP is kernel-side)
#   - DUT web UI :80 / :443    (bug: refused after ~4-5th consecutive reset)
#
# Root cause (confirmed against pinnacle/develop source + factory console capture):
#   lighttpd (the web server) is NOT enabled at boot — there is no rc.d S-symlink.
#   It is started ONLY by the one-shot LAN ifup hotplug /etc/hotplug.d/iface/50-lighttpd.
#   If that single start is missed/fails on a boot, nothing retriggers it until the
#   next LAN ifup, which only a power cycle provides. Ping keeps working because ICMP
#   is independent of lighttpd. curl/JNAP cannot self-recover (they talk to the dead
#   lighttpd — a catch-22).
#
# When this tool detects the failure it SSHes in and captures the smoking-gun state
# (no lighttpd process, 80/443 not LISTEN, missing error.log, hotplug log) to prove
# the root cause, then optionally recovers with `/etc/init.d/lighttpd start`.
#
# Usage:
#   ./reset_web_test.sh [-i DUT_IP] [-p SSH_PASS] [-u SSH_USER] [-n ITERATIONS]
#                       [-w BOOT_WAIT] [-t REACH_TIMEOUT] [--recover] [--no-ssh]
#
# Example:
#   ./reset_web_test.sh -i 192.168.1.1 -p 'admin' -n 15 --recover
#
set -u

# ---------------- defaults ----------------
DUT_IP="192.168.1.1"
SSH_USER="root"
# After factory reset the DUT boots UNCONFIGURED (admin password = "admin"), then
# Auto_Master takes effect (WAN present) and changes the admin password to
# devinfo.info.default_passphrase. For this build that master password is:
SSH_PASS="8xPghzqdr@"       # SSH login password once in master mode
JNAP_USER="admin"           # HTTP basic-auth user for JNAP
JNAP_PASS="8xPghzqdr@"      # HTTP basic-auth password once in master mode
ITERATIONS=15
BOOT_WAIT=180        # max seconds to wait for DUT to reboot & become pingable
REACH_TIMEOUT=90     # max seconds to wait for web (lighttpd LISTEN) after ping returns
AM_TIMEOUT=240       # max seconds to wait for Auto_Master to complete (mode->master)
JNAP_ACTION="http://linksys.com/jnap/core/FactoryReset"
DO_RECOVER=0         # on failure, run `/etc/init.d/lighttpd start` to recover
USE_SSH=1            # SSH diagnostics + auto-master gating (needs SSH_PASS)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"

# ---------------- arg parse ----------------
while [ $# -gt 0 ]; do
	case "$1" in
		-i) DUT_IP="$2"; shift 2;;
		-p) SSH_PASS="$2"; JNAP_PASS="$2"; shift 2;;   # sets both SSH + JNAP master password
		-P) JNAP_PASS="$2"; shift 2;;                   # override JNAP password only
		-u) SSH_USER="$2"; shift 2;;
		-n) ITERATIONS="$2"; shift 2;;
		-w) BOOT_WAIT="$2"; shift 2;;
		-t) REACH_TIMEOUT="$2"; shift 2;;
		-a) AM_TIMEOUT="$2"; shift 2;;
		--recover) DO_RECOVER=1; shift;;
		--no-ssh) USE_SSH=0; shift;;
		-h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0;;
		*) echo "Unknown arg: $1"; exit 2;;
	esac
done

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="$LOG_DIR/run_${RUN_TS}.log"

# ---------------- helpers ----------------
C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_RST=$'\033[0m'

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }
ok()   { log "${C_GRN}PASS${C_RST} $*"; }
bad()  { log "${C_RED}FAIL${C_RST} $*"; }
info() { log "${C_CYN}$*${C_RST}"; }

ping_ok() { ping -c1 -W2 "$DUT_IP" >/dev/null 2>&1; }

# web_ok: returns 0 if either :80 or :443 accepts a TCP/HTTP connection.
# We only care that the socket is LISTENing (bug = connection refused), so any
# HTTP status (including redirects/401) counts as "web up".
web_ok() {
	local code
	code=$(curl -sk -o /dev/null -m 5 -w '%{http_code}' "https://$DUT_IP/" 2>/dev/null)
	[ -n "$code" ] && [ "$code" != "000" ] && return 0
	code=$(curl -s  -o /dev/null -m 5 -w '%{http_code}' "http://$DUT_IP/" 2>/dev/null)
	[ -n "$code" ] && [ "$code" != "000" ] && return 0
	return 1
}

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o LogLevel=ERROR"
dut_ssh() {
	# runs remote command, echoes output; needs SSH_PASS
	sshpass -p "$SSH_PASS" ssh $SSH_OPTS "$SSH_USER@$DUT_IP" "$1" 2>&1
}
have_ssh() { [ "$USE_SSH" -eq 1 ] && [ -n "$SSH_PASS" ]; }

# JNAP result is OK only if it contains "OK". A response with _ErrorUnauthorized
# (wrong/missing auth) or any _Error* must NOT be treated as success.
jnap_result_ok() {
	echo "$1" | grep -q '"result"[[:space:]]*:[[:space:]]*"OK"'
}

# One JNAP FactoryReset POST with basic auth, on the given scheme. Echoes body.
jnap_factory_reset() {
	local scheme="$1" insecure=""
	[ "$scheme" = "https" ] && insecure="-k"
	local auth
	auth=$(printf '%s:%s' "$JNAP_USER" "$JNAP_PASS" | base64 | tr -d '\n')
	curl -s $insecure -m 12 -X POST \
		-H "Content-Type: application/json" \
		-H "X-JNAP-Action: $JNAP_ACTION" \
		-H "X-JNAP-Authorization: Basic $auth" \
		-d '{}' "$scheme://$DUT_IP/JNAP/" 2>&1
}

# trigger factory reset via JNAP (preferred: exactly what the issue uses).
# Master mode requires HTTP basic auth (admin:$JNAP_PASS). Falls back to SSH
# `jffs2reset -y && reboot` only if JNAP cannot be delivered/accepted.
trigger_factory_reset() {
	local out
	out=$(jnap_factory_reset https)
	if jnap_result_ok "$out"; then
		log "  JNAP FactoryReset accepted (https): $(echo "$out" | head -c 120)"
		return 0
	fi
	log "  https JNAP not OK ($(echo "$out" | head -c 100)); trying http :80"
	out=$(jnap_factory_reset http)
	if jnap_result_ok "$out"; then
		log "  JNAP FactoryReset accepted (http): $(echo "$out" | head -c 120)"
		return 0
	fi
	# If it came back _ErrorUnauthorized, the password is wrong — surface it clearly.
	if echo "$out" | grep -qi 'Unauthorized'; then
		bad "  JNAP returned Unauthorized — check -p/-P password (expected master pw '$JNAP_PASS')."
	fi
	if have_ssh; then
		log "  ${C_YEL}JNAP not accepted; falling back to SSH jffs2reset${C_RST}"
		dut_ssh "jffs2reset -y >/dev/null 2>&1; (sleep 1; reboot) &" >/dev/null 2>&1
		return 0
	fi
	bad "  Could not trigger factory reset (JNAP failed, no SSH fallback)."
	return 1
}

# wait until DUT stops responding (reboot started) then comes back to ping.
wait_reboot() {
	local waited=0
	# give it a moment to actually go down (best-effort, don't require it)
	local down=0
	for _ in $(seq 1 30); do
		if ! ping_ok; then down=1; break; fi
		sleep 1; waited=$((waited+1))
	done
	[ "$down" -eq 1 ] && log "  DUT went down after ${waited}s, waiting for reboot..." \
		|| log "  DUT never observed down (fast reboot?), waiting for stable ping..."
	# now wait for it to come back
	waited=0
	while [ "$waited" -lt "$BOOT_WAIT" ]; do
		if ping_ok; then
			# require 2 consecutive good pings to be sure it's really up
			sleep 2
			if ping_ok; then
				log "  DUT reachable again after ~${waited}s"
				return 0
			fi
		fi
		sleep 3; waited=$((waited+3))
	done
	bad "  DUT did not become pingable within ${BOOT_WAIT}s"
	return 1
}

# After a factory reset the DUT boots UNCONFIGURED (smart_mode.mode=0, pw=admin).
# With WAN present, Auto_Master runs (~30s delay + WAN-IP wait + up to ~120s
# BecomeMasterNode) and transitions to master (mode=2), setting the admin password
# to default_passphrase and auto_master::status -> stopped.
#
# The issue's step 4 ("confirm Web UI loads properly") assumes auto-master has
# completed. So before verifying web / doing the next reset we GATE on that here.
# Needs SSH. Without SSH we can only fixed-wait (best effort).
wait_auto_master() {
	if ! have_ssh; then
		log "  (no SSH) can't read auto-master state; fixed wait ${AM_TIMEOUT}s for it to settle"
		sleep "$AM_TIMEOUT"
		return 0
	fi
	local waited=0 mode st pw
	while [ "$waited" -lt "$AM_TIMEOUT" ]; do
		mode=$(dut_ssh "uci -q get linksys.smart_mode.mode" | tr -d '\r\n')
		st=$(dut_ssh   "sysevent get auto_master::status" | tr -d '\r\n')
		pw=$(dut_ssh   "uci -q get lsadmin.user.password" | tr -d '\r\n')
		# Complete when: node became master (mode!=0) AND auto-master no longer
		# running (stopped/failed) AND the admin password is no longer the default
		# "admin" (i.e. default_passphrase applied — matches our JNAP/SSH creds).
		if [ -n "$mode" ] && [ "$mode" != "0" ] \
		   && { [ "$st" = "stopped" ] || [ "$st" = "failed" ]; } \
		   && [ -n "$pw" ] && [ "$pw" != "admin" ]; then
			ok "  Auto_Master complete after ~${waited}s (mode=$mode status=$st, admin pw applied)"
			return 0
		fi
		log "  waiting auto-master... (${waited}s: mode='${mode:-?}' status='${st:-?}' pw_set=$([ "$pw" != admin ] && [ -n "$pw" ] && echo yes || echo no))"
		sleep 6; waited=$((waited+6))
	done
	bad "  Auto_Master did not complete within ${AM_TIMEOUT}s (mode='${mode:-?}' status='${st:-?}')"
	return 1
}

# On web failure, capture the diagnostic evidence proving the root cause.
diagnose_failure() {
	local iter="$1"
	local dfile="$LOG_DIR/diag_${RUN_TS}_iter${iter}.txt"
	info "  Capturing failure diagnostics -> $dfile"
	{
		echo "==== Issue #451 failure diagnostics ===="
		echo "time: $(date)"
		echo "iteration: $iter   DUT: $DUT_IP"
		echo "ping: $(ping_ok && echo UP || echo DOWN)"
		echo "web(:443 or :80): DOWN (connection refused)"
		echo
	} > "$dfile"

	if ! have_ssh; then
		echo "SSH diagnostics skipped (no password / --no-ssh)." >> "$dfile"
		cat "$dfile"; return
	fi

	{
		echo "---- /etc/init.d/lighttpd status ----"
		dut_ssh "/etc/init.d/lighttpd status 2>&1"
		echo
		echo "---- lighttpd process (expect: none) ----"
		dut_ssh "ps w 2>/dev/null | grep -v grep | grep lighttpd || echo 'NO lighttpd process'"
		echo
		echo "---- listening sockets 80/443 (expect: none) ----"
		dut_ssh "netstat -ltnp 2>/dev/null | grep -E ':80 |:443 ' || echo 'NOT LISTENING on 80/443'"
		echo
		echo "---- lighttpd config validation (expect: exit 0 / valid) ----"
		dut_ssh "lighttpd -tt -f /etc/lighttpd/lighttpd.conf 2>&1; echo exit=\$?"
		echo
		echo "---- /var/log/lighttpd/error.log (expect: missing => never started this boot) ----"
		dut_ssh "ls -l /var/log/lighttpd/error.log 2>&1; echo '--- tail ---'; tail -n 20 /var/log/lighttpd/error.log 2>&1"
		echo
		echo "---- boot rc.d symlink for lighttpd (expect: none => not enabled at boot) ----"
		dut_ssh "ls -l /etc/rc.d/*lighttpd* 2>&1 || echo 'NO rc.d symlink (not enabled at boot)'"
		echo
		echo "---- lighttpd hotplug log (the only start trigger) ----"
		dut_ssh "logread 2>/dev/null | grep -i lighttpd | tail -n 20 || echo 'no lighttpd logread entries'"
		echo
		echo "---- LAN iface state ----"
		dut_ssh "ubus call network.interface.lan status 2>/dev/null | grep -E '\"up\"|device' || ifstatus lan 2>/dev/null | head"
	} >> "$dfile" 2>&1

	cat "$dfile"

	# Verdict: is this the known root cause?
	if grep -q 'NO lighttpd process' "$dfile" && grep -qE 'exit=0|valid' "$dfile"; then
		bad "  ROOT CAUSE CONFIRMED: config VALID but lighttpd not running & 80/443 not listening."
		bad "  => lighttpd never started this boot (single LAN-ifup hotplug trigger, no boot service)."
	fi

	if [ "$DO_RECOVER" -eq 1 ]; then
		info "  --recover: starting lighttpd manually to confirm recovery..."
		dut_ssh "/etc/init.d/lighttpd start >/dev/null 2>&1; sleep 2"
		if web_ok; then
			ok "  Recovery worked: web is back after '/etc/init.d/lighttpd start' (proves start was simply missing)."
		else
			bad "  Recovery did NOT restore web — investigate config/cert path."
		fi
	fi
}

# ---------------- pre-flight ----------------
command -v sshpass >/dev/null || { echo "need: sshpass"; exit 1; }
command -v curl    >/dev/null || { echo "need: curl";    exit 1; }

info "======================================================================"
info " LinksysWRT #451 web-GUI-after-factory-reset reproduction test"
info " DUT=$DUT_IP  iterations=$ITERATIONS  boot_wait=${BOOT_WAIT}s am_wait=${AM_TIMEOUT}s"
info " ssh=$([ "$USE_SSH" -eq 1 ] && echo on || echo off) recover=$DO_RECOVER  master_pw='$JNAP_PASS' (unconfigured pw='admin')"
info " log: $RUN_LOG"
info "======================================================================"

if ! ping_ok; then bad "DUT $DUT_IP not pingable at start — aborting."; exit 1; fi
ok "Baseline: DUT pingable."
if web_ok; then ok "Baseline: web UI reachable."; else
	bad "Baseline: web UI NOT reachable — DUT already in failed state before test."
	have_ssh && diagnose_failure 0
	exit 1
fi

# ---------------- main loop ----------------
FAIL_ITER=0
for i in $(seq 1 "$ITERATIONS"); do
	info "---------- Factory Reset #$i / $ITERATIONS ----------"
	trigger_factory_reset || { bad "stop: cannot trigger reset"; break; }

	wait_reboot || { FAIL_ITER=$i; bad "iteration $i: DUT never came back (ping)"; break; }

	# ping check (issue step 3: expected always OK — ICMP is kernel-side)
	if ping_ok; then ok "iteration $i: ping OK"; else bad "iteration $i: ping FAILED"; fi

	# Gate on Auto_Master completing (issue step 4 assumes it has). This also
	# ensures the admin password is the master password before the NEXT reset's
	# authenticated JNAP call. A failure here is a different problem, not #451 —
	# but we still diagnose lighttpd since we're in the failing window.
	if ! wait_auto_master; then
		bad "iteration $i: Auto_Master did not complete — cannot fairly assess web yet"
		FAIL_ITER=$i
		diagnose_failure "$i"
		break
	fi

	# poll web up to REACH_TIMEOUT (issue step 4/8: web UI must load)
	w=0; webup=0
	while [ "$w" -lt "$REACH_TIMEOUT" ]; do
		if web_ok; then webup=1; break; fi
		sleep 3; w=$((w+3))
	done

	if [ "$webup" -eq 1 ]; then
		ok "iteration $i: web UI reachable (after ${w}s)"
	else
		bad "iteration $i: web UI REFUSED after ${REACH_TIMEOUT}s  <<< BUG REPRODUCED"
		FAIL_ITER=$i
		diagnose_failure "$i"
		break
	fi
done

# ---------------- summary ----------------
info "======================================================================"
if [ "$FAIL_ITER" -gt 0 ]; then
	bad "RESULT: bug reproduced on iteration #$FAIL_ITER of $ITERATIONS."
	bad "Ping stayed up, web stayed down = classic #451 signature."
	info "Diagnostics saved under: $LOG_DIR/diag_${RUN_TS}_iter${FAIL_ITER}.txt"
	info "Full run log: $RUN_LOG"
	exit 1
else
	ok "RESULT: completed $ITERATIONS factory resets, web recovered every time (no repro)."
	info "Full run log: $RUN_LOG"
	exit 0
fi
