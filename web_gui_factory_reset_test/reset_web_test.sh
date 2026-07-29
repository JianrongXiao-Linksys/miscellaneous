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
#                       [--no-wan] [--factory-cgi]
#
# Example (normal, WAN connected -> Auto_Master runs):
#   ./reset_web_test.sh -i 192.168.1.1 -p '8xPghzqdr@' -n 15 --recover
#
# Example (factory Born-On SOP: WAN UNPLUGGED, LAN connected):
#   ./reset_web_test.sh -i 192.168.1.1 -p admin -n 15 --no-wan --factory-cgi --recover
#
# --no-wan  : WAN cable removed. Auto_Master never runs, so the unit stays UNCONFIGURED
#             (linksys.smart_mode.mode=0) and the web/admin password stays 'admin'
#             permanently. Skips the Auto_Master gate and tries 'admin'/no-auth first.
# --factory-cgi : after each reset also GET /factory.cgi and require the Born-On status
#             to read 'Idle' (per the Industrial Cloud / Born-On factory validation SOP).
#             This exercises lighttpd's CGI handler, not just the TCP socket.
# --factory-flow : replicate the production station timing EXACTLY (implies --no-wan
#             and --factory-cgi). The station proceeds the moment the DUT answers
#             ping — it does NOT wait for Auto_Master or full init. After a short
#             grace (--grace, default 10s) it does an HTTPS GET of factory.cgi then a
#             JNAP request on port 80; a refusal there is the recorded factory failure.
#             Firing the next reset this early is what makes the lighttpd
#             single-LAN-ifup start race actually lose (reporter: fails on 4th-5th).
# --grace N : seconds to wait after ping before the factory checks (default 10)
#
# Example (reporter's exact reproduction conditions):
#   ./reset_web_test.sh -i 192.168.1.1 -p admin -n 20 --factory-flow
#
# --jason-flow : replicate the reporter's own stress test byte-for-byte, per
#             FactoryResetConnectionStressTest.txt (implies --no-wan + --factory-cgi).
#             Differences from --factory-flow, all taken from that document:
#               * reset POSTed to http://IP/JNAP/ (:80) first, not https
#               * response must contain BOTH "result":"OK" AND "DeviceRestart"
#               * disconnect check: 2 failed pings, 90s timeout  (doc 4.3)
#               * wait 20s after the DUT is confirmed unreachable (doc 4.4)
#               * reconnect check: 3 successful pings, then Wi-Fi reconnect + 60s
#                 retry if the first window times out                (doc 4.5)
#               * wait 10s after pingable, no Auto_Master check      (doc 4.6)
#               * factory.cgi with an Authorization: Basic header, --connect-timeout 5
#                 --max-time 15, and ONLY the curl exit code is judged — their tool
#                 does not check for 'Idle' (doc 2, 4.7-4.8)
#               * wait 10s before the next cycle                     (doc 4.9)
# --iface IF: bind pings and curl to this interface. The reporter ran the whole loop
#             over Wi-Fi (both wired and Wi-Fi were connected), so matching the
#             traffic path matters — a Wi-Fi client also has to re-associate after
#             every reset, which widens the window the race needs.
# --ssid S  : SSID to reconnect to on a ping timeout (the doc 4.5 retry path).
#
# Example (reporter's exact tool, over Wi-Fi):
#   ./reset_web_test.sh -i 192.168.1.1 -p 'Da8@Wfqes4' -n 20 --jason-flow \
#       --iface wlp0s20f3 --ssid Linksys00002 --no-ssh
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
NO_WAN=0             # factory-SOP mode: WAN unplugged -> no Auto_Master, pw stays 'admin'
CHECK_FACTORY_CGI=0  # also verify /factory.cgi Born-On status returns 'Idle' after reset
FACTORY_FLOW=0       # replicate the factory station flow exactly (see below)
FF_GRACE=10          # --factory-flow: seconds to wait after ping before checking web
# Additional per-unit default_passphrase candidates. default_passphrase differs per
# device, so keep the known ones here and let --extra-pass add more at runtime.
EXTRA_PASS="Da8@Wfqes4"
DOWN_WAIT=150        # max seconds to wait for the DUT to drop off after an accepted reset

# ---- --jason-flow: the reporter's documented stress test, verbatim ----
# Source: FactoryResetConnectionStressTest.txt (Jason, Linksys). Every constant below
# is taken from that document so our run is comparable to theirs 1:1. Notable
# differences from our own --factory-flow are called out in the README.
JASON_FLOW=0
JF_DOWN_TIMEOUT=90   # doc 4.3: disconnect-check timeout
JF_DOWN_FAILS=2      # doc 4.3: require two failed ping checks
JF_AFTER_DOWN=20     # doc 4.4: wait 20s after the DUT is confirmed unreachable
JF_UP_OKS=3          # doc 4.5: require three successful ping checks
JF_UP_TIMEOUT=120    # doc 4.5: "maximum initial wait ... controlled by test config"
JF_UP_RETRY=60       # doc 4.5: on timeout, reconnect Wi-Fi and retry for another 60s
JF_AFTER_UP=10       # doc 4.6: wait 10s after pingable, no Auto_Master check
JF_CYCLE_WAIT=10     # doc 4.9: wait 10s before the next Factory Reset cycle
IFACE=""             # bind ping/curl to this interface (Jason ran the loop over Wi-Fi)
WIFI_SSID=""         # --ssid: reconnect to this SSID on ping timeout (doc 4.5 retry)
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
		--no-wan) NO_WAN=1; shift;;               # factory SOP: WAN unplugged, no Auto_Master
		--factory-cgi) CHECK_FACTORY_CGI=1; shift;;
		--factory-flow) FACTORY_FLOW=1; NO_WAN=1; CHECK_FACTORY_CGI=1; shift;;
		--grace) FF_GRACE="$2"; shift 2;;
		--extra-pass) EXTRA_PASS="$EXTRA_PASS $2"; shift 2;;
		--jason-flow) JASON_FLOW=1; NO_WAN=1; CHECK_FACTORY_CGI=1; shift;;
		--iface) IFACE="$2"; shift 2;;
		--ssid) WIFI_SSID="$2"; shift 2;;
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

# Jason ran the whole stress loop over the Wi-Fi link to the DUT, not the wired LAN.
# --iface binds our pings and curl requests to a chosen interface so the traffic path
# matches. Empty = default routing (wired), which is what we used before.
ping_ok() {
	if [ -n "$IFACE" ]; then
		ping -I "$IFACE" -c1 -W2 "$DUT_IP" >/dev/null 2>&1
	else
		ping -c1 -W2 "$DUT_IP" >/dev/null 2>&1
	fi
}

# curl args for interface binding (used by every request when --iface is given).
curl_iface() { [ -n "$IFACE" ] && printf '%s' "--interface $IFACE"; }

# doc 4.5 retry: "reconnect the test PC to the DUT SSID and retry for another 60s".
# Their C++ program did this; we do the nmcli equivalent when --ssid is supplied.
wifi_reconnect() {
	[ -z "$WIFI_SSID" ] && { log "  (no --ssid given; skipping Wi-Fi reconnect step)"; return 1; }
	log "  reconnecting test PC to SSID '$WIFI_SSID' (doc 4.5 retry path)"
	nmcli device wifi connect "$WIFI_SSID" ${IFACE:+ifname "$IFACE"} >/dev/null 2>&1
	local rc=$?
	[ "$rc" -eq 0 ] && log "  Wi-Fi reconnected" || bad "  Wi-Fi reconnect failed (rc=$rc)"
	return $rc
}

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

# In NO_WAN (factory SOP) mode Auto_Master never runs, so the admin/root password
# stays "admin" instead of becoming the default passphrase. Which one is live
# depends on the mode, so try each and cache whichever authenticates.
SSH_PASS_OK=""
dut_ssh() {
	# runs remote command, echoes output; needs SSH_PASS
	if [ -n "$SSH_PASS_OK" ]; then
		sshpass -p "$SSH_PASS_OK" ssh $SSH_OPTS "$SSH_USER@$DUT_IP" "$1" 2>&1
		return
	fi
	local p out
	for p in $([ "$NO_WAN" -eq 1 ] && echo "admin $SSH_PASS" || echo "$SSH_PASS admin"); do
		out=$(sshpass -p "$p" ssh $SSH_OPTS "$SSH_USER@$DUT_IP" "$1" 2>&1)
		if ! echo "$out" | grep -qiE 'permission denied|authentication fail'; then
			SSH_PASS_OK="$p"
			echo "$out"
			return
		fi
	done
	echo "$out"
}
have_ssh() { [ "$USE_SSH" -eq 1 ] && [ -n "$SSH_PASS" ]; }

# Log lighttpd's actual state EVERY iteration (per request): is the process
# running and are :80/:443 listening? This is the crux of #451 — in the failure
# state (a7c550a6) lighttpd was NOT running and 80/443 were not LISTEN even though
# ping worked. Logging it every pass proves the correlation (up when web passes,
# absent when web is refused). Echoes a one-line summary; returns 0 if running.
log_lighttpd_state() {
	local tag="$1"
	have_ssh || { log "  [$tag] lighttpd-state: (no SSH)"; return 0; }
	local proc listen st
	proc=$(dut_ssh "ps w 2>/dev/null | grep -v grep | grep -c lighttpd" | tr -d '\r\n')
	listen=$(dut_ssh "netstat -ltn 2>/dev/null | grep -Ec ':80 |:443 '" | tr -d '\r\n')
	st=$(dut_ssh "/etc/init.d/lighttpd status 2>&1 | head -1" | tr -d '\r\n')
	proc=${proc:-0}; listen=${listen:-0}
	if [ "$proc" -gt 0 ] 2>/dev/null && [ "$listen" -gt 0 ] 2>/dev/null; then
		log "  [$tag] lighttpd: RUNNING (proc=$proc, listen80/443=$listen, status='${st}')"
		return 0
	fi
	bad "  [$tag] lighttpd: NOT RUNNING (proc=$proc, listen80/443=$listen, status='${st}')"
	return 1
}

# Factory-SOP check: GET /factory.cgi and confirm the Born-On status is "Idle".
# factory.cgi is a small shell CGI that prints Born-On state from uci `dbon.bootstatus`:
#   success=1 -> "Success", success=-1 -> "Failure", running=1 -> "Running", else "Idle".
# A factory reset wipes /etc/config/dbon, and etc/uci-defaults/dbon.defaults recreates it
# with running=0/success=0 -> so post-reset the SOP expects "Idle".
# This also doubles as a real end-to-end web check: it exercises lighttpd's CGI handler,
# not just the TCP socket.
check_factory_cgi() {
	local tag="$1" body status
	body=$(curl -sk -m 8 "https://$DUT_IP/factory.cgi" 2>/dev/null)
	[ -z "$body" ] && body=$(curl -s -m 8 "http://$DUT_IP/factory.cgi" 2>/dev/null)
	if [ -z "$body" ]; then
		bad "  [$tag] factory.cgi: NO RESPONSE (web/CGI down)"
		return 1
	fi
	# last non-empty line is the status word
	status=$(echo "$body" | grep -vE '^\s*$|-----' | tail -1 | tr -d '\r' | tr -d ' ')
	if [ "$status" = "Idle" ]; then
		ok "  [$tag] factory.cgi Born-On status: 'Idle' (expected after factory reset)"
		return 0
	fi
	bad "  [$tag] factory.cgi Born-On status: '$status' (SOP expects 'Idle' after reset)"
	return 1
}

# JNAP result is OK only if it contains "OK". A response with _ErrorUnauthorized
# (wrong/missing auth) or any _Error* must NOT be treated as success.
# Jason's doc (section 1) additionally requires "DeviceRestart" in the response, which
# is the stronger check: it proves the DUT accepted the reset AND will reboot.
jnap_result_ok() {
	echo "$1" | grep -q '"result"[[:space:]]*:[[:space:]]*"OK"' || return 1
	if [ "$JASON_FLOW" -eq 1 ]; then
		echo "$1" | grep -q 'DeviceRestart' || return 1
	fi
	return 0
}

# doc section 2: factory.cgi check, exactly as the reporter's tool issues it —
#   curl -k -sS --connect-timeout 5 --max-time 15 -H "Authorization:Basic <..>" \
#        "https://192.168.1.1/factory.cgi"
# and it checks ONLY the curl exit code; it does NOT validate that the body says
# "Idle". We record both so we can tell a refused socket (their failure) apart from
# a reachable CGI that returned an unexpected state (which their tool would pass).
check_factory_cgi_jason() {
	local tag="$1" pass="$2" body rc auth
	auth=$(printf '%s:%s' "$JNAP_USER" "$pass" | base64 | tr -d '\n')
	body=$(curl -k -sS $(curl_iface) --connect-timeout 5 --max-time 15 \
		-H "Authorization:Basic $auth" "https://$DUT_IP/factory.cgi" 2>&1)
	rc=$?
	local status
	status=$(echo "$body" | grep -vE '^\s*$|-----' | tail -1 | tr -d '\r' | tr -d ' ')
	if [ "$rc" -eq 0 ]; then
		ok "  [$tag] factory.cgi CURL_EXIT_CODE=0 (HTTPS OK); body status='${status:-<empty>}'"
		[ "$status" = "Idle" ] || bad "  [$tag] note: body is not 'Idle' (their tool does not check this)"
		return 0
	fi
	bad "  [$tag] factory.cgi CURL_EXIT_CODE=$rc (refused/timeout) <<< the reporter's failure"
	log  "  [$tag] curl said: $(echo "$body" | tr -d '\n' | head -c 160)"
	return 1
}

# One JNAP FactoryReset POST on the given scheme with the given password.
# An empty password sends NO auth header (unconfigured mode accepts that).
jnap_factory_reset() {
	local scheme="$1" pass="$2" insecure="" authhdr=()
	[ "$scheme" = "https" ] && insecure="-k"
	if [ -n "$pass" ]; then
		local auth
		auth=$(printf '%s:%s' "$JNAP_USER" "$pass" | base64 | tr -d '\n')
		authhdr=(-H "X-JNAP-Authorization: Basic $auth")
	fi
	if [ "$JASON_FLOW" -eq 1 ]; then
		# doc section 1, verbatim timeouts: --connect-timeout 5 --max-time 20
		curl -sS $insecure $(curl_iface) --connect-timeout 5 --max-time 20 -X POST \
			-H "Content-Type: application/json" \
			-H "X-JNAP-Action: $JNAP_ACTION" \
			"${authhdr[@]}" \
			-d '{}' "$scheme://$DUT_IP/JNAP/" 2>&1
		return
	fi
	curl -s $insecure $(curl_iface) -m 12 -X POST \
		-H "Content-Type: application/json" \
		-H "X-JNAP-Action: $JNAP_ACTION" \
		"${authhdr[@]}" \
		-d '{}' "$scheme://$DUT_IP/JNAP/" 2>&1
}

# trigger factory reset via JNAP (exactly what the issue uses).
# The web-login password changes with device state: it is the master passphrase
# in master mode but reverts to "admin" while unconfigured, and JNAP needs NO auth
# at all when unconfigured. So we try, in order: master pw, "admin", then no-auth,
# across https then http, and accept the first "result":"OK". SSH jffs2reset is the
# last-resort fallback.
trigger_factory_reset() {
	local out scheme pass pwlist
	# no-WAN: unit never leaves unconfigured mode, so "admin"/no-auth is the norm — try
	# those first. With WAN, Auto_Master applies the master passphrase, so try that first.
	# $EXTRA_PASS lets a second per-unit passphrase be tried (default_passphrase is
	# per-device, e.g. 8xPghzqdr@ on one DUT and Da8@Wfqes4 on another) so a hardware
	# swap does not look like a failure.
	if [ "$NO_WAN" -eq 1 ]; then pwlist="admin $JNAP_PASS $EXTRA_PASS"; else pwlist="$JNAP_PASS $EXTRA_PASS admin"; fi
	# doc section 1 posts the reset to http://192.168.1.1/JNAP/ (plain :80), so try
	# that scheme first when replicating their flow.
	local schemes="https http"
	[ "$JASON_FLOW" -eq 1 ] && schemes="http https"
	for scheme in $schemes; do
		for pass in $pwlist ""; do
			out=$(jnap_factory_reset "$scheme" "$pass")
			if jnap_result_ok "$out"; then
				# Remember the credential that worked so the factory.cgi Authorization
				# header can reuse it (Jason's check sends one).
				JNAP_PASS_OK="$pass"
				log "  JNAP FactoryReset accepted ($scheme, pw='${pass:-<none>}'): $(echo "$out" | tr -d '\n' | head -c 120)"
				return 0
			fi
		done
	done
	log "  ${C_YEL}JNAP not accepted on any scheme/password. Last: $(echo "$out" | tr -d '\n' | head -c 100)${C_RST}"
	# Distinguish "web server is dead" from "we used the wrong password". A JNAP
	# error body (e.g. _ErrorUnauthorized) is proof lighttpd IS alive and answering,
	# so it must never be scored as #451. Record that for the caller.
	if echo "$out" | grep -q '"result"'; then
		TRIGGER_WEB_ALIVE=1
		bad "  Web server IS alive (JNAP answered with an error) — this is an AUTH problem, not #451."
	else
		TRIGGER_WEB_ALIVE=0
	fi
	if have_ssh; then
		log "  ${C_YEL}Falling back to SSH jffs2reset${C_RST}"
		dut_ssh "jffs2reset -y >/dev/null 2>&1; (sleep 1; reboot) &" >/dev/null 2>&1
		return 0
	fi
	bad "  Could not trigger factory reset (JNAP failed, no SSH fallback)."
	return 1
}

# ---- Jason-flow reboot detection (doc sections 4.3 / 4.5) ----
# Deliberately different from wait_reboot(): their disconnect check requires TWO failed
# pings within 90s, and their reconnect check requires THREE successful pings, with a
# Wi-Fi reconnect + 60s extra retry if the first window times out.
jf_wait_down() {
	local waited=0 fails=0
	while [ "$waited" -lt "$JF_DOWN_TIMEOUT" ]; do
		if ping_ok; then fails=0; else
			fails=$((fails+1))
			if [ "$fails" -ge "$JF_DOWN_FAILS" ]; then
				log "  DUT unreachable after ${waited}s (${JF_DOWN_FAILS} failed pings) [doc 4.3]"
				return 0
			fi
		fi
		sleep 1; waited=$((waited+1))
	done
	bad "  DUT never went unreachable within ${JF_DOWN_TIMEOUT}s [doc 4.3] — reset did not take effect"
	return 1
}

jf_wait_up() {
	local phase_timeout="$1" waited=0 oks=0
	while [ "$waited" -lt "$phase_timeout" ]; do
		if ping_ok; then
			oks=$((oks+1))
			if [ "$oks" -ge "$JF_UP_OKS" ]; then
				log "  DUT pingable after ~${waited}s (${JF_UP_OKS} successful pings) [doc 4.5]"
				return 0
			fi
		else
			oks=0
		fi
		sleep 1; waited=$((waited+1))
	done
	return 1
}

# wait until DUT stops responding (reboot started) then comes back to ping.
wait_reboot() {
	local waited=0
	# Wait for the DUT to actually go down. This is NOT optional: some units take well
	# over a minute between accepting the JNAP reset and dropping the link (the overlay
	# wipe runs first). If we give up early, the "post-reset" checks below run against
	# the OLD boot and the next reset is fired mid-wipe — when JNAP rejects every
	# credential. So allow up to DOWN_WAIT and say plainly when it never happened.
	local down=0
	for _ in $(seq 1 "$DOWN_WAIT"); do
		if ! ping_ok; then down=1; break; fi
		sleep 1; waited=$((waited+1))
	done
	if [ "$down" -eq 1 ]; then
		log "  DUT went down after ${waited}s, waiting for reboot..."
	else
		bad "  DUT never went down within ${DOWN_WAIT}s of an accepted reset — reset did not take effect"
		return 1
	fi
	# now wait for it to come back
	waited=0
	while [ "$waited" -lt "$BOOT_WAIT" ]; do
		if ping_ok; then
			# Factory flow: the station proceeds on the FIRST successful ping — no
			# confirmation delay. Returning immediately preserves the aggressive
			# timing that makes the lighttpd startup race lose.
			if [ "$FACTORY_FLOW" -eq 1 ]; then
				log "  DUT reachable again after ~${waited}s (first ping; factory-flow)"
				return 0
			fi
			# require 2 consecutive good pings to be sure it's really up
			sleep 2
			if ping_ok; then
				log "  DUT reachable again after ~${waited}s"
				return 0
			fi
		fi
		sleep 1; waited=$((waited+1))
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
	# Factory SOP (--no-wan): the WAN cable is unplugged, so Auto_Master never runs at
	# all — the unit stays UNCONFIGURED (smart_mode.mode=0) and the admin/web password
	# stays "admin" permanently. There is nothing to wait for; gating here would just
	# burn AM_TIMEOUT every iteration. Report the unconfigured state and move on.
	if [ "$NO_WAN" -eq 1 ]; then
		if have_ssh; then
			local mode pw
			mode=$(dut_ssh "uci -q get linksys.smart_mode.mode" | tr -d '\r\n')
			pw=$(dut_ssh   "uci -q get lsadmin.user.password"   | tr -d '\r\n')
			info "  no-WAN mode: Auto_Master not expected to run (mode='${mode:-?}' pw='${pw:-?}')"
			[ -n "$mode" ] && [ "$mode" != "0" ] && \
				log "  ${C_YEL}note: mode=$mode though WAN is unplugged — unit is NOT unconfigured${C_RST}"
		else
			info "  no-WAN mode: skipping Auto_Master gate (unit stays unconfigured, pw='admin')"
		fi
		return 0
	fi
	if ! have_ssh; then
		log "  (no SSH) can't read auto-master state; fixed wait ${AM_TIMEOUT}s for it to settle"
		sleep "$AM_TIMEOUT"
		return 0
	fi
	local waited=0 mode st pw pwset
	while [ "$waited" -lt "$AM_TIMEOUT" ]; do
		mode=$(dut_ssh  "uci -q get linksys.smart_mode.mode" | tr -d '\r\n')
		st=$(dut_ssh    "sysevent get auto_master::status" | tr -d '\r\n')
		pw=$(dut_ssh    "uci -q get lsadmin.user.password" | tr -d '\r\n')
		pwset=$(dut_ssh "uci -q get lsadmin.user.user_set_password" | tr -d '\r\n')
		# Completion signals (verified on M60CF-EU, mode=2 / pw applied / status blank):
		#   - node became master:            mode != 0   (usually 2)
		#   - auto-master no longer running:  status is NOT "running"
		#     (it may be "stopped", "failed", OR blank once the event settles)
		#   - default passphrase applied:     user_set_password=1 AND pw != "admin"
		if [ -n "$mode" ] && [ "$mode" != "0" ] \
		   && [ "$st" != "running" ] \
		   && [ "$pwset" = "1" ] && [ -n "$pw" ] && [ "$pw" != "admin" ]; then
			ok "  Auto_Master complete after ~${waited}s (mode=$mode status='${st:-<blank>}', admin pw applied)"
			return 0
		fi
		# Stable terminal outcome that will NOT progress further: auto-master gave up
		# ('failed') and the unit stayed unconfigured. Don't burn the whole timeout.
		if [ "$st" = "failed" ] && [ "$mode" = "0" ] && [ "$waited" -ge 24 ]; then
			log "  auto-master settled 'failed', unit still unconfigured (mode=0) after ~${waited}s"
			return 1
		fi
		log "  waiting auto-master... (${waited}s: mode='${mode:-?}' status='${st:-<blank>}' pw_set='${pwset:-0}')"
		sleep 6; waited=$((waited+6))
	done
	bad "  Auto_Master did not complete within ${AM_TIMEOUT}s (mode='${mode:-?}' status='${st:-<blank>}' pw_set='${pwset:-0}')"
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
if [ "$NO_WAN" -eq 1 ]; then
	info " MODE: no-WAN (factory Born-On SOP) — Auto_Master will NOT run; unit stays"
	info "       unconfigured (mode=0) and the web/admin password stays 'admin'."
else
	info " MODE: WAN present — Auto_Master expected to promote unit to master."
fi
[ "$CHECK_FACTORY_CGI" -eq 1 ] && info " factory.cgi Born-On check: ENABLED (expect 'Idle' after each reset)"
if [ "$FACTORY_FLOW" -eq 1 ]; then
	info " FACTORY-FLOW: next reset fires as soon as ping answers (NO Auto_Master wait)."
	info "               after ping: ${FF_GRACE}s grace -> HTTPS factory.cgi -> JNAP on :80."
	info "               This matches the production station timing that reproduces #451."
fi
if [ "$JASON_FLOW" -eq 1 ]; then
	info " JASON-FLOW: replicating FactoryResetConnectionStressTest.txt verbatim."
	info "   reset via POST http://$DUT_IP/JNAP/ (:80), require \"result\":\"OK\" + DeviceRestart"
	info "   down: ${JF_DOWN_FAILS} failed pings / ${JF_DOWN_TIMEOUT}s -> wait ${JF_AFTER_DOWN}s"
	info "   up:   ${JF_UP_OKS} good pings / ${JF_UP_TIMEOUT}s (retry ${JF_UP_RETRY}s after Wi-Fi reconnect)"
	info "   then wait ${JF_AFTER_UP}s -> factory.cgi (exit-code check only) -> wait ${JF_CYCLE_WAIT}s"
	info "   path: ${IFACE:-default route (wired)}${WIFI_SSID:+  ssid=$WIFI_SSID}"
	[ -z "$IFACE" ] && info "   ${C_YEL}NOTE: reporter ran this loop over Wi-Fi; use --iface/--ssid to match.${C_RST}"
fi
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
DONE_ITER=0        # iterations that actually completed a full check (for honest summary)
ABORT_REASON=""    # non-empty => run ended early for a non-#451 reason
for i in $(seq 1 "$ITERATIONS"); do
	info "---------- Factory Reset #$i / $ITERATIONS ----------"
	if ! trigger_factory_reset; then
		# A trigger failure is NOT a benign stop. If the DUT still pings but JNAP will
		# not answer, that IS the #451 signature — the reset request is itself the first
		# casualty of the dead web server (the catch-22 described in the report).
		if [ "${TRIGGER_WEB_ALIVE:-0}" -eq 1 ]; then
			bad "stop: JNAP answered but rejected our credentials (NOT #451 — web is up)."
			ABORT_REASON="JNAP auth rejected at iteration $i (web server alive; wrong password)"
		elif ping_ok; then
			bad "iteration $i: cannot trigger reset while DUT still pings  <<< BUG REPRODUCED"
			bad "  (JNAP unreachable/refused => web server down; ping is kernel-side)"
			FAIL_ITER=$i
			diagnose_failure "$i"
		else
			bad "stop: cannot trigger reset and DUT is not pingable (not #451 — DUT down/hung)"
			ABORT_REASON="reset could not be triggered at iteration $i (DUT not pingable)"
		fi
		break
	fi

	if [ "$JASON_FLOW" -eq 1 ]; then
		# ---- REPORTER'S DOCUMENTED SEQUENCE (FactoryResetConnectionStressTest.txt) ----
		# 4.3 confirm unreachable (2 failed pings, 90s) -> 4.4 wait 20s ->
		# 4.5 wait pingable (3 good pings; retry once with Wi-Fi reconnect + 60s) ->
		# 4.6 wait 10s (no Auto_Master check) -> 4.7/4.8 factory.cgi, check exit code ->
		# 4.9 wait 10s before the next cycle.
		if ! jf_wait_down; then
			ABORT_REASON="DUT never went unreachable at iteration $i (reset did not take effect)"
			break
		fi
		log "  waiting ${JF_AFTER_DOWN}s after disconnect [doc 4.4]"
		sleep "$JF_AFTER_DOWN"

		if ! jf_wait_up "$JF_UP_TIMEOUT"; then
			bad "  DUT not pingable within ${JF_UP_TIMEOUT}s — Wi-Fi reconnect + ${JF_UP_RETRY}s retry [doc 4.5]"
			wifi_reconnect
			if ! jf_wait_up "$JF_UP_RETRY"; then
				bad "iteration $i: DUT never became pingable (retry window exhausted)"
				FAIL_ITER=$i; diagnose_failure "$i"; break
			fi
		fi

		log "  waiting ${JF_AFTER_UP}s after pingable, no Auto_Master check [doc 4.6]"
		sleep "$JF_AFTER_UP"

		log_lighttpd_state "iter $i"
		if check_factory_cgi_jason "iter $i" "${JNAP_PASS_OK:-admin}"; then
			DONE_ITER=$i
			ok "iteration $i: PASSED (factory.cgi CURL_EXIT_CODE=0)"
		else
			bad "iteration $i: FAILED — factory.cgi refused  <<< BUG REPRODUCED"
			if ping_ok; then
				bad "  ping still OK while HTTPS is refused = the reporter's exact signature"
			else
				bad "  NOTE: ping is also down — device-level failure, not web-only"
			fi
			FAIL_ITER=$i; diagnose_failure "$i"; break
		fi
		log "  waiting ${JF_CYCLE_WAIT}s before the next cycle [doc 4.9]"
		sleep "$JF_CYCLE_WAIT"
		continue
	fi

	if ! wait_reboot; then
		if ping_ok; then
			# Never went down / came back but reset didn't take: not the web bug.
			bad "iteration $i: reset did not take effect (DUT still up) — NOT #451"
			ABORT_REASON="reset accepted but DUT never rebooted at iteration $i"
		else
			FAIL_ITER=$i; bad "iteration $i: DUT never came back (ping)"
		fi
		break
	fi

	# ping check (issue step 3: expected always OK — ICMP is kernel-side)
	if ping_ok; then ok "iteration $i: ping OK"; else bad "iteration $i: ping FAILED"; fi

	if [ "$FACTORY_FLOW" -eq 1 ]; then
		# ---- FACTORY STATION FLOW (matches the reporter's reproduction exactly) ----
		# The production flow proceeds as soon as the DUT answers ping — it does NOT
		# wait for Auto_Master or full init. After a short grace period it does an
		# HTTPS GET of factory.cgi, then a JNAP request on port 80. A refusal at that
		# point is the failure the factory records ("factory.cgi did not return Idle").
		# Firing the next reset this early cuts into boot, which is what makes the
		# lighttpd single-LAN-ifup start race actually lose.
		log "  factory-flow: DUT pingable; waiting ${FF_GRACE}s grace (no Auto_Master wait)"
		sleep "$FF_GRACE"

		# The #451 signature is ping UP + web REFUSED. A first ping during boot can be
		# transient (the DUT keeps booting / reboots again), and then *everything* goes
		# away — that is a reboot, not the bug. So require a live ping here; if it is
		# gone, re-wait for the DUT and re-apply the grace instead of crying wolf.
		ff_settle=0
		while ! ping_ok; do
			ff_settle=$((ff_settle+1))
			if [ "$ff_settle" -gt 6 ]; then
				bad "  [iter $i] DUT ping gone and not returning — treating as reboot, not #451"
				break
			fi
			log "  [iter $i] ping vanished after grace (still booting) — re-waiting for DUT"
			wait_reboot || break
			sleep "$FF_GRACE"
		done
		if ! ping_ok; then
			bad "iteration $i: DUT not pingable — cannot evaluate web; stopping"
			FAIL_ITER=$i; diagnose_failure "$i"; break
		fi

		log_lighttpd_state "iter $i"

		fcgi_ok=0; jnap80_ok=0
		if check_factory_cgi "iter $i"; then fcgi_ok=1; fi
		# JNAP probe on port 80 (plain HTTP), as the factory flow does next.
		jout=$(curl -s -m 8 -X POST -H "Content-Type: application/json" \
			-H "X-JNAP-Action: http://linksys.com/jnap/core/GetDeviceInfo" \
			-d '{}' "http://$DUT_IP/JNAP/" 2>&1)
		if [ -n "$jout" ] && echo "$jout" | grep -q '"result"'; then
			jnap80_ok=1
			ok "  [iter $i] JNAP on :80 responded"
		else
			bad "  [iter $i] JNAP on :80 REFUSED/no response"
		fi

		if [ "$fcgi_ok" -eq 1 ] && [ "$jnap80_ok" -eq 1 ]; then
			DONE_ITER=$i
			ok "iteration $i: factory checks PASSED (factory.cgi Idle + JNAP :80)"
		else
			bad "iteration $i: factory check FAILED after ${FF_GRACE}s grace  <<< BUG REPRODUCED"
			bad "  (ping OK but factory.cgi/JNAP refused — matches the reporter's failure)"
			FAIL_ITER=$i
			diagnose_failure "$i"
			break
		fi
		continue
	fi

	# ---- default (tolerant) flow ----
	# Let Auto_Master settle (issue step 4 assumes it has). NOTE: in a single-DUT
	# topology with WAN, the node becomes its own master, so on the boot right after
	# a reset Auto_Master often sees "a master already exists" and exits 'failed',
	# leaving the unit unconfigured (mode=0, web pw reverts to 'admin'). That is
	# EXPECTED here and is NOT #451 — so this is informational only, never fatal.
	# #451 is purely about lighttpd being refused, which we assess by web_ok below.
	wait_auto_master || info "  (auto-master did not fully complete — expected in single-DUT/WAN setup; continuing)"

	# poll web up to REACH_TIMEOUT (issue step 4/8: web UI must load)
	w=0; webup=0
	while [ "$w" -lt "$REACH_TIMEOUT" ]; do
		if web_ok; then webup=1; break; fi
		sleep 3; w=$((w+3))
	done

	# Always record lighttpd's real state this iteration (proves the correlation).
	log_lighttpd_state "iter $i"

	if [ "$webup" -eq 1 ]; then
		DONE_ITER=$i
		ok "iteration $i: web UI reachable (after ${w}s)"
		# Factory SOP step: confirm Born-On status went back to 'Idle' after the reset.
		[ "$CHECK_FACTORY_CGI" -eq 1 ] && check_factory_cgi "iter $i"
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
elif [ -n "$ABORT_REASON" ]; then
	# Never claim a full clean run when we stopped early — report what actually ran.
	bad "RESULT: INCOMPLETE — $DONE_ITER of $ITERATIONS iterations verified before stopping."
	bad "Reason: $ABORT_REASON"
	info "Full run log: $RUN_LOG"
	exit 2
elif [ "$DONE_ITER" -lt "$ITERATIONS" ]; then
	bad "RESULT: INCOMPLETE — only $DONE_ITER of $ITERATIONS iterations verified."
	info "Full run log: $RUN_LOG"
	exit 2
else
	ok "RESULT: completed $ITERATIONS factory resets, web recovered every time (no repro)."
	info "Full run log: $RUN_LOG"
	exit 0
fi
