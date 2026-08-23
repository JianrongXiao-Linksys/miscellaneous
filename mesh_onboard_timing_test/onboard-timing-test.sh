#!/bin/bash
# Mesh onboarding timing harness for a two-node Pinnacle 2.0 (OpenWrt ED6) setup.
#
# Answers one question, repeatably: how long does it take from the moment the agent receives
# the BLE onboard command to the moment the agent can actually reach the controller AND the
# internet -- and where does that time go.
#
# See README.md in this directory for the wiring, the traps this script exists to avoid, and
# how to read the output.
#
# Usage:
#   onboard-timing-test.sh nic ctrl|agent|both     switch which node the host can talk to
#   onboard-timing-test.sh identify <ip>           MAC-guarded identity + build of whatever answers
#   onboard-timing-test.sh flash <img> <ip>        scp + md5 verify + sysupgrade
#   onboard-timing-test.sh reset <ip>              MAC-guarded factory reset
#   onboard-timing-test.sh trigger                 fire onboarding::pair=start on the controller
#   onboard-timing-test.sh measure [-o dir]        harvest the agent and print the timeline
#   onboard-timing-test.sh round [-o dir]          reset agent -> trigger -> measure (one round)
#   onboard-timing-test.sh run [-n N] [-o dir]     N rounds back to back
#
# Env overrides (all have defaults for the reference bench):
#   CTRL_NIC_CONN / AGENT_NIC_CONN   NetworkManager connection names
#   CTRL_MAC / AGENT_MAC             the two nodes' label MACs, lowercase
#   CTRL_IP                          controller LAN IP (default 192.168.1.1)
#   AGENT_DHCP_IP                    where the onboarded agent lands (default 192.168.1.111)
#   DEADLINE                         seconds to wait for a round to converge (default 300)
#   POLL                             seconds between convergence probes (default 10)

set -uo pipefail

# --- bench configuration ---------------------------------------------------------------

CTRL_NIC_CONN="${CTRL_NIC_CONN:-Wired connection 2}"
AGENT_NIC_CONN="${AGENT_NIC_CONN:-Wired connection 3}"
CTRL_MAC="${CTRL_MAC:-74:12:13:21:53:88}"
AGENT_MAC="${AGENT_MAC:-74:12:13:21:55:e6}"
CTRL_IP="${CTRL_IP:-192.168.1.1}"
AGENT_DHCP_IP="${AGENT_DHCP_IP:-192.168.1.111}"
DEADLINE="${DEADLINE:-300}"
# Convergence poll interval. This is the ONLY error term in the headline number, so it is small:
# at POLL=10 the reported time carried a "<=" of up to 10 s and rounds could not be compared to
# better than that, which is the same order as the differences between firmware builds we are
# trying to see. Each probe is one ssh with two -c1 -W1 pings, so 2 s is affordable.
POLL="${POLL:-2}"
# Progress lines every this many seconds, so a fine POLL does not produce a wall of output.
POLL_REPORT="${POLL_REPORT:-10}"
# Seconds to keep watching AFTER the agent is reachable, before harvesting. The post-credential
# radio churn happens here; harvesting on the online edge silently truncates the evidence.
SETTLE_WATCH="${SETTLE_WATCH:-60}"
OUTROOT="${OUTROOT:-$HOME/code/claude/onboard-tests}"

# Blank root password on the DUT, and the host key changes on every reflash, so pinning it
# would break the harness on exactly the runs it is for.
SSH_OPTS=(-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no
          -o ConnectTimeout=6 -o BatchMode=yes -o LogLevel=ERROR)

# The backhaul SSID is a per-unit secret and this script's output is meant to be pasteable
# into a ticket. Anything matching it is replaced before it reaches stdout or a file.
redact() {
	local bh="${BACKHAUL_SSID:-}"
	if [ -n "$bh" ]; then
		sed -e "s/${bh}/<backhaul-ssid>/g" -e 's/\(key\|passphrase\|psk\|password\)=.*/\1=<redacted>/I'
	else
		sed -e 's/\(key\|passphrase\|psk\|password\)=.*/\1=<redacted>/I'
	fi
}

say()  { printf '[onboard] %s\n' "$*"; }
die()  { printf '[onboard] FATAL: %s\n' "$*" >&2; exit 1; }
dsh()  { ssh "${SSH_OPTS[@]}" "root@$1" "$2" 2>/dev/null; }

# --- NIC switching ---------------------------------------------------------------------
#
# Both nodes answer on 192.168.1.1 at some point in a round: the controller always, and the
# agent whenever it is unconfigured. Two live NICs on the same /24 therefore make "192.168.1.1"
# ambiguous, and which node answers depends on ARP timing rather than on intent. So exactly one
# is up at a time, except for `both`, which is only safe once the agent has a DHCP lease.

nic() {
	case "$1" in
		ctrl)
			nmcli connection down "$AGENT_NIC_CONN" >/dev/null 2>&1
			nmcli connection up   "$CTRL_NIC_CONN"  >/dev/null 2>&1
			;;
		agent)
			nmcli connection down "$CTRL_NIC_CONN"  >/dev/null 2>&1
			nmcli connection up   "$AGENT_NIC_CONN" >/dev/null 2>&1
			;;
		both)
			nmcli connection up "$CTRL_NIC_CONN"  >/dev/null 2>&1
			nmcli connection up "$AGENT_NIC_CONN" >/dev/null 2>&1
			;;
		*) die "nic: expected ctrl|agent|both" ;;
	esac
	# NetworkManager deactivates a profile when carrier drops, so an `up` right after a DUT
	# reboot can report success and leave the profile down. Give it a moment and say what
	# actually happened rather than assuming.
	sleep 3
	ip -4 -o addr show | grep -E 'enx|eth' | sed 's/^/[onboard] /'
}

# --- identity --------------------------------------------------------------------------
#
# NEVER act on an IP alone. The single most expensive mistake on this bench is issuing a
# factory reset against 192.168.1.1 believing it is the agent and hitting the controller.

identify() {
	local ip="$1" out
	out="$(dsh "$ip" 'echo "mac=$(uci -q get devinfo.info.hw_mac_addr | tr A-Z a-z)"
	                  echo "ver=$(sed -n "s/^build_version=//p" /etc/routerinfo)"
	                  echo "mode=$(uci -q get prplmesh.config.management_mode)"
	                  echo "uptime=$(cut -d. -f1 /proc/uptime)"')"
	[ -n "$out" ] || { echo "unreachable"; return 1; }
	echo "$out" | tr '\n' ' '; echo
}

mac_of() { dsh "$1" 'uci -q get devinfo.info.hw_mac_addr | tr A-Z a-z'; }

# Refuse to continue unless the box at $1 is the node named by $2.
require_node() {
	local ip="$1" want="$2" got
	got="$(mac_of "$ip")"
	[ -n "$got" ] || die "nothing answers at $ip"
	[ "$got" = "$want" ] || die "$ip is $got, expected $want -- refusing to act"
	say "$ip confirmed as $want"
}

# --- flash -----------------------------------------------------------------------------

flash() {
	local img="$1" ip="$2" want="${3:-}" local_md5 dut_md5
	[ -f "$img" ] || die "no such image: $img"
	[ -n "$want" ] && require_node "$ip" "$want"

	local_md5="$(md5sum "$img" | cut -d' ' -f1)"
	say "image $(basename "$img") md5=$local_md5"

	dsh "$ip" 'rm -f /tmp/fw.img' >/dev/null
	scp "${SSH_OPTS[@]}" -q "$img" "root@$ip:/tmp/fw.img" || die "scp to $ip failed"
	dut_md5="$(dsh "$ip" 'md5sum /tmp/fw.img | cut -d" " -f1')"
	# A truncated transfer that still exits 0 is the failure mode here: /tmp is a ~200 MB
	# tmpfs and a full one silently short-writes.
	[ "$dut_md5" = "$local_md5" ] || die "md5 mismatch on $ip (got ${dut_md5:-none})"
	say "md5 verified on $ip"

	say "launching sysupgrade on $ip at $(date '+%H:%M:%S')"
	dsh "$ip" 'nohup sysupgrade /tmp/fw.img >/tmp/sysupgrade.log 2>&1 & echo launched' >/dev/null
}

# --- factory reset ---------------------------------------------------------------------
#
# /var/config is the preserved syscfg volume. firstboot alone leaves entries behind that
# survive into the next boot and make a "clean" run not clean, which is why both rm passes
# are here -- including the dotfile forms, which a bare * misses.

reset_node() {
	local ip="$1" want="${2:-}"
	[ -n "$want" ] && require_node "$ip" "$want"
	say "factory reset of $ip at $(date '+%H:%M:%S')"
	dsh "$ip" 'rm -rf /var/config/*
	           rm -rf /var/config/.[!.]* /var/config/.??*
	           nohup sh -c "firstboot -y && sync && reboot -f" >/dev/null 2>&1 &
	           echo launched' >/dev/null
}

# --- trigger ---------------------------------------------------------------------------

trigger() {
	require_node "$CTRL_IP" "$CTRL_MAC"
	local ready
	ready="$(dsh "$CTRL_IP" 'ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && echo inet=ok || echo inet=fail
	                         echo "vaps=$(ls /var/run/hostapd/ 2>/dev/null | grep -c "^phy")"
	                         echo "ble=$(pgrep -f ble-onboard-daemon | wc -l)"')"
	say "controller readiness: $(echo "$ready" | tr '\n' ' ')"
	case "$ready" in *inet=fail*) say "WARNING: controller has no internet -- 8.8.8.8 will fail" ;; esac

	say "trigger at $(date '+%H:%M:%S') (controller uptime $(dsh "$CTRL_IP" 'cut -d. -f1 /proc/uptime'))"
	dsh "$CTRL_IP" "ubus call sysevent set '{\"name\":\"onboarding::pair\",\"value\":\"start\"}'" >/dev/null
	sleep 2
	say "onboarding::state=$(dsh "$CTRL_IP" 'sysevent get onboarding::state')"
}

# --- convergence -----------------------------------------------------------------------
#
# "Onboarded" is not "the controller said so". The bar is the one a user would apply: from the
# AGENT, both the controller and the internet answer. Checked from the agent because a host-side
# ping proves only that the host's own NIC works.

#
# On success it prints the AGENT's own uptime, read in the same ssh session immediately after the
# pings answered. That is what makes the result comparable with the `[t=NNN.NN]` log markers: a
# host wall-clock stamp has to be mapped onto the agent's clock afterwards, and the agent's clock
# jumps when NTP lands mid-onboard, so the mapping is guesswork on precisely the rounds that
# matter. It is an upper bound by one poll interval plus the ping time, and nothing more.
agent_online() {
	local out
	out="$(dsh "$AGENT_DHCP_IP" 'ping -c1 -W1 '"$CTRL_IP"' >/dev/null 2>&1 && echo ctrl=ok || echo ctrl=fail
	                             ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 && echo inet=ok || echo inet=fail
	                             cut -d" " -f1 /proc/uptime')"
	case "$out" in
		*ctrl=ok*inet=ok*) printf '%s\n' "$out" | tail -1; return 0 ;;
	esac
	return 1
}

wait_online() {
	local dir="$1" waited=0 up="" next_report="$POLL_REPORT"
	while [ "$waited" -lt "$DEADLINE" ]; do
		sleep "$POLL"
		waited=$((waited + POLL))
		if up="$(agent_online)"; then
			say "agent online after ${waited}s of waiting (host clock $(date '+%H:%M:%S'), agent uptime ${up})"
			# Handed to timeline() through the artefact dir rather than a variable: the
			# measurement belongs with the logs it is quoted next to, and a re-run of
			# `measure -o <dir>` must reproduce the same number months later.
			[ -n "$dir" ] && { mkdir -p "$dir"; printf '%s\n' "$up" > "$dir/online-uptime"; }
			return 0
		fi
		if [ "$waited" -ge "$next_report" ]; then
			say "  ...${waited}s, agent not online yet"
			next_report=$((next_report + POLL_REPORT))
		fi
	done
	say "DEADLINE ${DEADLINE}s reached without the agent coming online"
	return 1
}

# --- harvest + timeline ----------------------------------------------------------------
#
# THREE sources, because no single one survives a round:
#
#   logread                 the live ring. syslog-ng reloads after NTP sync and RESTARTS the
#                           ring, so the middle of a round can vanish from it minutes later.
#                           Harvest it as early as possible.
#   /tmp/log/messages.1.gz  the rotated ring, i.e. what logread just threw away.
#   /tmp/wifi-monitor.log   wifi-monitor's own 128 KB ring, unaffected by syslog rotation and
#                           the only durable record of the backhaul module's decisions.
#
# The `[t=NNN.NN]` markers are the authoritative clock. Wall-clock timestamps are NOT usable:
# the DUT boots with an unsynced clock (dates in the past) and jumps forward mid-onboard when
# NTP lands, so a wall-clock sort interleaves lines from before and after the jump.

harvest() {
	local dir="$1"
	mkdir -p "$dir"
	dsh "$AGENT_DHCP_IP" 'logread'                | redact > "$dir/agent-logread.txt"
	dsh "$AGENT_DHCP_IP" 'cat /tmp/wifi-monitor.log' | redact > "$dir/wifi-monitor.log"
	scp "${SSH_OPTS[@]}" -q "root@$AGENT_DHCP_IP:/tmp/log/messages.1.gz" "$dir/messages.1.gz" 2>/dev/null
	dsh "$CTRL_IP" 'logread | grep -iE "ble-onboard|onboard"' | redact > "$dir/ctrl-onboard.txt"
	dsh "$AGENT_DHCP_IP" 'echo "-- bhsta --"
	    wpa_cli -p /var/run/wpa_supplicant -i $(uci -q get wireless.bhsta.ifname) status 2>/dev/null \
	        | grep -E "^(wpa_state|bssid|freq)="
	    echo "-- ssid: hostapd vs driver --"
	    for i in $(ls /var/run/hostapd/ | grep "^phy.*-0$"); do
	        printf "%s hostapd=%s driver=%s\n" "$i" \
	            "$(hostapd_cli -i $i get_config 2>/dev/null | sed -n "s/^ssid=//p")" \
	            "$(iw dev $i info 2>/dev/null | sed -n "s/^[[:space:]]*ssid //p")"
	    done
	    echo "-- agent state --"
	    ubus call X_PRPLWARE-COM_Agent.Info _get {} 2>/dev/null | grep -o "\"CurrentState\":[^,]*"
	    echo "-- sta-iface-repair attempts --"
	    cat /var/run/lsmesh-sta-iface-repair.attempts 2>/dev/null || echo 0' \
	    | redact > "$dir/agent-state.txt"
	say "harvested to $dir"
}

# Pull the milestones out of the harvested logs and print them with deltas from t0.
#
# Deliberately a fixed list rather than "every [t=] line": the point is a comparable number
# per round, and a timeline whose rows change between rounds cannot be diffed.
timeline() {
	local dir="$1" t0
	local logs="$dir/agent-logread.txt $dir/wifi-monitor.log"
	[ -f "$dir/messages.1.gz" ] && zcat "$dir/messages.1.gz" > "$dir/.messages.1" 2>/dev/null \
		&& logs="$logs $dir/.messages.1"

	t0="$(grep -hoE '\[t=[0-9.]+\][^|]*GATT command received' $logs 2>/dev/null \
	      | head -1 | sed -n 's/^\[t=\([0-9.]*\)\].*/\1/p')"
	if [ -z "$t0" ]; then
		say "no 'GATT command received' line found -- cannot measure this round"
		return 1
	fi

	say "t0 = $t0 (GATT command received)"
	printf '%10s  %8s  %s\n' "t(s)" "delta" "event"
	# One awk pass so the rows come out in t order regardless of which file they came from.
	grep -hoE '\[t=[0-9.]+\].*' $logs 2>/dev/null \
	  | grep -E 'GATT command received|starting WPS-PBC|triggering WPS-PBC|WPS-PBC completed|fronthaul credentials persisted|replacement beerocks_agent|back-out|recovered \(was disconnected|reassociating now|legalised HT40|rebuilding|hostapd still reports|activation grace|backhaul: connected on boot' \
	  | sed -n 's/^\[t=\([0-9.]*\)\] *\(.*\)$/\1|\2/p' \
	  | sort -t'|' -k1,1g -u \
	  | awk -F'|' -v t0="$t0" '$1+0 >= t0+0 { printf "%10.2f  %+8.2f  %s\n", $1, $1-t0, $2 }'

	# The repair's own line is logged by lsmesh, not with a [t=] marker, so it is matched
	# separately and reported as a fact rather than placed on the timeline.
	grep -hoE "sta-iface-repair: .*after [0-9]+s -> killing beerocks_agent.*" $logs 2>/dev/null | head -1
	grep -hoE "sta-iface-repair: replacement beerocks_agent up .*" $logs 2>/dev/null | head -1

	# THE HEADLINE. Agent-clocked, so it sits on the same axis as every row above.
	local online
	online="$(cat "$dir/online-uptime" 2>/dev/null)"
	if [ -n "$online" ]; then
		awk -v a="$t0" -v b="$online" -v p="$POLL" \
			'BEGIN { printf "[onboard] GATT -> agent online (pings controller AND internet): %.2f - %.2f = %.2f s (+/-%ds, one poll)\n", b, a, b-a, p }'
	else
		say "no online-uptime recorded for this round -- run 'round', not 'measure', for the headline number"
	fi

	# Secondary, and reported with its caveat. The settle line is only as good as the last
	# backhaul event in the log, and wifi-monitor deliberately does NOT emit a
	# `recovered (was disconnected ~Ns)` for a dip that falls inside its 30 s activation grace
	# (a reassociate that soon after WPS is measured harmful). On builds before that gap was
	# closed the settle therefore reads EARLIER than a drop the same log reports one line later
	# -- 26082217 r4 printed 29.72 s with the bSTA going SCANNING at +24.63 s. So check for a
	# grace dip after the settle and say so instead of quoting a number that is not one.
	local last dip
	last="$(grep -hoE '\[t=[0-9.]+\] backhaul: (recovered|connected)' $logs 2>/dev/null \
	        | tail -1 | sed -n 's/^\[t=\([0-9.]*\)\].*/\1/p')"
	dip="$(grep -hoE '\[t=[0-9.]+\][^|]*inside the [0-9]+s activation grace' $logs 2>/dev/null \
	       | tail -1 | sed -n 's/^\[t=\([0-9.]*\)\].*/\1/p')"
	[ -n "$last" ] && awk -v a="$t0" -v b="$last" \
		'BEGIN { printf "[onboard] GATT -> last logged backhaul settle: %.2f - %.2f = %.2f s\n", b, a, b-a }'
	# BEGIN, not a pattern-action rule: awk is given no input here, so a bare `d>b { ... }` never
	# runs its body and the warning silently never fires -- which is how it failed its own test.
	[ -n "$last" ] && [ -n "$dip" ] && awk -v b="$last" -v d="$dip" \
		'BEGIN { if (d+0 > b+0) printf "[onboard] WARNING: bSTA went down at t=%.2f, AFTER that settle, inside the activation grace -- the settle above is not the end of the churn on this build\n", d }'
}

# --- a whole round ---------------------------------------------------------------------

one_round() {
	local dir="$1"
	nic ctrl >/dev/null

	# Reset the agent. It is reachable at its DHCP address while onboarded, which is also the
	# only moment it can be told apart from the controller without switching NICs.
	if [ -n "$(mac_of "$AGENT_DHCP_IP")" ]; then
		reset_node "$AGENT_DHCP_IP" "$AGENT_MAC"
	else
		say "agent not at $AGENT_DHCP_IP -- switching to its NIC to reset it"
		nic agent >/dev/null
		reset_node "$CTRL_IP" "$AGENT_MAC"
		nic ctrl >/dev/null
	fi

	# The agent needs to be booted and advertising before the controller's scan will find it.
	say "waiting for the agent to boot and start advertising"
	sleep 150

	trigger  || return 1
	wait_online "$dir" || { harvest "$dir"; return 1; }

	# Do NOT harvest at the instant the agent answers. "Reachable" is the headline, not the end of
	# the round: the M2 credentials reach the radio carrying the bSTA afterwards, and that is where
	# the HT40 legalisation, the back-out trigger and the post-M2 backhaul dip live. Harvesting on
	# the online edge cut the 26082217 r5 artefact off at t=211 and lost a bSTA drop at t=237 --
	# the artefact said the round ended clean when the log, read live minutes later, said it had not.
	# The headline is already banked in $dir/online-uptime, so this window costs nothing but wall time.
	say "settling for ${SETTLE_WATCH}s before harvesting, so the post-credential churn is in the logs"
	sleep "$SETTLE_WATCH"

	harvest "$dir"
	timeline "$dir" | tee "$dir/TIMELINE.txt"
}

# --- entry point -----------------------------------------------------------------------

cmd="${1:-}"; shift || true
case "$cmd" in
	nic)      nic "${1:?ctrl|agent|both}" ;;
	identify) identify "${1:?ip}" ;;
	flash)    flash "${1:?image}" "${2:?ip}" "${3:-}" ;;
	reset)    reset_node "${1:?ip}" "${2:-}" ;;
	trigger)  trigger ;;
	measure)
		dir="${OUTROOT}/manual-$(date +%y%m%d%H%M)"
		[ "${1:-}" = "-o" ] && dir="$2"
		harvest "$dir"; timeline "$dir" | tee "$dir/TIMELINE.txt"
		;;
	round)
		dir="${OUTROOT}/round-$(date +%y%m%d%H%M)"
		[ "${1:-}" = "-o" ] && dir="$2"
		one_round "$dir"
		;;
	run)
		rounds=1; dir=""
		while [ $# -gt 0 ]; do
			case "$1" in
				-n) rounds="$2"; shift 2 ;;
				-o) dir="$2"; shift 2 ;;
				*)  die "run: unexpected argument $1" ;;
			esac
		done
		pass=0; fail=0
		i=1
		while [ "$i" -le "$rounds" ]; do
			d="${dir:-${OUTROOT}/run-$(date +%y%m%d%H%M)}/r${i}"
			say "===== round $i/$rounds -> $d ====="
			if one_round "$d"; then pass=$((pass+1)); else fail=$((fail+1)); fi
			i=$((i+1))
		done
		say "===== $pass passed, $fail failed ====="
		[ "$fail" = "0" ]
		;;
	*)
		sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac
