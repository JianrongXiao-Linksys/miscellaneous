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
# How long, after the settle window, to keep re-checking the credentials before failing the round.
# 180 s because the recovery path that delivers them can involve a beerocks_agent restart plus a
# fresh registration walk: on 26082314 r17 that landed ~70 s after the settle window closed.
CREDS_DEADLINE="${CREDS_DEADLINE:-180}"
# Each credential probe is two ssh round trips and a NIC switch, so it is not free.
CREDS_POLL="${CREDS_POLL:-15}"
CREDS_POLL_REPORT="${CREDS_POLL_REPORT:-30}"
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

# The controller's own verdict on the attempt, in one line: "state result counters".
#
# Read from the controller because it is the only node that knows the attempt ended: an agent
# that was never reached logs nothing at all, and the harness cannot tell "still working" from
# "gave up 3 minutes ago" by pinging it. Safe to call while the ctrl NIC is the live one, which
# is the whole of wait_online.
ctrl_verdict() {
	dsh "$CTRL_IP" 'printf "%s %s %s\n" "$(sysevent get onboarding::state)" \
	                                    "$(sysevent get onboarding::result)" \
	                                    "$(sysevent get onboarding::counters | tr " " "/")"'
}

wait_online() {
	local dir="$1" waited=0 up="" next_report="$POLL_REPORT" verdict start
	# Wall clock, not a count of poll intervals. Each iteration also spends an ssh -- up to
	# ConnectTimeout when the agent is unreachable, which is every iteration of a failing round --
	# so `waited += POLL` undercounts badly: 26082222 r9 printed "...40s" at what was really
	# 81 s by the controller's own uptime, and DEADLINE=300 would have meant nearer 10 minutes.
	# A progress number that is not seconds cannot be compared with the [t=] axis at all.
	start="$(date +%s)"
	while [ "$waited" -lt "$DEADLINE" ]; do
		sleep "$POLL"
		waited=$(( $(date +%s) - start ))
		if up="$(agent_online)"; then
			say "agent online after ${waited}s of waiting (host clock $(date '+%H:%M:%S'), agent uptime ${up})"
			# Handed to timeline() through the artefact dir rather than a variable: the
			# measurement belongs with the logs it is quoted next to, and a re-run of
			# `measure -o <dir>` must reproduce the same number months later.
			[ -n "$dir" ] && { mkdir -p "$dir"; printf '%s\n' "$up" > "$dir/online-uptime"; }
			return 0
		fi
		if [ "$waited" -ge "$next_report" ]; then
			verdict="$(ctrl_verdict)"
			say "  ...${waited}s, agent not online yet (controller: ${verdict:-unreadable})"
			# From `waited`, not from the old boundary: with a wall clock one iteration can
			# cross several boundaries, and stepping by POLL_REPORT would then report every
			# iteration until it caught up.
			next_report=$((waited + POLL_REPORT))
			# Fail fast on the controller's own verdict. 26082220 r8 burned the whole
			# 300 s DEADLINE on a round the controller had already given up on at 36 s
			# ("0 succeeded, 1 failed", the GATT connect never landed) -- 4 minutes of
			# polling a node that was never going to answer, and, worse, 4 more minutes
			# of syslog ring churn before the harvest, which is why that round's evidence
			# had to be dug out of messages.1.gz. Only `failed` aborts: `done` with a
			# success result happens well before the agent has a route, so treating
			# state=done as terminal would abort every good round.
			case "$verdict" in
				done*failed*)
					say "controller gave up after ${waited}s: ${verdict} -- aborting the round early"
					return 1
					;;
			esac
		fi
	done
	say "DEADLINE ${DEADLINE}s reached without the agent coming online (controller: $(ctrl_verdict))"
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

# Where to reach the agent for a harvest, echoed as an IP, or empty if it cannot be reached.
#
# On a FAILED round the agent is not at $AGENT_DHCP_IP -- it never got a lease -- it is
# unconfigured at 192.168.1.1 behind the other NIC. Harvesting without this fallback produced
# 26082222 r9's artefact dir: four files, three of them zero bytes, and the whole agent side of
# the failure (the wps_pbc error that was the actual root cause) had to be read off the box by
# hand afterwards. The failed rounds are the ones whose logs matter most.
#
# The MAC guard is not optional here: on the agent NIC, 192.168.1.1 is whichever node answers,
# and harvesting the controller into agent-*.txt would be worse than harvesting nothing.
agent_harvest_ip() {
	local ll
	[ -n "$(mac_of "$AGENT_DHCP_IP")" ] && { printf '%s' "$AGENT_DHCP_IP"; return 0; }
	nic agent >/dev/null
	# Directly cabled now, so this works even when the backhaul is down and the lease is not
	# reachable through the controller.
	[ -n "$(mac_of "$AGENT_DHCP_IP")" ] && { printf '%s' "$AGENT_DHCP_IP"; return 0; }
	[ "$(mac_of "$CTRL_IP")" = "$AGENT_MAC" ] && { printf '%s' "$CTRL_IP"; return 0; }
	# Last resort, and the only address on this bench that cannot be ambiguous: the agent's
	# IPv6 link-local, derived from its label MAC. 26082223 r10 needed it -- the agent had
	# reverted to a static 192.168.1.1 while the controller was ALSO reachable at 192.168.1.1
	# through the agent's own bridge, so the MAC guard on that address correctly refused, and
	# there was no v4 address left that meant "the agent". A link-local is per-interface, so
	# whatever answers it on this cable is the box on the other end of this cable.
	ll="$(agent_ll6)"
	[ -n "$ll" ] && [ "$(mac_of "$ll")" = "$AGENT_MAC" ] && { printf '%s' "$ll"; return 0; }
	return 1
}

# The agent's IPv6 link-local, scoped to the agent NIC: EUI-64 of AGENT_MAC with the U/L bit
# flipped, which is what SLAAC builds and what the DUT actually carries.
agent_ll6() {
	local dev a1 a2 a3 a4 a5 a6
	dev="$(nmcli -g GENERAL.DEVICES connection show "$AGENT_NIC_CONN" 2>/dev/null | head -1)"
	[ -n "$dev" ] || return 1
	IFS=: read -r a1 a2 a3 a4 a5 a6 <<< "$AGENT_MAC"
	[ -n "$a6" ] || return 1
	printf 'fe80::%02x%s:%sff:fe%s:%s%s%%%s' "$(( 0x$a1 ^ 0x02 ))" "$a2" "$a3" "$a4" "$a5" "$a6" "$dev"
}

harvest() {
	local dir="$1" aip
	mkdir -p "$dir"
	# The controller first, while its NIC is the live one: agent_harvest_ip may switch away.
	dsh "$CTRL_IP" 'logread | grep -iE "ble-onboard|onboard"' | redact > "$dir/ctrl-onboard.txt"
	scp "${SSH_OPTS[@]}" -q "root@$CTRL_IP:/tmp/log/messages.1.gz" "$dir/ctrl-messages.1.gz" 2>/dev/null
	if ! aip="$(agent_harvest_ip)"; then
		say "WARNING: the agent answers on neither $AGENT_DHCP_IP nor $CTRL_IP -- no agent-side evidence for this round"
		return 0
	fi
	[ "$aip" = "$AGENT_DHCP_IP" ] || say "agent harvested at $aip (unconfigured -- this round did not onboard)"
	AGENT_DHCP_IP="$aip" harvest_agent "$dir"
}

harvest_agent() {
	local dir="$1"
	# The daemon's OWN mirror first, because it is the only source that does not lose the round.
	# ble-onboard writes every line it logs to /tmp/ble-onboard.log (64 KB, one generation kept)
	# precisely because the 128 KB syslog ring drops the onboarding inside minutes. On 26082223
	# r10 the syslog ring had already rotated the whole sequence away and this file still had it
	# complete, from `daemon starting` to the timeout.
	dsh "$AGENT_DHCP_IP" 'cat /tmp/ble-onboard.log.1 /tmp/ble-onboard.log 2>/dev/null' \
		| redact > "$dir/agent-ble-onboard.log"
	dsh "$AGENT_DHCP_IP" 'logread'                | redact > "$dir/agent-logread.txt"
	dsh "$AGENT_DHCP_IP" 'cat /tmp/wifi-monitor.log' | redact > "$dir/wifi-monitor.log"
	scp "${SSH_OPTS[@]}" -q "root@$AGENT_DHCP_IP:/tmp/log/messages.1.gz" "$dir/messages.1.gz" 2>/dev/null
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
	# agent-ble-onboard.log first: it is the daemon's own mirror and the one source that does
	# not lose the round to ring rotation. The others still matter -- wifi-monitor's backhaul
	# lines and the kernel/netifd context are not in it.
	local logs="$dir/agent-ble-onboard.log $dir/agent-logread.txt $dir/wifi-monitor.log"
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

# --- credential alignment -------------------------------------------------------------
#
# "Online" is not "onboarded". 26082225 r12 pinged the controller and the internet in 21 s and
# was still running its own factory SSIDs on every BSS: the prplMesh agent was stuck in
# WAIT_FOR_BACKHAUL_MANAGER_CONNECTED_NOTIFICATION (12), so no WSC M2 ever arrived and no
# credential was ever applied. A client could not roam to it and a third node could not onboard
# through it. The round looked like the best result we had measured.
#
# So the round now also asserts that every fronthaul and backhaul BSS on the agent carries the
# controller's credential.

# Every BSS a node runs, one record per BSS, read from hostapd's own runtime config -- which IS
# the credential rather than a report about it. Also reports the live driver SSID, so a hostapd
# config that never reached the radio is visible as a split brain rather than as a pass.
#
# hostapd's multi_ap field is what tells a backhaul BSS from a fronthaul one: 1=bBSS, 2=fBSS,
# 3=both. Not the SSID -- on r12 both of the agent's SSIDs looked plausible and neither was the
# controller's.
#
# The passphrase never leaves the DUT. It is reduced there to the first 8 hex of its md5, which
# is enough to see "same" or "different" and nothing more.
#
# Shipped as base64 rather than as a quoted ssh argument: the awk program needs single quotes
# and $0, and every nesting of those through ssh has been a source of silent breakage.
CREDS_REMOTE=$(cat <<'REMOTE'
for f in /var/run/hostapd-phy*.conf; do
    [ -f "$f" ] || continue
    r=${f#/var/run/hostapd-}; r=${r%.conf}
    awk -v radio="$r" '
        function role() {
            if (map == "1") return "bh"
            if (map == "2") return "fh"
            if (map == "3") return "fh+bh"
            return "plain"
        }
        function flush() {
            if (ifn != "") printf "%s|%s|%s|%s|wpa%s/%s/%s|%s\n", radio, role(), ifn, ssid, wpa, pw, km, pass
            ifn=""; ssid=""; map=""; wpa=""; pw=""; km=""; pass=""
        }
        /^interface=/ || /^bss=/ { flush(); ifn=substr($0, index($0,"=")+1) }
        /^ssid=/                 { ssid=substr($0, index($0,"=")+1) }
        /^multi_ap=/             { map=substr($0, index($0,"=")+1) }
        /^wpa=/                  { wpa=substr($0, index($0,"=")+1) }
        /^wpa_pairwise=/ || /^rsn_pairwise=/ { pw=substr($0, index($0,"=")+1) }
        /^wpa_key_mgmt=/         { km=substr($0, index($0,"=")+1) }
        /^wpa_passphrase=/       { pass=substr($0, index($0,"=")+1) }
        END { flush() }
    ' "$f"
done | while IFS="|" read -r radio role ifn ssid sec pass; do
    fp=none
    [ -n "$pass" ] && fp=$(printf %s "$pass" | md5sum | cut -c1-8)
    live=$(iw dev "$ifn" info 2>/dev/null | sed -n "s/^[[:space:]]*ssid //p")
    [ -n "$live" ] || live="(down)"
    printf "%s|%s|%s|%s|%s|%s|%s\n" "$radio" "$role" "$ifn" "$ssid" "$sec" "$fp" "$live"
done
REMOTE
)

creds_dump() {
	local b64
	b64="$(printf '%s\n' "$CREDS_REMOTE" | base64 -w0)"
	dsh "$1" "echo ${b64} | base64 -d | sh"
}

# Compare the agent's BSSes against the controller's, keyed on (role, radio) rather than on
# interface name: the CAP runs an extra bBSS and the indices need not line up, but role plus
# radio is the same question a client asks.
#
# Radio index equality assumes identical hardware on both nodes, which is this bench. On mixed
# hardware compare by band instead.
creds_check() {
	local dir="${1:-}" cf af aip rc=0 line
	local radio role ifn ssid sec fp live
	local aline assid asec afp alive problems notes verdict

	nic ctrl >/dev/null
	cf="$(creds_dump "$CTRL_IP")"
	[ -n "$cf" ] || { say "credential check: the controller returned no BSS records -- skipping"; return 1; }
	if ! aip="$(agent_harvest_ip)"; then
		say "credential check: the agent is unreachable -- cannot compare"
		return 1
	fi
	af="$(creds_dump "$aip")"
	[ -n "$af" ] || { say "credential check: the agent returned no BSS records"; return 1; }

	{
		printf 'role  radio    controller ssid / pskfp            agent ssid / pskfp                verdict\n'
		printf '%s\n' "$cf" | while IFS='|' read -r radio role ifn ssid sec fp live; do
			case "$role" in fh|bh|fh+bh) ;; *) continue ;; esac
			aline="$(printf '%s\n' "$af" | awk -F'|' -v r="$radio" -v ro="$role" '$1==r && $2==ro {print; exit}')"
			if [ -z "$aline" ]; then
				printf '%-5s %-8s %-34s %-34s %s\n' "$role" "$radio" "${ssid} / ${fp}" "-" "MISSING on the agent"
				continue
			fi
			IFS='|' read -r _ _ _ assid asec afp alive <<< "$aline"
			problems=""; notes=""
			[ "$ssid" = "$assid" ] || problems="${problems}${problems:+, }ssid"
			[ "$fp"   = "$afp"   ] || problems="${problems}${problems:+, }psk"
			# wpa version and pairwise cipher are the credential; key_mgmt is a set the AP
			# offers and the CAP legitimately advertises more of it (WPA-PSK-SHA256 for 11w),
			# so a difference there is worth printing and not worth failing a round over.
			[ "${sec%%/*}" = "${asec%%/*}" ] || problems="${problems}${problems:+, }wpa-version"
			[ "$(printf %s "$sec" | cut -d/ -f2)" = "$(printf %s "$asec" | cut -d/ -f2)" ] \
				|| problems="${problems}${problems:+, }pairwise"
			[ "${sec#*/*/}" = "${asec#*/*/}" ] || notes="key_mgmt CAP=${sec#*/*/} agent=${asec#*/*/}"
			# A credential hostapd holds but the radio never took is not a credential.
			[ "$alive" = "$assid" ] || problems="${problems}${problems:+, }not-on-air(driver=${alive})"
			if [ -n "$problems" ]; then
				verdict="MISMATCH: ${problems}"
			else
				verdict="aligned"
			fi
			printf '%-5s %-8s %-34s %-34s %s\n' "$role" "$radio" "${ssid} / ${fp}" "${assid} / ${afp}" \
				"${verdict}${notes:+  [${notes}]}"
		done
	} > /tmp/.creds-report.$$

	cat /tmp/.creds-report.$$
	grep -qE 'MISMATCH|MISSING' /tmp/.creds-report.$$ && rc=1
	if [ -n "$dir" ]; then
		mkdir -p "$dir"
		redact < /tmp/.creds-report.$$ > "$dir/creds.txt"
	fi
	rm -f /tmp/.creds-report.$$
	if [ "$rc" = "0" ]; then
		say "credential check: PASS -- every fronthaul and backhaul BSS matches the controller"
	else
		say "credential check: FAIL -- the agent is not carrying the controller's credentials"
	fi
	return "$rc"
}

# Poll creds_check until every BSS carries the controller's credentials, and report the agent
# uptime at which that became true. This, not reachability, is when onboarding is finished.
#
# It is a poll and not a single shot because the credentials do not always arrive on the first
# pass of the agent's registration. 26082314 r17: reachable at agent uptime 216.4, registration
# stalled in WAIT_FOR_BACKHAUL_MANAGER_REGISTER_RESPONSE (7), lsmesh-sta-iface-repair killed
# beerocks_agent (attempt 1/2), and the CAP's SSIDs landed on all three BSSes after the 60 s
# settle window had already closed -- so the round was recorded FAIL and was, minutes later,
# a PASS. A single shot measures when we happened to look; this measures the event.
creds_wait() {
	local dir="${1:-}" deadline="${2:-$CREDS_DEADLINE}" waited=0 up
	while : ; do
		if creds_check "$dir" > "${dir:-/tmp}/.creds-last" 2>&1; then
			cat "${dir:-/tmp}/.creds-last"
			up="$(agent_uptime)"
			say "credentials aligned at agent uptime ${up:-unknown} (${waited}s into the credential wait)"
			[ -n "$dir" ] && printf '%s\n' "${up:-unknown}" > "$dir/creds-uptime"
			rm -f "${dir:-/tmp}/.creds-last"
			return 0
		fi
		if [ "$waited" -ge "$deadline" ]; then
			cat "${dir:-/tmp}/.creds-last"
			say "credentials still not aligned ${waited}s after the settle window -- this round FAILS the credential bar"
			rm -f "${dir:-/tmp}/.creds-last"
			return 1
		fi
		[ $(( waited % CREDS_POLL_REPORT )) = 0 ] && [ "$waited" -gt 0 ] \
			&& say "  ...${waited}s, credentials not aligned yet"
		sleep "$CREDS_POLL"
		waited=$((waited + CREDS_POLL))
	done
}

# Agent uptime in seconds, echoed, or empty if the agent cannot be reached. Kept separate from
# the harvest so it can be sampled cheaply inside a poll.
agent_uptime() {
	local aip
	aip="$(agent_harvest_ip)" || return 1
	dsh "$aip" 'awk "{print \$1}" /proc/uptime' 2>/dev/null
}

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

	# Last, and it decides the round. Reaching the internet proves the bSTA associated; it says
	# nothing about whether the agent was ever configured as a mesh AP.
	creds_wait "$dir"
}

# --- entry point -----------------------------------------------------------------------

cmd="${1:-}"; shift || true
case "$cmd" in
	nic)      nic "${1:?ctrl|agent|both}" ;;
	identify) identify "${1:?ip}" ;;
	flash)    flash "${1:?image}" "${2:?ip}" "${3:-}" ;;
	reset)    reset_node "${1:?ip}" "${2:-}" ;;
	trigger)  trigger ;;
	creds)
		dir=""
		[ "${1:-}" = "-o" ] && dir="$2"
		creds_check "$dir"
		;;
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
