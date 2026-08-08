#!/bin/bash
# ---------------------------------------------------------------------------
# qca_skipcnss_stress.sh — Qualcomm case 08621084, Pranjal's recommended steps
#
# QCA asked for exactly this procedure (case 08621084, Aug 5 + Aug 7 posts):
#   1. add boot argument  cnss2.skip_cnss=1  and reboot the DUT
#   2. capture console logs from a Linux PC on the DUT LAN
#   3. run the factory-reset stress loop for 15 iterations:
#        - trigger a factory reset using the management API
#        - wait for the DUT to go offline
#        - wait for it to come back online
#        - confirm SSH and HTTP/HTTPS access
#        - wait only 10 seconds, then trigger the next reset
#   4. monitor the console logs for   overlayfs   and   -116
#   5. if an overlayfs -116 error occurs, run   jffs2reset -y
#
# This script owns steps 3-5. Step 1 is a one-off fw_setenv (checked here, not
# performed). Step 2 needs the serial console; run serial_console_log.py in
# parallel — this script additionally pulls `dmesg` over SSH every iteration so
# the overlayfs/-116 scan works even without serial access.
#
# Deliberately a SEPARATE script from reset_web_test.sh: that tool tracks the
# lighttpd web-refused issue and its timings/verdicts must not change.
#
# Usage:
#   ./qca_skipcnss_stress.sh [-i IP] [-n ITERATIONS] [-p PASS ...]
# ---------------------------------------------------------------------------
set -u

DUT_IP="192.168.1.1"
ITERATIONS=15
SSH_USER="root"
# Password depends on device state: 'admin' while unconfigured (right after a
# factory reset), the per-unit default_passphrase once Auto_Master has run.
PASS_LIST="admin 8xPghzqdr@ 12345Asdf@ Da8@Wfqes4"
JNAP_USER="admin"
JNAP_ACTION="http://linksys.com/jnap/core/FactoryReset"
DOWN_WAIT=150        # max s to wait for the DUT to drop off after an accepted reset
BOOT_WAIT=180        # max s to wait for it to answer ping again
SSH_TIMEOUT=120      # max s to wait for sshd after ping returns (QCA step 3)
WEB_TIMEOUT=120      # max s to wait for HTTP/HTTPS after ping returns (QCA step 3)
CYCLE_WAIT=10        # QCA step 3: "wait only 10 seconds, then trigger the next reset"
AUTO_JFFS2RESET=1    # QCA step 5: run jffs2reset -y when overlayfs -116 is seen

while [ $# -gt 0 ]; do
	case "$1" in
		-i) DUT_IP="$2"; shift 2;;
		-n) ITERATIONS="$2"; shift 2;;
		-p) PASS_LIST="$2 $PASS_LIST"; shift 2;;
		--no-auto-reset) AUTO_JFFS2RESET=0; shift;;
		--cycle-wait) CYCLE_WAIT="$2"; shift 2;;
		-h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0;;
		*) echo "Unknown arg: $1"; exit 2;;
	esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="$LOG_DIR/qca_skipcnss_${RUN_TS}.log"
KLOG="$LOG_DIR/qca_skipcnss_${RUN_TS}_dmesg.txt"

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_RST=$'\033[0m'
log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }
ok()   { log "${C_GRN}PASS${C_RST} $*"; }
bad()  { log "${C_RED}FAIL${C_RST} $*"; }
warn() { log "${C_YEL}$*${C_RST}"; }
info() { log "${C_CYN}$*${C_RST}"; }

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o LogLevel=ERROR"
SSH_PASS_OK=""

ping_ok() { ping -c1 -W2 "$DUT_IP" >/dev/null 2>&1; }

# Runs a remote command. Caches whichever password authenticates, and re-probes
# the whole list if the cached one stops working (a reset changes the password).
dut_ssh() {
	local out p
	if [ -n "$SSH_PASS_OK" ]; then
		out=$(sshpass -p "$SSH_PASS_OK" ssh $SSH_OPTS "$SSH_USER@$DUT_IP" "$1" 2>&1)
		if ! echo "$out" | grep -qiE 'permission denied|authentication fail'; then
			echo "$out"; return 0
		fi
		SSH_PASS_OK=""
	fi
	for p in $PASS_LIST; do
		out=$(sshpass -p "$p" ssh $SSH_OPTS "$SSH_USER@$DUT_IP" "$1" 2>&1)
		if ! echo "$out" | grep -qiE 'permission denied|authentication fail'; then
			SSH_PASS_OK="$p"; echo "$out"; return 0
		fi
	done
	echo "$out"; return 1
}

ssh_ok() { dut_ssh "echo __SSH_ALIVE__" 2>/dev/null | grep -q __SSH_ALIVE__; }

# Any HTTP status other than 000 means the socket accepted us; the bug shape we
# care about is connection refused, so that is the only thing scored as down.
web_ok() {
	local code
	code=$(curl -sk -o /dev/null -m 5 -w '%{http_code}' "https://$DUT_IP/" 2>/dev/null)
	[ -n "$code" ] && [ "$code" != "000" ] && return 0
	code=$(curl -s  -o /dev/null -m 5 -w '%{http_code}' "http://$DUT_IP/" 2>/dev/null)
	[ -n "$code" ] && [ "$code" != "000" ] && return 0
	return 1
}

# QCA step 1 check: the whole point of this run is skip_cnss=1 being active.
verify_skip_cnss() {
	local cmdline param
	cmdline=$(dut_ssh "cat /proc/cmdline" | tr -d '\r')
	param=$(dut_ssh "cat /sys/module/ipq_cnss2/parameters/skip_cnss 2>/dev/null" | tr -d '\r\n')
	if echo "$cmdline" | grep -q "cnss2.skip_cnss=1"; then
		ok "  skip_cnss=1 present in /proc/cmdline (module param='${param:-n/a}')"
		return 0
	fi
	bad "  cnss2.skip_cnss=1 NOT in /proc/cmdline — boot argument did not survive"
	log  "  cmdline: $cmdline"
	log  "  fix: fw_setenv bootargs \"console=ttyMSM0,115200n8 cnss2.enable_mlo_support=1 cnss2.skip_cnss=1\" && reboot"
	return 1
}

# QCA step 4: scan the kernel log for overlayfs errors and for -116 (ESTALE).
# Returns 0 = clean, 1 = overlayfs/-116 hit.
scan_kernel_log() {
	local tag="$1" dm hits
	dm=$(dut_ssh "dmesg 2>/dev/null")
	{
		echo "################ $tag  ($(date)) ################"
		echo "$dm"
		echo
	} >> "$KLOG"
	hits=$(echo "$dm" | grep -inE "overlayfs|ESTALE|[^0-9-]-116([^0-9]|$)" | head -40)
	if [ -z "$hits" ]; then
		ok "  [$tag] kernel log clean: no overlayfs / -116 / ESTALE"
		return 0
	fi
	bad "  [$tag] overlayfs / -116 signature FOUND  <<< QCA step 4 hit"
	echo "$hits" | while IFS= read -r l; do log "      $l"; done
	return 1
}

# QCA step 5: on an overlayfs -116 error, run jffs2reset -y.
do_jffs2reset() {
	local tag="$1"
	if [ "$AUTO_JFFS2RESET" -ne 1 ]; then
		warn "  [$tag] --no-auto-reset given: NOT running jffs2reset (QCA step 5 skipped)"
		return 0
	fi
	warn "  [$tag] QCA step 5: running 'jffs2reset -y' on the DUT"
	dut_ssh "jffs2reset -y 2>&1" | while IFS= read -r l; do log "      $l"; done
	warn "  [$tag] jffs2reset done — rebooting so the wipe takes effect"
	dut_ssh "(sleep 1; reboot) >/dev/null 2>&1 &" >/dev/null 2>&1
}

# Factory reset via the management API. Try each password across https then http;
# unconfigured units also accept no auth at all, so try that last.
trigger_factory_reset() {
	local scheme pass out insecure authhdr
	for scheme in https http; do
		for pass in $PASS_LIST ""; do
			insecure=""; [ "$scheme" = "https" ] && insecure="-k"
			authhdr=()
			if [ -n "$pass" ]; then
				authhdr=(-H "X-JNAP-Authorization: Basic $(printf '%s:%s' "$JNAP_USER" "$pass" | base64 | tr -d '\n')")
			fi
			out=$(curl -s $insecure -m 12 -X POST \
				-H "Content-Type: application/json" \
				-H "X-JNAP-Action: $JNAP_ACTION" \
				"${authhdr[@]}" -d '{}' "$scheme://$DUT_IP/JNAP/" 2>&1)
			if echo "$out" | grep -q '"result"[[:space:]]*:[[:space:]]*"OK"'; then
				log "  reset accepted via API ($scheme, pw='${pass:-<none>}')"
				return 0
			fi
		done
	done
	warn "  API reset not accepted. Last response: $(echo "$out" | tr -d '\n' | head -c 140)"
	if ssh_ok; then
		warn "  falling back to SSH: jffs2reset -y; reboot"
		dut_ssh "jffs2reset -y >/dev/null 2>&1; (sleep 1; reboot) &" >/dev/null 2>&1
		return 0
	fi
	bad "  cannot trigger a reset (API refused, SSH unavailable)"
	return 1
}

wait_down() {
	local waited=0
	while [ "$waited" -lt "$DOWN_WAIT" ]; do
		if ! ping_ok; then log "  DUT offline after ${waited}s"; return 0; fi
		sleep 1; waited=$((waited+1))
	done
	bad "  DUT never went offline within ${DOWN_WAIT}s of an accepted reset"
	return 1
}

wait_up() {
	local waited=0
	while [ "$waited" -lt "$BOOT_WAIT" ]; do
		if ping_ok; then log "  DUT back online after ${waited}s"; return 0; fi
		sleep 1; waited=$((waited+1))
	done
	bad "  DUT did not answer ping within ${BOOT_WAIT}s"
	return 1
}

wait_for() {   # wait_for <label> <timeout> <predicate-fn>
	local label="$1" timeout="$2" fn="$3" waited=0
	while [ "$waited" -lt "$timeout" ]; do
		if "$fn"; then log "  $label up after ${waited}s"; return 0; fi
		sleep 3; waited=$((waited+3))
	done
	bad "  $label NOT available within ${timeout}s"
	return 1
}

# ---------------- pre-flight ----------------
command -v sshpass >/dev/null || { echo "need: sshpass"; exit 1; }
command -v curl    >/dev/null || { echo "need: curl";    exit 1; }

info "======================================================================"
info " QCA case 08621084 — skip_cnss=1 factory-reset stress (Pranjal's steps)"
info " DUT=$DUT_IP  iterations=$ITERATIONS  cycle_wait=${CYCLE_WAIT}s"
info " per iteration: API reset -> offline -> online -> SSH + HTTP/HTTPS -> dmesg scan"
info " watching for: 'overlayfs', '-116' (ESTALE); auto jffs2reset=$AUTO_JFFS2RESET"
info " run log:   $RUN_LOG"
info " dmesg log: $KLOG"
info "======================================================================"

if ! ping_ok; then bad "DUT $DUT_IP not pingable — aborting."; exit 1; fi
ok "baseline: DUT pingable"
ssh_ok || { bad "baseline: SSH not available (tried: $PASS_LIST) — aborting."; exit 1; }
ok "baseline: SSH OK (pw='$SSH_PASS_OK')"
web_ok && ok "baseline: HTTP/HTTPS OK" || { bad "baseline: web refused — DUT already failed before the test"; exit 1; }
verify_skip_cnss || exit 1
scan_kernel_log "baseline"

# ---------------- main loop ----------------
OVERLAY_HITS=0
DONE_ITER=0
FAIL_ITER=0
ABORT=""

for i in $(seq 1 "$ITERATIONS"); do
	info "---------- Factory Reset #$i / $ITERATIONS ----------"

	trigger_factory_reset || { ABORT="could not trigger reset at iteration $i"; break; }
	wait_down            || { ABORT="reset did not take effect at iteration $i"; break; }
	wait_up              || { FAIL_ITER=$i; bad "iteration $i: DUT never came back"; break; }

	# The password changes across a reset, so drop the cached one.
	SSH_PASS_OK=""

	sshup=0; webup=0
	wait_for "SSH"        "$SSH_TIMEOUT" ssh_ok && sshup=1
	wait_for "HTTP/HTTPS" "$WEB_TIMEOUT" web_ok && webup=1

	if [ "$sshup" -eq 1 ]; then
		verify_skip_cnss || warn "  iteration $i: skip_cnss lost — results after this point are not comparable"
		if ! scan_kernel_log "iter $i"; then
			OVERLAY_HITS=$((OVERLAY_HITS+1))
			do_jffs2reset "iter $i"
			wait_up || { FAIL_ITER=$i; ABORT="DUT did not return after jffs2reset at iteration $i"; break; }
			SSH_PASS_OK=""
			wait_for "SSH"        "$SSH_TIMEOUT" ssh_ok >/dev/null
			wait_for "HTTP/HTTPS" "$WEB_TIMEOUT" web_ok >/dev/null
		fi
	else
		bad "  iteration $i: no SSH — cannot read dmesg this iteration"
	fi

	if [ "$sshup" -eq 1 ] && [ "$webup" -eq 1 ]; then
		DONE_ITER=$i
		ok "iteration $i: PASSED (offline/online + SSH + HTTP/HTTPS confirmed)"
	else
		bad "iteration $i: FAILED (ssh=$sshup web=$webup)"
		FAIL_ITER=$i
		break
	fi

	log "  QCA step 3: waiting ${CYCLE_WAIT}s before the next reset"
	sleep "$CYCLE_WAIT"
done

# ---------------- summary ----------------
info "======================================================================"
info "iterations completed : $DONE_ITER / $ITERATIONS"
info "overlayfs/-116 hits  : $OVERLAY_HITS"
[ -n "$ABORT" ] && bad "stopped early: $ABORT"
[ "$FAIL_ITER" -gt 0 ] && bad "failing iteration: #$FAIL_ITER"
info "run log:   $RUN_LOG"
info "dmesg log: $KLOG"
info "======================================================================"

if [ "$OVERLAY_HITS" -gt 0 ]; then exit 3; fi
if [ "$FAIL_ITER" -gt 0 ] || [ -n "$ABORT" ]; then exit 1; fi
if [ "$DONE_ITER" -lt "$ITERATIONS" ]; then exit 2; fi
ok "RESULT: $ITERATIONS iterations, no overlayfs/-116, SSH+web up every time."
exit 0
