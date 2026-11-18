# Shared helpers for vm-ailock-matrix.sh. Bash 3.2 (macOS /bin/bash).
# The entry script sets DRY_RUN, PHASE, EXPECT, HOST_KIND, WORK, JSON, repo revisions.

FIXTURE_SUFFIX=ailock-fixture.example.com
FIXTURE_CIDR=198.51.100.0/24
FIXTURE_HOST=198.51.100.10
FIXTURE_TCP_PORT=8080
# Loopback SOCKS the relay uses as its Home line (freedom outbound). The
# kernel does not dial this port; AI targets are Home on the relay, and the
# relay never sends a confirmed AI target direct.
SOCKS_PORT=18081
KERNEL_DNS_PORT=15353
KERNEL_SOCKS_PORT=18080
# segue-relay listens here. Older cores bound the kernel's carrier sockets
# to the physical NIC (IP_BOUND_IF), which cannot dial 127.0.0.1; the alias
# mode keeps that world: CARRIER_HOST is an alias on the NIC and a
# forwarder there splices the carrier to the relay. Loopback mode (the
# default) points the exit straight at 127.0.0.1 and needs neither.
RELAY_PORT=17443
RELAY_METRICS_PORT=17444
CARRIER_HOST=192.0.2.10
CARRIER_IFACE=
GUARD_PORT=5354
UNLISTED_HOST=203.0.113.50
UNLISTED_PORT=443
# Second lo0 alias, TEST-NET-3, not inside FIXTURE_CIDR. The leak row serves
# TCP and UDP here so the expected leak does not need the internet.
LEAK_HOST=203.0.113.10
LEAK_PORT=443
LOOPBACK_PORT=18099
ANCHOR=segue.ailock
HELPER_LABEL=com.segue.core-helper
SUPPORT="/Library/Application Support/Segue"
HELPER_DST=/Library/PrivilegedHelperTools/segue-core-helper
KERNEL_DST=/Library/PrivilegedHelperTools/segue-kernel
SEGUE_DST=/Library/PrivilegedHelperTools/segue
RELAY_DST=/Library/PrivilegedHelperTools/segue-relay
RELEASE_DST=/Library/PrivilegedHelperTools/segue-release
RELEASE_CTL_DST=/Library/PrivilegedHelperTools/segue-release-ctl
RELEASE_SOCK=/var/run/segue-release.sock
# Ad-hoc identifier signed onto segue-release-ctl. The matrix daemon is
# started with a matching identifier requirement because a throwaway VM has
# no Developer ID. Production plists omit --requirement.
RELEASE_CTL_ID=com.raydocs.segue.vm-matrix
UID_DST=/Library/PrivilegedHelperTools/segue.allowed-uid
# The matrix probe is /usr/bin/python3, which execs Xcode's interpreter
# (identifier com.apple.python3, anchor apple). The production helper has
# no --requirement and only admits the Developer ID app. Without this,
# status_read is "peer denied: code_signing" and helper_kernel_up never
# sees the utun, even when the kernel is up.
HELPER_PROBE_REQUIREMENT='identifier "com.apple.python3" and anchor apple'
HELPER_PLIST=/Library/LaunchDaemons/com.segue.core-helper.plist
RELEASE_PLIST=/Library/LaunchDaemons/com.segue.release.plist
INTENT="${SUPPORT}/ai-lock.intent"
FIXTURE_LIST="${SUPPORT}/ai-lock.fixture.txt"
RESOLVER_FILE="/etc/resolver/${FIXTURE_SUFFIX}"
PROBES="${VM_DIR}/probes.py"
REPORT="${VM_DIR}/report.py"

SEEN_ROWS=" "
EXIT_CODE=0
SKIP_CLEANUP=0
CLEANED=0
# Default: the helper starts and supervises segue-kernel (arm -> start).
# --kernel-by-script restores the old path where this script execs the
# kernel itself; then no kernel.json is installed where the helper looks,
# so the helper's own start attempt settles as config_rejected instead of
# fighting the script's kernel for the ports. The entry script owns the
# value: it parses --kernel-by-script before sourcing this file.
: "${KERNEL_BY_SCRIPT:=0}"

kernel_by_script() {
  [[ "$KERNEL_BY_SCRIPT" == 1 ]]
}

# Where the kernel's AI exit dials segue-relay (same port in both modes).
# The entry script owns the value: it parses --exit-via before sourcing
# this file. loopback: the exit relay is 127.0.0.1 (the core's carrier can
# dial lo0; no alias, no forwarder). alias: 192.0.2.10 on the physical
# NIC, with a forwarder to the relay, for comparison with older cores.
: "${EXIT_VIA:=loopback}"

exit_via_alias() {
  [[ "$EXIT_VIA" == alias ]]
}

RELAY_DIAL_HOST=127.0.0.1
if exit_via_alias; then
  RELAY_DIAL_HOST="$CARRIER_HOST"
fi

dry() {
  [[ "$DRY_RUN" == 1 ]]
}

quote_cmd() {
  local prefix="$1"
  shift
  printf '%s' "$prefix"
  local arg
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

# plan prints a non-privileged command. priv prints one that needs root
# or mutates PF, DNS, launchd, or /Library. In --dry-run neither runs.
plan() {
  if dry; then
    quote_cmd PLAN "$@"
    return 0
  fi
  "$@"
}

priv() {
  if dry; then
    quote_cmd PRIV "$@"
    return 0
  fi
  "$@"
}

note() {
  if dry; then
    printf 'PLAN note: %s\n' "$1"
  fi
}

seen() {
  case " $SEEN_ROWS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

record() {
  local name="$1" result="$2" evidence="$3"
  if seen "$name"; then
    return 0
  fi
  SEEN_ROWS="$SEEN_ROWS $name"
  if [[ "$result" == "FAIL" ]] && ! dry; then
    evidence="${evidence}
$(capture_fail_context)"
  fi
  printf '\nROW %s %s\n%s\n' "$result" "$name" "$evidence"
  printf '%s' "$evidence" | /usr/bin/python3 "$REPORT" add "$JSON" "$name" "$result"
  if [[ "$result" == "FAIL" ]]; then
    EXIT_CODE=1
  fi
}

skip_pending() {
  local why="$1" name
  for name in \
    armed-kernel-not-running \
    connected \
    kill-kernel \
    kill-helper \
    restore-via-release-daemon \
    expected-leak-doh-quic \
    reboot-armed \
    reboot-clear
  do
    if ! seen "$name"; then
      record "$name" SKIP "$why"
    fi
  done
}

wait_until() {
  local tries="$1"
  shift
  local i=0
  while [[ "$i" -lt "$tries" ]]; do
    if "$@"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

num() {
  case "$1" in
    ""|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

kv() {
  # First line's value for key= in a key=value blob. Digits or a single token.
  local key="$1" text="$2" rest
  rest="${text#*${key}=}"
  if [[ "$rest" == "$text" ]]; then
    printf '0\n'
    return 0
  fi
  rest="${rest%%$'\n'*}"
  printf '%s\n' "${rest%% *}"
}

resolver_present() {
  [[ -f "$RESOLVER_FILE" ]]
}

# Port line of the armed suffix file. Empty when the file is missing.
resolver_port() {
  [[ -f "$RESOLVER_FILE" ]] || return 1
  awk '$1 == "port" { print $2; exit }' "$RESOLVER_FILE"
}

# nameserver 127.0.0.1 and an exact port. resolver(5) is what carries the
# kernel's non-53 port; networksetup cannot.
resolver_points_at() {
  local want="$1" got
  [[ -f "$RESOLVER_FILE" ]] || return 1
  grep -qx 'nameserver 127.0.0.1' "$RESOLVER_FILE" || return 1
  got=$(resolver_port) || return 1
  [[ "$got" == "$want" ]]
}

resolver_kernel_port() {
  resolver_points_at "$KERNEL_DNS_PORT"
}

resolver_guard_port() {
  resolver_points_at "$GUARD_PORT"
}

socket_present() {
  [[ -S /var/run/segue/service.sock ]]
}

guard_answers() {
  local out
  out=$(/usr/bin/dig +time=1 +tries=1 @127.0.0.1 -p "$GUARD_PORT" "www.${FIXTURE_SUFFIX}" A 2>&1 || true)
  dig_empty_noerror "$out"
}

anchor_has_fixture() {
  /sbin/pfctl -a "$ANCHOR" -sr 2>/dev/null | grep -F "$FIXTURE_CIDR" >/dev/null 2>&1
}

main_has_anchor() {
  /sbin/pfctl -sr 2>/dev/null | grep -F "$ANCHOR" >/dev/null 2>&1
}

helper_pid() {
  /usr/bin/pgrep -x segue-core-helper 2>/dev/null | head -n 1 || true
}

utun_list() {
  /sbin/ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^utun' | tr '\n' ' ' || true
}

dig_query() {
  /usr/bin/dig +time=2 +tries=1 "$1" A 2>&1 || true
}

dig_empty_noerror() {
  printf '%s\n' "$1" | grep -q 'status: NOERROR' || return 1
  printf '%s\n' "$1" | grep -Eq 'ANSWER: 0(,|[[:space:]]|$)' || return 1
  return 0
}

# System dig of an armed name: empty NOERROR, and the answer came from the
# helper's loopback guard rather than the VPC resolver.
dig_held_by_guard() {
  dig_empty_noerror "$1" || return 1
  printf '%s\n' "$1" | grep -Eq 'SERVER: 127\.0\.0\.1#'
}

dig_at_guard() {
  /usr/bin/dig +time=2 +tries=1 @127.0.0.1 -p "$GUARD_PORT" "$1" A 2>&1 || true
}

dig_has_answer() {
  printf '%s\n' "$1" | grep -Eq 'ANSWER: [1-9]'
}

# An A answer in 198.18.0.0/15 (the kernel's fake-IP range).
dig_fake_ip() {
  printf '%s\n' "$1" | grep -Eq '198\.1[89]\.[0-9]+\.[0-9]+'
}

dig_timed_out() {
  printf '%s\n' "$1" | grep -Eq 'timed out|no servers could be reached'
}

log_tail() {
  if [[ -f "$1" ]]; then
    tail -n 40 "$1"
  else
    printf 'no log %s\n' "$1"
  fi
}

# Printed on every FAIL row. Dry-run lists the same commands via plan_fail_probes.
capture_fail_context() {
  {
    printf '%s\n' "--- launchctl helper ---"
    /bin/launchctl print "system/${HELPER_LABEL}" 2>&1 | /usr/bin/head -n 80 || true
    printf '%s\n' "--- launchctl release ---"
    /bin/launchctl print "system/${RELEASE_LABEL:-com.segue.release}" 2>&1 | /usr/bin/head -n 80 || true
    printf '%s\n' "--- helper.err ---"
    log_tail "${WORK}/logs/helper.err"
    printf '%s\n' "--- kernel.log ---"
    log_tail "${WORK}/logs/kernel.log"
    printf '%s\n' "--- kernel.stdout ---"
    log_tail "${WORK}/logs/kernel.stdout"
    printf '%s\n' "--- kernel.stderr ---"
    log_tail "${WORK}/logs/kernel.stderr"
    printf '%s\n' "--- sockets ---"
    /bin/ls -l /var/run/segue /var/run/segue/service.sock /var/run/segue-release.sock 2>&1 || true
    printf '%s\n' "--- guard listener ---"
    /usr/sbin/lsof -nP -iUDP:"${GUARD_PORT}" 2>&1 | /usr/bin/head -n 40 || true
    printf '%s\n' "--- scutil dns ---"
    /usr/sbin/scutil --dns 2>&1 | /usr/bin/head -n 60 || true
    printf '%s\n' "--- kernel /v1/status ---"
    kernel_status_text
    printf '%s\n' "--- relay metrics ---"
    /usr/bin/python3 "$PROBES" relay-metrics "$RELAY_METRICS_PORT" 2>&1 || true
    printf '%s\n' "--- relay log ---"
    log_tail "${WORK}/logs/relay.pid.log"
    printf '%s\n' "--- carrier route ---"
    if [[ -f "${WORK}/state/carrier.route" ]]; then
      /bin/cat "${WORK}/state/carrier.route" 2>&1 || true
    else
      printf 'no carrier route\n'
    fi
  } 2>&1 || true
}

plan_fail_probes() {
  if ! dry; then
    return 0
  fi
  plan /bin/launchctl print "system/${HELPER_LABEL}"
  plan /bin/launchctl print system/com.segue.release
  plan /bin/ls -l /var/run/segue /var/run/segue/service.sock /var/run/segue-release.sock
  plan /usr/sbin/lsof -nP -iUDP:"${GUARD_PORT}"
  plan /usr/sbin/scutil --dns
  plan /usr/bin/python3 "$PROBES" kernel-status "${SUPPORT}/kernel/control.json"
  plan /usr/bin/python3 "$PROBES" relay-metrics "$RELAY_METRICS_PORT"
  note "FAIL rows also include the tails of helper.err, kernel.log, kernel.stdout, kernel.stderr and relay.pid.log, plus the full kernel /v1/status JSON"
}

toolchain() {
  if [[ -z "${CARGO_TARGET_DIR:-}" && -d /Volumes/dev/ci/cargo/bin ]]; then
    export CARGO_HOME=/Volumes/dev/ci/cargo
    export RUSTUP_HOME=/Volumes/dev/ci/rustup
    export CARGO_TARGET_DIR=/Volumes/dev/ci/app-target.noindex
    export PATH="/Volumes/dev/ci/cargo/bin:${PATH}"
  fi
  if [[ -z "${CARGO_TARGET_DIR:-}" ]]; then
    export CARGO_TARGET_DIR="${WORK}/target"
  fi
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  note "CARGO_TARGET_DIR=${CARGO_TARGET_DIR}"
}

sync_repo() {
  local url="$1" dest="$2" rev="$3"
  note "clone ${url} only when ${dest} has no .git; then fetch that revision"
  if dry; then
    plan /usr/bin/git clone "$url" "$dest"
    plan /usr/bin/git -C "$dest" fetch --tags "$url" "$rev"
    plan /usr/bin/git -C "$dest" checkout --detach FETCH_HEAD
    return 0
  fi
  export GIT_TERMINAL_PROMPT=0
  if [[ ! -d "${dest}/.git" ]]; then
    /usr/bin/git clone "$url" "$dest" || return 1
  fi
  /usr/bin/git -C "$dest" fetch --tags "$url" "$rev" || return 1
  /usr/bin/git -C "$dest" checkout --detach FETCH_HEAD || return 1
}

prepare_tree() {
  local core_rev="${CORE_REV:-<core-rev>}" app_rev="${APP_REV:-<app-rev>}"
  toolchain
  CORE_SRC="${WORK}/src/segue-core"
  APP_SRC="${WORK}/src/segue-app"
  if dry; then
    sync_repo "$CORE_REPO" "$CORE_SRC" "$core_rev"
    sync_repo "$APP_REPO" "$APP_SRC" "$app_rev"
    plan cargo build --release --manifest-path "${CORE_SRC}/Cargo.toml" -p segue-kernel -p segue-cli -p segue-relay
    plan swift build -c release --package-path "${APP_SRC}/apps/macos"
    KERNEL_BUILT="${CARGO_TARGET_DIR}/release/segue-kernel"
    SEGUE_BUILT="${CARGO_TARGET_DIR}/release/segue"
    RELAY_BUILT="${CARGO_TARGET_DIR}/release/segue-relay"
    HELPER_BIN="${APP_SRC}/apps/macos/.build/release/segue-core-helper"
    return 0
  fi
  if [[ "$SKIP_BUILD" == 1 ]]; then
    note "skip-build: using an existing checkout and release binaries"
  else
    if [[ -z "${CORE_REV}" || -z "${APP_REV}" ]]; then
      echo "need --core-rev and --app-rev (or --skip-build)" >&2
      return 1
    fi
    sync_repo "$CORE_REPO" "$CORE_SRC" "$CORE_REV" || return 1
    sync_repo "$APP_REPO" "$APP_SRC" "$APP_REV" || return 1
    mkdir -p "${WORK}/logs"
    if ! cargo build --release --manifest-path "${CORE_SRC}/Cargo.toml" -p segue-kernel -p segue-cli -p segue-relay >"${WORK}/logs/cargo.log" 2>&1; then
      echo "cargo build failed; see ${WORK}/logs/cargo.log" >&2
      return 1
    fi
    if ! swift build -c release --package-path "${APP_SRC}/apps/macos" >"${WORK}/logs/swift.log" 2>&1; then
      echo "swift build failed; see ${WORK}/logs/swift.log" >&2
      return 1
    fi
  fi
  KERNEL_BUILT="${CARGO_TARGET_DIR}/release/segue-kernel"
  SEGUE_BUILT="${CARGO_TARGET_DIR}/release/segue"
  RELAY_BUILT="${CARGO_TARGET_DIR}/release/segue-relay"
  HELPER_BIN="${APP_SRC}/apps/macos/.build/release/segue-core-helper"
  if [[ ! -x "$KERNEL_BUILT" || ! -x "$SEGUE_BUILT" || ! -x "$RELAY_BUILT" || ! -x "$HELPER_BIN" ]]; then
    echo "missing segue-kernel, segue, segue-relay, or segue-core-helper" >&2
    return 1
  fi
}

write_intent() {
  local armed="$1" name="$2" gen="$3"
  mkdir -p "${WORK}/state"
  printf '{"armed":%s,"generation":%s,"name":"%s"}\n' "$armed" "$gen" "$name" > "${WORK}/state/intent.json"
  priv /bin/mkdir -p "$SUPPORT" || return 1
  priv /bin/cp "${WORK}/state/intent.json" "$INTENT" || return 1
  priv /bin/chmod 600 "$INTENT" || return 1
}

copy_fixture_list() {
  mkdir -p "${WORK}/state"
  cat > "${WORK}/state/ai-lock.fixture.txt" <<EOF
# VM matrix fixture. Not the product ai-lock.txt (that file is not modified).
# The kernel merges ${FIXTURE_SUFFIX} and ${FIXTURE_CIDR} from the signed
# bundle. The helper reads this file because it does not merge a bundle yet.
suffix ${FIXTURE_SUFFIX}
cidr ${FIXTURE_CIDR}
EOF
  priv /bin/mkdir -p "$SUPPORT" || return 1
  priv /bin/cp "${WORK}/state/ai-lock.fixture.txt" "$FIXTURE_LIST" || return 1
  priv /bin/chmod 644 "$FIXTURE_LIST" || return 1
}

write_helper_plist() {
  mkdir -p "${WORK}/state" "${WORK}/logs"
  cat > "${WORK}/state/helper.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${HELPER_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${HELPER_DST}</string>
		<string>--ai-lock</string>
		<string>${FIXTURE_LIST}</string>
		<string>--kernel</string>
		<string>${KERNEL_DST}</string>
		<string>--config</string>
		<string>${SUPPORT}/kernel.json</string>
		<string>--state-dir</string>
		<string>${SUPPORT}/kernel</string>
		<string>--kernel-log</string>
		<string>${WORK}/logs/kernel.log</string>
		<string>--intent</string>
		<string>${INTENT}</string>
		<string>--socket</string>
		<string>/var/run/segue/service.sock</string>
		<string>--allowed-uids</string>
		<string>${UID_DST}</string>
		<string>--requirement</string>
		<string>${HELPER_PROBE_REQUIREMENT}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${WORK}/logs/helper.out</string>
	<key>StandardErrorPath</key>
	<string>${WORK}/logs/helper.err</string>
</dict>
</plist>
EOF
}

install_daemons() {
  note "the fixture exit is segue-relay on 127.0.0.1:${RELAY_PORT}. The kernel's AI route is that relay (segue exit_class ai)."
  if exit_via_alias; then
    note "exit-via alias: the kernel dials ${CARRIER_HOST}:${RELAY_PORT}, an alias of the physical NIC; a forwarder there splices the carrier to the relay, because IP_BOUND_IF cannot dial loopback."
  else
    note "exit-via loopback: the kernel dials the relay on 127.0.0.1:${RELAY_PORT} directly; no NIC alias and no forwarder."
  fi
  note "the helper captures the kernel child's stdout and stderr to ${WORK}/logs/kernel.stdout and kernel.stderr (mode 0600, rotated at 1 MiB next to kernel.log); while the kernel state is kernel_failed, status_read also carries the redacted tail as kernel_last_stderr."
  note "fixture AI suffix and CIDR are added by a signed policy bundle. The product ai-lock.txt is not edited."
  note "arm starts segue-kernel via the helper: it supervises the child, restarts it on crash, and polls /v1/status (control section in kernel.json, token under ${SUPPORT}/kernel) for the utun. --kernel-by-script execs the kernel here instead, for debugging."
  note "helper --requirement admits ${HELPER_PROBE_REQUIREMENT} so the python probe can status_read and re-arm. Production plists omit --requirement."
  write_helper_plist
  printf '0\n' > "${WORK}/state/allowed-uid"
  priv /bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons /var/run/segue "$SUPPORT" "${SUPPORT}/kernel" "${WORK}/logs" || return 1
  priv /bin/cp "$HELPER_BIN" "$HELPER_DST" || return 1
  priv /bin/chmod 755 "$HELPER_DST" || return 1
  priv /bin/cp "$KERNEL_BUILT" "$KERNEL_DST" || return 1
  priv /bin/chmod 755 "$KERNEL_DST" || return 1
  priv /bin/cp "$SEGUE_BUILT" "$SEGUE_DST" || return 1
  priv /bin/chmod 755 "$SEGUE_DST" || return 1
  priv /bin/cp "$RELAY_BUILT" "$RELAY_DST" || return 1
  priv /bin/chmod 755 "$RELAY_DST" || return 1
  priv /bin/cp "${WORK}/state/allowed-uid" "$UID_DST" || return 1
  priv /bin/chmod 644 "$UID_DST" || return 1
  priv /bin/cp "${WORK}/state/helper.plist" "$HELPER_PLIST" || return 1
  priv /bin/chmod 644 "$HELPER_PLIST" || return 1
  priv /bin/chmod 700 "${SUPPORT}/kernel" || return 1
  if dry; then
    priv /bin/launchctl bootout system "$HELPER_PLIST"
  else
    /bin/launchctl bootout system "$HELPER_PLIST" >/dev/null 2>&1 || true
  fi
  priv /bin/launchctl bootstrap system "$HELPER_PLIST" || return 1
}

save_dns() {
  if dry; then
    priv /usr/sbin/networksetup -listallnetworkservices
    priv /usr/sbin/networksetup -getdnsservers '<service>'
    return 0
  fi
  /usr/bin/python3 "$PROBES" dns-save "${WORK}/state/dns.snapshot"
}

restore_dns() {
  if dry; then
    priv /usr/sbin/networksetup -setdnsservers '<service>' '<saved-or-Empty>'
    return 0
  fi
  if [[ -f "${WORK}/state/dns.snapshot" ]]; then
    /usr/bin/python3 "$PROBES" dns-restore "${WORK}/state/dns.snapshot" || true
  fi
}

backup_pf() {
  mkdir -p "${WORK}/state"
  if dry; then
    priv /bin/cp /etc/pf.conf "${WORK}/state/pf.conf.bak"
    return 0
  fi
  if [[ -f /etc/pf.conf ]]; then
    /bin/cp /etc/pf.conf "${WORK}/state/pf.conf.bak"
  else
    : > "${WORK}/state/pf.conf.bak"
  fi
}

enable_pf() {
  if dry; then
    priv /sbin/pfctl -E
    return 0
  fi
  local out token
  out=$(/sbin/pfctl -E 2>&1) || true
  printf '%s\n' "$out" > "${WORK}/state/pf-enable.txt"
  token=$(printf '%s\n' "$out" | sed -n 's/.*Token : \([0-9][0-9]*\).*/\1/p' | head -n 1)
  if [[ -n "$token" ]]; then
    printf '%s\n' "$token" > "${WORK}/state/pf.token"
  fi
}

try_socket_arm() {
  local payload
  payload="{\"version\":1,\"kind\":\"arm\",\"arm\":{\"schemaVersion\":1,\"generation\":1,\"intent\":\"user_connect\",\"anchor_revision\":1,\"manifest_digest\":\"vm-matrix\",\"egress\":[{\"ip\":\"${RELAY_DIAL_HOST}\",\"port\":${RELAY_PORT}}],\"exit_ifaces\":[\"${CARRIER_IFACE:-lo0}\"],\"strict\":false,\"evidence\":{\"policy_version\":1,\"posture\":\"vm-matrix\"}}}"
  if dry; then
    plan /usr/bin/python3 "$PROBES" helper /var/run/segue/service.sock '<arm-json>'
    printf 'socket=dry-run\n'
    return 0
  fi
  /usr/bin/python3 "$PROBES" helper /var/run/segue/service.sock "$payload" 2>&1 || true
}

# True when the helper accepted the arm (a status envelope). An error
# envelope — peer denied, malformed — is a failure. The reply is also
# appended to the socket-arm log the step dump prints.
socket_arm() {
  local out
  if dry; then
    try_socket_arm
    return 0
  fi
  out=$(try_socket_arm)
  mkdir -p "${WORK}/state"
  printf '%s\n' "$out" >> "${WORK}/state/socket-arm.txt"
  printf '%s\n' "$out" | grep -q '"kind"[[:space:]]*:[[:space:]]*"status"'
}

# Set by arm_helper when a step fails. run_all puts both into the row.
ARM_FAIL_STEP=""
ARM_FAIL_DUMP=""

# What an arm failure needs and the row previously lacked: which wait
# died, and the helper/kernel/PF state at that moment.
arm_state_dump() {
  local step="$1" token="${SUPPORT}/kernel/control.json" payload
  payload='{"version":1,"kind":"status_read"}'
  {
    printf 'arm_step=%s\n' "$step"
    printf 'now=%s\n' "$(/bin/date -u +%H:%M:%S)"
    printf 'socket_stat=%s\n' "$(/usr/bin/stat -f '%Sm type=%HT' -t %H:%M:%S /var/run/segue/service.sock 2>&1)"
    printf 'helper_started=%s\n' "$(/bin/ps -o lstart= -p "$(/usr/bin/pgrep -x segue-core-helper | head -n 1)" 2>&1)"
    printf 'arm_trace=%s\n' "${ARM_TRACE:-}"
    printf '%s\n' "--- status_read ---"
    /usr/bin/python3 "$PROBES" helper /var/run/segue/service.sock "$payload" 2>&1 || true
    printf '%s\n' "--- status_parsed ---"
    helper_kernel_status || true
    printf '%s\n' "--- socket-arm ---"
    if [[ -f "${WORK}/state/socket-arm.txt" ]]; then
      /bin/cat "${WORK}/state/socket-arm.txt" 2>&1 || true
    else
      printf 'no socket-arm reply\n'
    fi
    printf '%s\n' "--- control.json ---"
    if [[ -f "$token" ]]; then
      /bin/cat "$token" 2>&1 || true
    else
      printf 'missing %s\n' "$token"
    fi
    printf '%s\n' "--- kernel /v1/status ---"
    kernel_status_text
    printf '%s\n' "--- intent ---"
    if [[ -f "$INTENT" ]]; then
      /bin/cat "$INTENT" 2>&1 || true
    else
      printf 'missing %s\n' "$INTENT"
    fi
    printf '%s\n' "--- resolver files ---"
    /bin/ls -l /etc/resolver 2>&1 || true
    if [[ -f "$RESOLVER_FILE" ]]; then
      printf '%s\n' "--- ${RESOLVER_FILE} ---"
      /bin/cat "$RESOLVER_FILE" 2>&1 || true
    else
      printf 'missing %s\n' "$RESOLVER_FILE"
    fi
    printf '%s\n' "--- pfctl -a ${ANCHOR} -s rules ---"
    /sbin/pfctl -a "$ANCHOR" -s rules 2>&1 || true
    printf '%s\n' "--- guard dig ---"
    /usr/bin/dig +time=1 +tries=1 @127.0.0.1 -p "$GUARD_PORT" "www.${FIXTURE_SUFFIX}" A 2>&1 || true
  } 2>&1 || true
  return 0
}

arm_failed() {
  ARM_FAIL_STEP="$1"
  if dry; then
    note "arm failed at step ${1}"
    plan_arm_evidence
    ARM_FAIL_DUMP="dry-run step ${1}"
    return 1
  fi
  ARM_FAIL_DUMP=$(arm_state_dump "$1")
  return 1
}

# wait_until, and on timeout record the step name plus arm_state_dump.
arm_wait() {
  local tries="$1" step="$2"
  shift 2
  ARM_TRACE="${ARM_TRACE:-}${step}@$(/bin/date -u +%H:%M:%S) "
  if wait_until "$tries" "$@"; then
    return 0
  fi
  arm_failed "$step"
}

# Commands a dry-run lists for the step dump, so the plan shows the
# evidence a failed arm row would carry.
plan_arm_evidence() {
  note "arm steps, in order: socket_present, socket_arm, resolver_present, pf_reload (only if the main ruleset does not reference the anchor), anchor_refill, anchor_has_fixture, guard_answers, helper_kernel_up, kernel_posture_connected (GET /v1/status state=connected), resolver_kernel_port (resolver_guard_port when the helper has no utun)"
  note "a failed step records its name plus this evidence: status_read reply, parsed kernel_state/pid/tun/last_stderr, socket-arm reply, control.json, the full kernel /v1/status JSON, the intent file, resolver files (nameserver 127.0.0.1 and port ${KERNEL_DNS_PORT} when connected, otherwise port ${GUARD_PORT}), pfctl -a ${ANCHOR} -s rules, guard dig"
  plan /usr/bin/python3 "$PROBES" helper /var/run/segue/service.sock '<status_read>'
  plan /usr/bin/python3 "$PROBES" kernel-status "${SUPPORT}/kernel/control.json"
  plan /bin/cat "${SUPPORT}/kernel/control.json"
  plan /bin/cat "$INTENT"
  plan /bin/ls -l /etc/resolver
  plan /bin/cat "$RESOLVER_FILE"
  plan grep -qx "port ${KERNEL_DNS_PORT}" "$RESOLVER_FILE"
  plan grep -qx "port ${GUARD_PORT}" "$RESOLVER_FILE"
  plan /sbin/pfctl -a "$ANCHOR" -s rules
  plan /usr/bin/dig +time=1 +tries=1 @127.0.0.1 -p "$GUARD_PORT" "www.${FIXTURE_SUFFIX}" A
}

arm_helper() {
  ARM_FAIL_STEP=""
  ARM_FAIL_DUMP=""
  copy_fixture_list || { arm_failed copy_fixture; return 1; }
  # The stack the kernel needs goes in before the intent: the helper reads
  # kernel.json the moment it arms. In --kernel-by-script the script execs
  # the kernel first, so the helper's own start settles config_rejected
  # and leaves the script's kernel the ports.
  prepare_kernel_stack || { arm_failed prepare_kernel; return 1; }
  if kernel_by_script; then
    start_kernel_process || { arm_failed start_kernel_process; return 1; }
  fi
  write_intent true user_connect 1 || { arm_failed write_intent; return 1; }
  note "same-boot PF: the helper writes the anchor line into /etc/pf.conf but does not reload it. The harness runs pfctl -f /etc/pf.conf so the anchor is referenced. That reload flushes anchor contents, so the harness sends arm again on the socket to refill them. It does not kickstart the helper: a kickstart SIGTERMs the kernel, and the new process binds a new control port."
  note "the helper polls the intent file, so the arm is noticed without a restart. The helper was started before this file existed."
  note "arm steps: socket_present, socket_arm, resolver_present, anchor_has_fixture, guard_answers, helper_kernel_up, kernel_posture_connected, resolver_kernel_port. The resolver file is nameserver 127.0.0.1 and port ${KERNEL_DNS_PORT} once GET /v1/status reports state=connected and a utun, otherwise port ${GUARD_PORT}. dig @127.0.0.1 -p ${GUARD_PORT} must be empty NOERROR. A resolver file is replaced in place, never unlinked, to change ports."
  if dry; then
    plan test -S /var/run/segue/service.sock
    socket_arm
    plan test -f "$RESOLVER_FILE"
    priv /sbin/pfctl -sr
    priv /sbin/pfctl -f /etc/pf.conf
    socket_arm
    plan /sbin/pfctl -a "$ANCHOR" -s rules
    plan /usr/bin/dig +time=1 +tries=1 @127.0.0.1 -p "$GUARD_PORT" "www.${FIXTURE_SUFFIX}" A
    if kernel_by_script; then
      note "kernel-by-script: the kernel above was exec'd by this script, not the helper. Resolver file stays on the guard port."
      plan grep -qx "port ${GUARD_PORT}" "$RESOLVER_FILE"
    else
      note "the helper starts ${KERNEL_DST} run --state-dir ${SUPPORT}/kernel --log ${WORK}/logs/kernel.log ${SUPPORT}/kernel.json at arm and reports it over status_read (kernel_state=running, kernel_pid, tun=utun<N>)."
      plan /usr/bin/python3 "$PROBES" helper /var/run/segue/service.sock '<status_read: kernel_state=running kernel_pid=<pid> tun=utun<N>>'
      note "arm success once that utun is up and GET /v1/status state is connected: ${RESOLVER_FILE} has nameserver 127.0.0.1 and port ${KERNEL_DNS_PORT} (dns_mode=kernel, ai_layer=tunnel). Before the carrier, the same file names port ${GUARD_PORT}."
      plan /usr/bin/python3 "$PROBES" kernel-status "${SUPPORT}/kernel/control.json"
      plan grep -qx "nameserver 127.0.0.1" "$RESOLVER_FILE"
      plan grep -qx "port ${KERNEL_DNS_PORT}" "$RESOLVER_FILE"
    fi
    plan_arm_evidence
    priv /usr/bin/dscacheutil -flushcache
    priv /usr/bin/killall -HUP mDNSResponder
    return 0
  fi
  # No kickstart. The running helper polls the intent file and the socket
  # arm below installs the same generation. Restarting it would SIGTERM
  # the kernel the first arm had just started.
  arm_wait 60 socket_present socket_present || return 1
  socket_arm >/dev/null || { arm_failed socket_arm; return 1; }
  arm_wait 20 resolver_present resolver_present || return 1
  if ! main_has_anchor; then
    /sbin/pfctl -f /etc/pf.conf || { arm_failed pf_reload; return 1; }
    # pfctl -f flushed the anchor rules the arm just loaded. A second arm
    # refills them. start() is idempotent, so the kernel keeps its port.
    socket_arm >/dev/null || { arm_failed anchor_refill; return 1; }
    arm_wait 20 socket_present_after_reload socket_present || return 1
    arm_wait 20 resolver_present_after_reload resolver_present || return 1
  fi
  arm_wait 15 anchor_has_fixture anchor_has_fixture || return 1
  arm_wait 15 guard_answers guard_answers || return 1
  if ! kernel_by_script; then
    # The kernel the helper started: running, with a utun its control API
    # reports. Its pid lands in the file the kill rows use. Resolver files
    # then name the kernel DNS port; until the carrier is up they name the
    # guard port, and a suffix is never left without a file.
    arm_wait 30 helper_kernel_up helper_kernel_up || return 1
    # The helper POSTs /v1/connect; state becomes connected only after the
    # carrier to the relay accepts. DNS stays on the guard until then.
    arm_wait 30 kernel_posture_connected kernel_posture_connected || return 1
    arm_wait 20 resolver_kernel_port resolver_kernel_port || return 1
  else
    arm_wait 15 resolver_guard_port resolver_guard_port || return 1
  fi
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
  /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

clear_for_boot() {
  note "clear intent does not delete leftover files on launch. The harness removes them, then starts the helper and checks it does not put them back."
  if dry; then
    priv /bin/launchctl bootout system "$HELPER_PLIST"
    write_intent false none 2
    priv /bin/rm -f "$RESOLVER_FILE"
    priv /sbin/pfctl -a "$ANCHOR" -F all
    priv /bin/launchctl bootstrap system "$HELPER_PLIST"
    return 0
  fi
  /bin/launchctl bootout system "$HELPER_PLIST" >/dev/null 2>&1 || true
  write_intent false none 2 || return 1
  /bin/rm -f "$RESOLVER_FILE"
  /sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
  /bin/launchctl bootstrap system "$HELPER_PLIST" || return 1
  sleep 2
  if resolver_present || anchor_has_fixture; then
    return 1
  fi
}

start_bg() {
  local pidfile="$1"
  shift
  if dry; then
    plan "$@"
    return 0
  fi
  mkdir -p "${WORK}/logs"
  nohup "$@" >>"${WORK}/logs/$(basename "$pidfile").log" 2>&1 &
  echo $! > "$pidfile"
}

kill_pidfile() {
  local file="$1" expect="$2" pid cmd comm i
  [[ -f "$file" ]] || return 0
  pid=$(cat "$file" 2>/dev/null || true)
  case "$pid" in
    ""|*[!0-9]*) rm -f "$file"; return 0 ;;
  esac
  # `command` is truncated to the terminal width and can hide the binary
  # name. `comm` is the short name (`segue-kernel`), which is what we match.
  cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
  comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
  case "$cmd $comm" in
    *"$expect"*)
      # SIGTERM lets segue-kernel run tun.shutdown (drop the utun fd).
      # SIGKILL at 300ms skipped that and left utun4 up on the Satellite.
      kill -TERM "$pid" 2>/dev/null || true
      i=0
      while [[ "$i" -lt 20 ]]; do
        if ! ps -p "$pid" >/dev/null 2>&1; then
          break
        fi
        sleep 0.25
        i=$((i + 1))
      done
      if ps -p "$pid" >/dev/null 2>&1; then
        kill -KILL "$pid" 2>/dev/null || true
        sleep 0.5
      fi
      ;;
  esac
  rm -f "$file"
}

write_server_config() {
  mkdir -p "${WORK}/state"
  cat > "${WORK}/state/fixture-server.json" <<EOF
{
  "inbounds": [
    {
      "tag": "socks-in",
      "protocol": "socks",
      "listen": "127.0.0.1",
      "port": ${SOCKS_PORT},
      "settings": {"auth": "noauth", "udp": false}
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"}
  ]
}
EOF
}

# Signed policy, synthetic Ed25519 ticket, kernel.json and relay.json.
# Keys stay under ${WORK}/state (mode 0600) and are never copied into the repo.
# The AI route is the segue session to the relay (exit_class ai). The relay
# classifies that suffix as AI and dials it through the loopback Home line,
# whose outbound is freedom, so the lo0 alias is reached with no further proxy.
sign_bundle() {
  local key="${WORK}/state/policy.key"
  local body="${WORK}/state/policy-body.json"
  local relay_key="${WORK}/state/relay.key"
  local ticket="${WORK}/state/device.ticket"
  local pub relay_pub ticket_text
  mkdir -p "${WORK}/state"
  cat > "$body" <<EOF
{"version":1,"expires_at":4000000000,"ai_domains":["${FIXTURE_SUFFIX}"],"ai_cidrs":["${FIXTURE_CIDR}"],"default":{"type":"direct"}}
EOF
  if dry; then
    plan "${KERNEL_DST}" policy-keygen "$key"
    plan "${KERNEL_DST}" sign-bundle --key "$key" --key-id 1 "$body"
    priv /bin/cp "${WORK}/state/policy.bundle" "${SUPPORT}/policy.bundle"
    plan "${RELAY_DST}" keygen "$relay_key"
    plan "${RELAY_DST}" issue-ticket --key "$relay_key" --key-id 1 --device 7 --classes ai,overseas --ttl 86400
    note "synthetic Ed25519 ticket and key are written under ${WORK}/state at run time (mode 0600) and are not committed"
    note "kernel.json: AI route is segue tag ai (exit_class ai, role home) via exit lab, carrier direct, relay ${RELAY_DIAL_HOST}:${RELAY_PORT} (exit-via ${EXIT_VIA}); tun ipv6 is false; dns.listen is 127.0.0.1:${KERNEL_DNS_PORT}; domestic resolver is 192.0.2.53 (TEST-NET, not a real server)"
    note "relay.json: listen 127.0.0.1:${RELAY_PORT}, node_id 1, metrics 127.0.0.1:${RELAY_METRICS_PORT}, ticket key from keygen, same policy bundle, home line 127.0.0.1:${SOCKS_PORT}, dev_allow_cidrs ${FIXTURE_HOST}/32"
    return 0
  fi
  rm -f "$key" "$relay_key"
  pub=$("${KERNEL_DST}" policy-keygen "$key") || return 1
  pub=$(printf '%s' "$pub" | tr -d '[:space:]')
  printf '%s\n' "$pub" > "${WORK}/state/policy.pub"
  "${KERNEL_DST}" sign-bundle --key "$key" --key-id 1 "$body" > "${WORK}/state/policy.bundle" || return 1
  priv /bin/cp "${WORK}/state/policy.bundle" "${SUPPORT}/policy.bundle" || return 1
  priv /bin/chmod 644 "${SUPPORT}/policy.bundle" || return 1
  relay_pub=$("${RELAY_DST}" keygen "$relay_key") || return 1
  relay_pub=$(printf '%s' "$relay_pub" | tr -d '[:space:]')
  ticket_text=$("${RELAY_DST}" issue-ticket --key "$relay_key" --key-id 1 --device 7 --classes ai,overseas --ttl 86400) || return 1
  printf '%s\n' "$ticket_text" > "$ticket"
  chmod 600 "$ticket" "$relay_key" "$key" || return 1
  cat > "${WORK}/state/relay.json" <<EOF
{
  "listen": "127.0.0.1:${RELAY_PORT}",
  "node_id": 1,
  "metrics_listen": "127.0.0.1:${RELAY_METRICS_PORT}",
  "ticket_keys": [{"key_id": 1, "public_key": "${relay_pub}"}],
  "policy": {
    "public_keys": [{"key_id": 1, "public_key": "${pub}"}],
    "bundle": "${WORK}/state/policy.bundle"
  },
  "home_lines": [
    {"id": "lab", "server": "127.0.0.1:${SOCKS_PORT}", "isp": "lab"}
  ],
  "dev_allow_cidrs": ["${FIXTURE_HOST}/32"]
}
EOF
  cat > "${WORK}/state/kernel.json" <<EOF
{
  "listen": "127.0.0.1:${KERNEL_SOCKS_PORT}",
  "outbounds": {
    "direct": {"protocol": "freedom"}
  },
  "policy": {
    "public_keys": [{"key_id": 1, "public_key": "${pub}"}],
    "bundle": "policy.bundle",
    "installed": "policy.installed",
    "ai_route": "ai"
  },
  "exits": [
    {"name": "lab", "carrier": "direct", "relay": "${RELAY_DIAL_HOST}:${RELAY_PORT}", "node_id": 1}
  ],
  "segue": {
    "ai": {"ticket_file": "${ticket}", "exit_class": "ai", "role": "home"}
  },
  "control": {
    "listen": "127.0.0.1:0",
    "token_file": "control.json"
  },
  "dns": {
    "listen": "127.0.0.1:${KERNEL_DNS_PORT}",
    "domestic": ["192.0.2.53:53"],
    "fake_ip_state": "fakeip.state"
  },
  "tun": {"ipv6": false},
  "sniff": {"timeout_ms": 300, "max_bytes": 16384}
}
EOF
  # dns.listen is 127.0.0.1:15353. While the carrier is connected the helper
  # writes /etc/resolver/<suffix> with nameserver 127.0.0.1 and this port;
  # otherwise the same file names the guard port.
  if kernel_by_script; then
    note "kernel-by-script: kernel.json stays in ${WORK}/state; the helper own start settles config_rejected and leaves the script kernel alone."
    return 0
  fi
  priv /bin/cp "${WORK}/state/kernel.json" "${SUPPORT}/kernel.json" || return 1
}

install_carrier_alias() {
  local iface
  iface=$(/sbin/route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2; exit}')
  if [[ -z "$iface" ]]; then
    if dry; then
      iface="<physical-iface>"
    else
      echo "no physical interface (route -n get 1.1.1.1)" >&2
      return 1
    fi
  fi
  CARRIER_IFACE="$iface"
  if ! dry; then
    printf '%s\n' "$iface" > "${WORK}/state/carrier.iface"
  fi
  note "alias ${CARRIER_HOST}/32 on ${iface}: the kernel binds carrier sockets to the physical NIC, which cannot connect to 127.0.0.1. The on-link host route makes the probe treat ${CARRIER_HOST} as local on that NIC."
  if dry; then
    priv /sbin/ifconfig "$iface" alias "$CARRIER_HOST" netmask 255.255.255.255
    priv /sbin/route -n delete -host "$CARRIER_HOST"
    priv /sbin/route -n add -host "$CARRIER_HOST" -interface "$iface"
    plan /sbin/route -n get "$CARRIER_HOST"
    return 0
  fi
  if ! /sbin/ifconfig "$iface" | grep -F "$CARRIER_HOST" >/dev/null 2>&1; then
    /sbin/ifconfig "$iface" alias "$CARRIER_HOST" netmask 255.255.255.255 || return 1
  fi
  /sbin/route -n delete -host "$CARRIER_HOST" >/dev/null 2>&1 || true
  if ! /sbin/route -n add -host "$CARRIER_HOST" -interface "$iface"; then
    # The alias's connected route may already be the on-link host route.
    if ! /sbin/route -n get "$CARRIER_HOST" 2>/dev/null | grep -q "interface: ${iface}"; then
      echo "could not install an on-link route for ${CARRIER_HOST} on ${iface}" >&2
      return 1
    fi
  fi
  /sbin/route -n get "$CARRIER_HOST" > "${WORK}/state/carrier.route" 2>&1 || true
}

remove_carrier_alias() {
  local iface="${CARRIER_IFACE:-}"
  if [[ -z "$iface" && -f "${WORK}/state/carrier.iface" ]]; then
    iface=$(cat "${WORK}/state/carrier.iface" 2>/dev/null || true)
  fi
  /sbin/route -n delete -host "$CARRIER_HOST" >/dev/null 2>&1 || true
  if [[ -n "$iface" && "$iface" != "<physical-iface>" ]]; then
    /sbin/ifconfig "$iface" -alias "$CARRIER_HOST" >/dev/null 2>&1 || true
  fi
}

hosts_install() {
  local line="${FIXTURE_HOST} www.${FIXTURE_SUFFIX} # segue-vm-matrix"
  if dry; then
    note "hosts line so segue-relay resolves www.${FIXTURE_SUFFIX} to ${FIXTURE_HOST}; dig does not read /etc/hosts, so fake-IP checks stay on the kernel resolver"
    priv /bin/sh -c "printf '%s\n' '${line}' >> /etc/hosts"
    return 0
  fi
  if /usr/bin/grep -q 'segue-vm-matrix' /etc/hosts 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$line" >> /etc/hosts || return 1
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
  /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

hosts_remove() {
  local tmp="${WORK}/state/hosts.stripped"
  if dry; then
    note "remove the segue-vm-matrix line from /etc/hosts"
    priv /usr/bin/grep -v segue-vm-matrix /etc/hosts
    return 0
  fi
  if ! /usr/bin/grep -q 'segue-vm-matrix' /etc/hosts 2>/dev/null; then
    return 0
  fi
  /usr/bin/grep -v 'segue-vm-matrix' /etc/hosts > "$tmp" || return 0
  /bin/cp "$tmp" /etc/hosts || true
  /bin/rm -f "$tmp"
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
  /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

wait_listen() {
  local host="$1" port="$2" pidfile="$3" label="$4"
  local i=0 pid
  if dry; then
    plan /usr/bin/python3 "$PROBES" tcp "$host" "$port" 1
    return 0
  fi
  pid=$(cat "$pidfile" 2>/dev/null || true)
  while [[ "$i" -lt 40 ]]; do
    if /usr/bin/python3 "$PROBES" tcp "$host" "$port" 0.3 >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "$pid" ]] && ! ps -p "$pid" >/dev/null 2>&1; then
      echo "${label} exited before listening on ${host}:${port}" >&2
      log_tail "${WORK}/logs/$(basename "$pidfile").log" >&2
      return 1
    fi
    sleep 0.25
    i=$((i + 1))
  done
  echo "${label} did not listen on ${host}:${port}" >&2
  log_tail "${WORK}/logs/$(basename "$pidfile").log" >&2
  return 1
}

# Relay, Home line, carrier alias and forwarder (exit-via alias only),
# signed bundle, kernel.json, lo0 alias and the AI fixture host. Runs
# before arm so the helper finds a complete config the moment it starts
# the kernel.
prepare_kernel_stack() {
  write_server_config
  if exit_via_alias; then
    install_carrier_alias || return 1
  else
    note "exit-via loopback: no carrier alias on the physical NIC and no forwarder; the kernel's exit is the relay on 127.0.0.1:${RELAY_PORT}."
  fi
  if dry; then
    sign_bundle || return 1
    hosts_install || return 1
    plan "${SEGUE_DST}" run -config "${WORK}/state/fixture-server.json"
    plan "${RELAY_DST}" run "${WORK}/state/relay.json"
    if exit_via_alias; then
      plan /usr/bin/python3 "$PROBES" forward "$CARRIER_HOST" "$RELAY_PORT" 127.0.0.1 "$RELAY_PORT"
    fi
    priv /sbin/ifconfig lo0 alias "${FIXTURE_HOST}" netmask 255.255.255.0
    plan /usr/bin/python3 "$PROBES" serve "${FIXTURE_HOST}" "$FIXTURE_TCP_PORT" ai-host
    return 0
  fi
  sign_bundle || return 1
  hosts_install || return 1
  start_bg "${WORK}/state/fixture.pid" "${SEGUE_DST}" run -config "${WORK}/state/fixture-server.json" || return 1
  wait_listen 127.0.0.1 "$SOCKS_PORT" "${WORK}/state/fixture.pid" "home socks" || return 1
  start_bg "${WORK}/state/relay.pid" "${RELAY_DST}" run "${WORK}/state/relay.json" || return 1
  wait_listen 127.0.0.1 "$RELAY_PORT" "${WORK}/state/relay.pid" "segue-relay" || return 1
  if exit_via_alias; then
    start_bg "${WORK}/state/carrier.pid" /usr/bin/python3 "$PROBES" forward "$CARRIER_HOST" "$RELAY_PORT" 127.0.0.1 "$RELAY_PORT" || return 1
    wait_listen "$CARRIER_HOST" "$RELAY_PORT" "${WORK}/state/carrier.pid" "carrier" || return 1
  fi
  if ! /sbin/ifconfig lo0 | grep -q '198\.51\.100\.10'; then
    /sbin/ifconfig lo0 alias "${FIXTURE_HOST}" netmask 255.255.255.0 || return 1
  fi
  start_bg "${WORK}/state/ai-host.pid" /usr/bin/python3 "$PROBES" serve "${FIXTURE_HOST}" "$FIXTURE_TCP_PORT" ai-host || return 1
  UTUN_BEFORE=" $(utun_list) "
}

# The debug fallback (--kernel-by-script): this script execs the kernel
# with the config in ${WORK}/state. No kernel.json is installed at
# ${SUPPORT}, so the helper does not spawn a rival for these ports.
start_kernel_process() {
  if dry; then
    plan "${KERNEL_DST}" run --state-dir "${SUPPORT}/kernel" --log "${WORK}/logs/kernel.log" "${WORK}/state/kernel.json"
    return 0
  fi
  mkdir -p "${WORK}/logs"
  nohup "${KERNEL_DST}" run --state-dir "${SUPPORT}/kernel" --log "${WORK}/logs/kernel.log" "${WORK}/state/kernel.json" >>"${WORK}/logs/kernel.stdout" 2>&1 &
  echo $! > "${WORK}/state/kernel.pid"
  wait_until 20 saw_new_utun || return 1
  wait_until 15 kernel_dns_up || return 1
}

start_kernel_stack() {
  prepare_kernel_stack || return 1
  start_kernel_process
}

# status_read through the helper socket, parsed into key=value lines the
# rows can kv out of. Empty output means the helper did not answer.
helper_kernel_status() {
  local payload='{"version":1,"kind":"status_read"}'
  /usr/bin/python3 "$PROBES" helper /var/run/segue/service.sock "$payload" 2>/dev/null     | /usr/bin/python3 -c '
import json, sys
try:
    obj = json.loads(sys.stdin.read().strip())
except Exception:
    sys.exit(0)
body = obj.get("status") or {}
kernel = body.get("kernel") or {}
err = obj.get("error") or {}
print("kind=%s" % obj.get("kind", ""))
print("kernel_state=%s" % kernel.get("state", "missing"))
print("kernel_pid=%s" % (kernel.get("pid") or ""))
print("kernel_last_exit=%s" % (kernel.get("last_exit") or ""))
stderr_tail = kernel.get("last_stderr") or ""
print("kernel_last_stderr=%s" % stderr_tail.replace("\n", "\\n")[:512])
print("tun=%s" % (body.get("tun_interface") or ""))
print("armed=%s" % body.get("armed"))
print("dns_mode=%s" % (body.get("dns_mode") or ""))
print("ai_layer=%s" % (body.get("ai_layer") or ""))
print("resolver_files=%s" % body.get("resolver_files"))
if isinstance(err, dict) and err.get("code"):
    print("error=%s" % err.get("code"))
    print("error_message=%s" % err.get("message", ""))
'
}

# The helper started the kernel and its control API reports a utun. The
# pid is recorded where the kill rows and cleanup already look for it.
# (kv answers 0 for a missing key, so the fields are matched explicitly.)
helper_kernel_up() {
  local parsed pid tun
  parsed=$(helper_kernel_status)
  printf '%s\n' "$parsed" | grep -q '^kernel_state=running$' || return 1
  pid=$(printf '%s\n' "$parsed" | sed -n 's/^kernel_pid=//p')
  tun=$(printf '%s\n' "$parsed" | sed -n 's/^tun=//p')
  case "$pid" in
    ''|0|*[!0-9]*) return 1 ;;
  esac
  case "$tun" in
    utun*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$pid" > "${WORK}/state/kernel.pid"
  printf '%s\n' "$tun" > "${WORK}/state/utun.name"
}

# Full GET /v1/status body (or an error line). The token stays in control.json.
kernel_status_text() {
  /usr/bin/python3 "$PROBES" kernel-status "${SUPPORT}/kernel/control.json" 2>&1 || true
}

# True when the session dialer's coarse state is connected.
kernel_posture_connected() {
  local body
  body=$(/usr/bin/python3 "$PROBES" kernel-status "${SUPPORT}/kernel/control.json" 2>/dev/null) || return 1
  printf '%s\n' "$body" | /usr/bin/python3 -c 'import json,sys
try:
    doc = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if doc.get("state") == "connected" else 1)'
}

saw_new_utun() {
  local now name
  now=$(utun_list)
  for name in $now; do
    case "$UTUN_BEFORE" in
      *" $name "*) ;;
      *)
        printf '%s\n' "$name" > "${WORK}/state/utun.name"
        return 0
        ;;
    esac
  done
  return 1
}

kernel_dns_up() {
  local out
  out=$(/usr/bin/python3 "$PROBES" dns 127.0.0.1 "$KERNEL_DNS_PORT" "www.${FIXTURE_SUFFIX}" 2>&1 || true)
  printf '%s\n' "$out" | grep -Eq 'rcode=[0-9]'
}

cidr_drop_probe() {
  local before after route tcp bp ap be ae
  if dry; then
    priv /sbin/ifconfig lo0 -alias "$FIXTURE_HOST"
    plan /sbin/route -n get "$FIXTURE_HOST"
    priv /sbin/pfctl -a "$ANCHOR" -sr -v
    plan /usr/bin/python3 "$PROBES" tcp "$FIXTURE_HOST" "$FIXTURE_TCP_PORT" 1.5
    return 0
  fi
  kill_pidfile "${WORK}/state/ai-host.pid" probes.py
  /sbin/ifconfig lo0 -alias "$FIXTURE_HOST" >/dev/null 2>&1 || true
  route=$(/sbin/route -n get "$FIXTURE_HOST" 2>&1 || true)
  before=$(/sbin/pfctl -a "$ANCHOR" -sr -v 2>&1 || true)
  tcp=$(/usr/bin/python3 "$PROBES" tcp "$FIXTURE_HOST" "$FIXTURE_TCP_PORT" 1.5 2>&1 || true)
  after=$(/sbin/pfctl -a "$ANCHOR" -sr -v 2>&1 || true)
  bp=$(num "$(kv packets "$(printf '%s\n' "$before" | /usr/bin/python3 "$PROBES" counter)")")
  ap=$(num "$(kv packets "$(printf '%s\n' "$after" | /usr/bin/python3 "$PROBES" counter)")")
  be=$(num "$(kv evaluations "$(printf '%s\n' "$before" | /usr/bin/python3 "$PROBES" counter)")")
  ae=$(num "$(kv evaluations "$(printf '%s\n' "$after" | /usr/bin/python3 "$PROBES" counter)")")
  CIDR_EVIDENCE="route:
${route}
tcp: ${tcp}
packets ${bp} -> ${ap}
evaluations ${be} -> ${ae}"
  if printf '%s\n' "$route" | grep -q 'interface: lo0'; then
    return 1
  fi
  if printf '%s\n' "$tcp" | grep -q 'connect=ok'; then
    return 1
  fi
  if [[ "$ap" -gt "$bp" || "$ae" -gt "$be" ]]; then
    return 0
  fi
  return 1
}

row_armed() {
  local name=armed-kernel-not-running
  if dry; then
    plan /usr/bin/pgrep -x segue-kernel
    plan grep -qx "nameserver 127.0.0.1" "$RESOLVER_FILE"
    plan grep -qx "port ${GUARD_PORT}" "$RESOLVER_FILE"
    plan /usr/bin/dig +time=2 +tries=1 "www.${FIXTURE_SUFFIX}" A
    plan /usr/bin/dig +time=2 +tries=1 @127.0.0.1 -p "$GUARD_PORT" "www.${FIXTURE_SUFFIX}" A
    plan /usr/bin/dig +time=2 +tries=1 example.com A
    plan /usr/bin/python3 "$PROBES" dns 127.0.0.1 "$GUARD_PORT" "www.${FIXTURE_SUFFIX}"
    plan /usr/bin/python3 "$PROBES" tcp 127.0.0.1 "$LOOPBACK_PORT" 2
    cidr_drop_probe || true
    note "this row runs after kill-kernel: the SIGTERM was a clean shutdown, so the supervisor does not restart it, and the helper replaced the resolver file in place with the guard port"
    record "$name" DRY-RUN "armed, kernel not running: no segue-kernel process; resolver file nameserver 127.0.0.1 port ${GUARD_PORT}; system dig of www.${FIXTURE_SUFFIX} is empty NOERROR from 127.0.0.1; dig @127.0.0.1 -p ${GUARD_PORT} is empty NOERROR; dig example.com is a real answer; TCP to ${FIXTURE_CIDR} is dropped; TCP to 127.0.0.1 works"
    return 0
  fi
  local dig_ai dig_ex guard loop rules leak guard_dig
  dig_ai=$(dig_query "www.${FIXTURE_SUFFIX}")
  guard_dig=$(dig_at_guard "www.${FIXTURE_SUFFIX}")
  dig_ex=$(dig_query example.com)
  guard=$(/usr/bin/python3 "$PROBES" dns 127.0.0.1 "$GUARD_PORT" "www.${FIXTURE_SUFFIX}" 2>&1 || true)
  loop=$(/usr/bin/python3 "$PROBES" tcp 127.0.0.1 "$LOOPBACK_PORT" 2 2>&1 || true)
  rules=$(/sbin/pfctl -a "$ANCHOR" -sr 2>&1 || true)
  leak=$(printf '%s\n' "$rules" | /usr/bin/python3 "$PROBES" leak-rules || true)
  CIDR_EVIDENCE=""
  local dropped=0
  if cidr_drop_probe; then
    dropped=1
  fi
  local ok=1 why=""
  if ! resolver_guard_port; then
    ok=0
    why="${why} resolver file is not nameserver 127.0.0.1 port ${GUARD_PORT}."
  fi
  if ! dig_held_by_guard "$dig_ai"; then
    ok=0
    why="${why} armed dig was not empty NOERROR from 127.0.0.1."
  fi
  if ! dig_empty_noerror "$guard_dig"; then
    ok=0
    why="${why} dig @127.0.0.1 -p ${GUARD_PORT} was not empty NOERROR."
  fi
  if ! printf '%s\n' "$guard" | grep -q 'rcode=0 ancount=0'; then
    ok=0
    why="${why} guard DNS was not rcode=0 ancount=0."
  fi
  if ! dig_has_answer "$dig_ex"; then
    ok=0
    why="${why} example.com had no answer."
  fi
  if ! printf '%s\n' "$loop" | grep -q 'connect=ok'; then
    ok=0
    why="${why} non-AI loopback TCP failed."
  fi
  if [[ "$dropped" != 1 ]]; then
    ok=0
    why="${why} fixture CIDR was not dropped."
  fi
  if ! printf '%s\n' "$leak" | grep -q 'ok=yes'; then
    ok=0
    why="${why} anchor rules are not the narrow fixture block."
  fi
  if pgrep -x segue-kernel >/dev/null 2>&1; then
    ok=0
    why="${why} a segue-kernel process is still running."
  fi
  local evidence socket_reply
  socket_reply=$(cat "${WORK}/state/socket-arm.txt" 2>/dev/null || true)
  evidence="why:${why}
socket:${socket_reply}
guard:${guard}
--- dig @127.0.0.1 guard ---
${guard_dig}
loop:${loop}
leak:${leak}
${CIDR_EVIDENCE}
--- armed dig ---
${dig_ai}
--- example.com ---
${dig_ex}
--- rules ---
${rules}"
  if [[ "$ok" == 1 ]]; then
    record "$name" PASS "$evidence"
  else
    record "$name" FAIL "$evidence"
  fi
}

row_connected() {
  local name=connected
  if dry; then
    plan grep -qx "nameserver 127.0.0.1" "$RESOLVER_FILE"
    plan grep -qx "port ${KERNEL_DNS_PORT}" "$RESOLVER_FILE"
    plan /usr/bin/dig +time=2 +tries=1 "www.${FIXTURE_SUFFIX}" A
    plan /usr/bin/dig +time=2 +tries=1 @127.0.0.1 -p "$KERNEL_DNS_PORT" "www.${FIXTURE_SUFFIX}" A
    plan /usr/bin/python3 "$PROBES" dns 127.0.0.1 "$KERNEL_DNS_PORT" "www.${FIXTURE_SUFFIX}"
    plan /usr/bin/python3 "$PROBES" egress 198.18.0.1 "$FIXTURE_TCP_PORT" "$RELAY_METRICS_PORT" "$UNLISTED_HOST" "$UNLISTED_PORT" "$LOOPBACK_PORT"
    plan /usr/bin/python3 "$PROBES" relay-metrics "$RELAY_METRICS_PORT"
    record "$name" DRY-RUN "the kernel arm started is up: resolver file is nameserver 127.0.0.1 port ${KERNEL_DNS_PORT}; system dig of www.${FIXTURE_SUFFIX} is a 198.18.0.0/15 fake-IP; dig @127.0.0.1 -p ${KERNEL_DNS_PORT} is the same fake-IP; a TCP connection to that address increments segue_relay_connects_home; a non-AI address does not increment connects_home or connects_overseas; loopback still connects."
    return 0
  fi
  if [[ ! -f "${WORK}/state/kernel.pid" ]] || ! pgrep -x segue-kernel >/dev/null 2>&1; then
    record "$name" FAIL "the kernel arm started is not running
$(helper_kernel_status)
$(log_tail "${WORK}/logs/kernel.log")
$(log_tail "${WORK}/logs/kernel.stdout")
$(log_tail "${WORK}/logs/fixture.pid.log")
$(log_tail "${WORK}/logs/relay.pid.log")"
    return 0
  fi
  local dns ip egress utun sys_dig kern_dig
  dns=$(/usr/bin/python3 "$PROBES" dns 127.0.0.1 "$KERNEL_DNS_PORT" "www.${FIXTURE_SUFFIX}" 2>&1 || true)
  sys_dig=$(dig_query "www.${FIXTURE_SUFFIX}")
  kern_dig=$(/usr/bin/dig +time=2 +tries=1 @127.0.0.1 -p "$KERNEL_DNS_PORT" "www.${FIXTURE_SUFFIX}" A 2>&1 || true)
  ip="${dns#*answers=}"
  ip="${ip%%,*}"
  utun=$(cat "${WORK}/state/utun.name" 2>/dev/null || true)
  if ! printf '%s\n' "$ip" | grep -Eq '^198\.1[89]\.'; then
    record "$name" FAIL "fake-IP missing (${dns}) utun=${utun}
$(log_tail "${WORK}/logs/kernel.log")"
    return 0
  fi
  if ! resolver_kernel_port || ! dig_fake_ip "$sys_dig" || ! dig_fake_ip "$kern_dig"; then
    record "$name" FAIL "resolver file or system dig was not a kernel fake-IP utun=${utun}
resolver:
$(cat "$RESOLVER_FILE" 2>&1 || true)
--- system dig ---
${sys_dig}
--- dig @127.0.0.1 -p ${KERNEL_DNS_PORT} ---
${kern_dig}
dns:${dns}"
    return 0
  fi
  egress=$(/usr/bin/python3 "$PROBES" egress "$ip" "$FIXTURE_TCP_PORT" "$RELAY_METRICS_PORT" "$UNLISTED_HOST" "$UNLISTED_PORT" "$LOOPBACK_PORT" 2>&1 || true)
  local evidence="utun=${utun}
dns:${dns}
egress:
${egress}
$(log_tail "${WORK}/logs/kernel.log")
$(log_tail "${WORK}/logs/relay.pid.log")"
  # Match whole lines. A missing key must not look like a zero delta.
  if printf '%s\n' "$egress" | grep -qx 'ai_connect=ok' \
    && printf '%s\n' "$egress" | grep -Eq '^ai_home_delta=[1-9][0-9]*$' \
    && printf '%s\n' "$egress" | grep -qx 'other_home_delta=0' \
    && printf '%s\n' "$egress" | grep -qx 'other_overseas_delta=0' \
    && printf '%s\n' "$egress" | grep -qx 'loopback=ok'; then
    record "$name" PASS "$evidence"
  else
    record "$name" FAIL "$evidence"
  fi
}

row_kill_kernel() {
  local name=kill-kernel
  if dry; then
    priv /bin/kill -TERM '<kernel-pid>'
    plan /sbin/ifconfig -l
    plan grep -qx "port ${GUARD_PORT}" "$RESOLVER_FILE"
    plan /usr/bin/dig +time=2 +tries=1 "www.${FIXTURE_SUFFIX}" A
    plan /usr/bin/dig +time=2 +tries=1 @127.0.0.1 -p "$GUARD_PORT" "www.${FIXTURE_SUFFIX}" A
    plan /usr/bin/dig +time=2 +tries=1 example.com A
    cidr_drop_probe || true
    record "$name" DRY-RUN "after SIGTERM to segue-kernel only, waiting for it to exit before SIGKILL: a SIGTERM is a clean shutdown (exit 0), so the supervisor does not restart it and replaces the resolver file in place with port ${GUARD_PORT} (no gap without a file); its utun is gone and the pid is dead; armed name is still empty NOERROR from 127.0.0.1; dig @127.0.0.1 -p ${GUARD_PORT} is empty NOERROR; example.com still answers; fixture CIDR still dropped; non-AI loopback still connects"
    return 0
  fi
  if [[ ! -f "${WORK}/state/kernel.pid" ]]; then
    record "$name" SKIP "kernel was not started"
    return 0
  fi
  local pid utun dig_ai dig_ex loop dropped=0 dead=no guard_dig
  pid=$(cat "${WORK}/state/kernel.pid")
  utun=$(cat "${WORK}/state/utun.name" 2>/dev/null || true)
  kill_pidfile "${WORK}/state/kernel.pid" segue-kernel
  if ! ps -p "$pid" >/dev/null 2>&1; then
    dead=yes
  fi
  sleep 1
  dig_ai=$(dig_query "www.${FIXTURE_SUFFIX}")
  guard_dig=$(dig_at_guard "www.${FIXTURE_SUFFIX}")
  dig_ex=$(dig_query example.com)
  loop=$(/usr/bin/python3 "$PROBES" tcp 127.0.0.1 "$LOOPBACK_PORT" 2 2>&1 || true)
  if cidr_drop_probe; then
    dropped=1
  fi
  local still=""
  if [[ -n "$utun" ]]; then
    case " $(utun_list) " in
      *" $utun "*) still="yes" ;;
      *) still="no" ;;
    esac
  else
    still="unknown"
  fi
  local ok=1 why=""
  if [[ "$dead" != "yes" ]]; then
    ok=0
    why="${why} segue-kernel pid ${pid} still alive."
  fi
  if [[ "$still" != "no" ]]; then
    ok=0
    why="${why} utun ${utun} still present (${still})."
  fi
  if ! resolver_guard_port; then
    ok=0
    why="${why} resolver file is not nameserver 127.0.0.1 port ${GUARD_PORT}."
  fi
  if ! dig_held_by_guard "$dig_ai"; then
    ok=0
    why="${why} armed name was not empty NOERROR from 127.0.0.1."
  fi
  if ! dig_empty_noerror "$guard_dig"; then
    ok=0
    why="${why} dig @127.0.0.1 -p ${GUARD_PORT} was not empty NOERROR."
  fi
  if ! dig_has_answer "$dig_ex"; then
    ok=0
    why="${why} example.com had no answer."
  fi
  if ! printf '%s\n' "$loop" | grep -q 'connect=ok'; then
    ok=0
    why="${why} non-AI TCP failed."
  fi
  if [[ "$dropped" != 1 ]]; then
    ok=0
    why="${why} fixture CIDR was not dropped."
  fi
  local evidence="why:${why}
pid=${pid} dead=${dead} utun=${utun} gone=${still}
loop:${loop}
${CIDR_EVIDENCE}
--- armed dig ---
${dig_ai}
--- dig @127.0.0.1 guard ---
${guard_dig}
--- example.com ---
${dig_ex}"
  if [[ "$ok" == 1 ]]; then
    record "$name" PASS "$evidence"
  else
    record "$name" FAIL "$evidence"
  fi
}

row_kill_helper() {
  local name=kill-helper
  if dry; then
    priv /bin/kill -9 '<helper-pid>'
    plan /usr/bin/dig +time=2 +tries=1 "www.${FIXTURE_SUFFIX}" A
    plan /usr/bin/dig +time=2 +tries=1 @127.0.0.1 -p "$GUARD_PORT" "www.${FIXTURE_SUFFIX}" A
    plan /usr/bin/dig +time=2 +tries=1 example.com A
    record "$name" DRY-RUN "SIGKILL the helper. launchd KeepAlive restarts it. During the gap the armed name times out or is empty NOERROR from 127.0.0.1 (an upstream NXDOMAIN or SOA is a leak). After the helper is back, system dig and dig @127.0.0.1 -p ${GUARD_PORT} are empty NOERROR from the guard. example.com still answers."
    return 0
  fi
  local pid before during during_ex after ex_after
  before=$(dig_query example.com)
  pid=$(helper_pid)
  if [[ -z "$pid" ]]; then
    record "$name" FAIL "helper is not running"
    return 0
  fi
  kill -9 "$pid" 2>/dev/null || true
  during=$(dig_query "www.${FIXTURE_SUFFIX}")
  during_ex=$(dig_query example.com)
  local restarted=0
  if wait_until 20 helper_running; then
    restarted=1
    # The process is back before the guard is. Do not score the restart
    # against the gap where the listener is still coming up.
    wait_until 15 guard_answers || true
    if ! kernel_by_script; then
      # The restarted helper re-armed the narrow layer and took the kernel
      # back over (the orphan's pid file named it) or started it fresh.
      wait_until 30 helper_kernel_up || true
    fi
  fi
  after=$(dig_query "www.${FIXTURE_SUFFIX}")
  ex_after=$(dig_query example.com)
  local ok=1 why=""
  if dig_has_answer "$during"; then
    ok=0
    why="${why} armed name answered during the gap."
  elif dig_held_by_guard "$during" || dig_timed_out "$during"; then
    :
  else
    ok=0
    why="${why} armed dig during the gap was neither empty NOERROR from 127.0.0.1 nor a timeout."
  fi
  if ! dig_has_answer "$before" || ! dig_has_answer "$during_ex" || ! dig_has_answer "$ex_after"; then
    ok=0
    why="${why} example.com failed before, during, or after the restart."
  fi
  if [[ "$restarted" != 1 ]]; then
    ok=0
    why="${why} helper did not restart."
  elif ! dig_held_by_guard "$after"; then
    ok=0
    why="${why} armed name was not empty NOERROR from 127.0.0.1 after the helper returned."
  fi
  local evidence="why:${why}
killed=${pid} restarted=$(helper_pid)
--- example.com before ---
${before}
--- armed during ---
${during}
--- example.com during ---
${during_ex}
--- armed after ---
${after}
--- example.com after ---
${ex_after}"
  if [[ "$ok" == 1 ]]; then
    record "$name" PASS "$evidence"
  else
    record "$name" FAIL "$evidence"
  fi
}

helper_running() {
  [[ -n "$(helper_pid)" ]]
}

release_socket_present() {
  [[ -S "$RELEASE_SOCK" ]]
}

marked_resolver_count() {
  local count=0 file first
  count=0
  if [[ -d /etc/resolver ]]; then
    for file in /etc/resolver/*; do
      [[ -f "$file" ]] || continue
      first=$(/usr/bin/head -n 1 "$file" 2>/dev/null || true)
      if [[ "$first" == "# managed by segue.ailock" ]]; then
        count=$((count + 1))
      fi
    done
  fi
  printf '%s\n' "$count"
}

intent_is_armed() {
  [[ -f "$INTENT" ]] || return 1
  /usr/bin/grep -Eq '"armed"[[:space:]]*:[[:space:]]*true' "$INTENT"
}

anchor_rules_present() {
  printf '%s\n' "$1" | /usr/bin/grep -Eq '^(pass|block|match|scrub|nat|rdr|anchor)[[:space:]]|198\.51\.100\.0/24'
}

write_release_plist() {
  mkdir -p "${WORK}/state" "${WORK}/logs"
  cat > "${WORK}/state/release.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.segue.release</string>
	<key>ProgramArguments</key>
	<array>
		<string>${RELEASE_DST}</string>
		<string>--allowed-uids</string>
		<string>${UID_DST}</string>
		<string>--requirement</string>
		<string>identifier "${RELEASE_CTL_ID}"</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${WORK}/logs/release.out</string>
	<key>StandardErrorPath</key>
	<string>${WORK}/logs/release.err</string>
</dict>
</plist>
EOF
}

row_restore() {
  local name=restore-via-release-daemon
  local built="${APP_SRC}/apps/macos/.build/release/segue-release"
  local built_ctl="${APP_SRC}/apps/macos/.build/release/segue-release-ctl"
  write_release_plist
  if dry; then
    note "SKIP when ${built} or ${built_ctl} is absent"
    priv /bin/cp "$built" "$RELEASE_DST"
    priv /bin/cp "$built_ctl" "$RELEASE_CTL_DST"
    priv /bin/chmod 755 "$RELEASE_DST" "$RELEASE_CTL_DST"
    priv /usr/bin/codesign -s - -f -i "$RELEASE_CTL_ID" "$RELEASE_CTL_DST"
    note "daemon --requirement is identifier \"${RELEASE_CTL_ID}\" so the ad-hoc ctl is admitted. Production plists omit --requirement."
    priv /bin/cp "${WORK}/state/release.plist" "$RELEASE_PLIST"
    priv /bin/launchctl bootout system "$RELEASE_PLIST"
    priv /bin/launchctl bootstrap system "$RELEASE_PLIST"
    priv /bin/kill -STOP '<helper-pid>'
    plan "$RELEASE_CTL_DST" restore --socket "$RELEASE_SOCK"
    priv /sbin/pfctl -a "$ANCHOR" -sr
    plan /bin/cat "$INTENT"
    plan /usr/bin/python3 "$PROBES" dns-match "${WORK}/state/dns.snapshot"
    note "read-back while the helper stays stopped: outcome=restored, anchor_loaded=false, anchor rules empty, no resolver file with the segue marker, DNS matches the pre-arm snapshot, intent not armed"
    priv /bin/kill -CONT '<helper-pid>'
    record "$name" DRY-RUN "SIGSTOP the helper, then segue-release-ctl restore (ReleaseClient's restore envelope) on ${RELEASE_SOCK}. PASS only when outcome=restored, anchor_loaded=false, no Segue resolver files remain, DNS matches the pre-arm snapshot, and intent is cleared."
    return 0
  fi
  if [[ ! -x "$built" || ! -x "$built_ctl" ]]; then
    record "$name" SKIP "need both ${built} and ${built_ctl}"
    return 0
  fi
  if ! /bin/cp "$built" "$RELEASE_DST"; then
    record "$name" FAIL "could not install ${RELEASE_DST}"
    return 0
  fi
  if ! /bin/cp "$built_ctl" "$RELEASE_CTL_DST"; then
    record "$name" FAIL "could not install ${RELEASE_CTL_DST}"
    return 0
  fi
  /bin/chmod 755 "$RELEASE_DST" "$RELEASE_CTL_DST" || true
  local sign_err
  sign_err=$(/usr/bin/codesign -s - -f -i "$RELEASE_CTL_ID" "$RELEASE_CTL_DST" 2>&1) || {
    record "$name" FAIL "codesign -s - -i ${RELEASE_CTL_ID} failed for ${RELEASE_CTL_DST}: ${sign_err}"
    return 0
  }
  /bin/cp "${WORK}/state/release.plist" "$RELEASE_PLIST" || {
    record "$name" FAIL "could not install ${RELEASE_PLIST}"
    return 0
  }
  /bin/chmod 644 "$RELEASE_PLIST" || true
  /bin/launchctl bootout system "$RELEASE_PLIST" >/dev/null 2>&1 || true
  local boot_err
  boot_err=$(/bin/launchctl bootstrap system "$RELEASE_PLIST" 2>&1) || {
    record "$name" FAIL "launchctl bootstrap of segue-release failed: ${boot_err}
$(log_tail "${WORK}/logs/release.err")"
    return 0
  }
  local paused=""
  paused=$(helper_pid)
  if [[ -n "$paused" ]]; then
    kill -STOP "$paused" 2>/dev/null || true
  fi
  local reply="" anchor_text="" dns_line="" marked="?" ok=1 why=""
  if ! wait_until 10 release_socket_present; then
    ok=0
    why="${why} release socket did not appear."
  else
    reply=$("$RELEASE_CTL_DST" restore --socket "$RELEASE_SOCK" 2>&1 || true)
    anchor_text=$(/sbin/pfctl -a "$ANCHOR" -sr 2>/dev/null || true)
    if [[ -f "${WORK}/state/dns.snapshot" ]]; then
      dns_line=$(/usr/bin/python3 "$PROBES" dns-match "${WORK}/state/dns.snapshot" 2>&1 || true)
    else
      dns_line="match=no
services=no-snapshot"
    fi
    marked=$(marked_resolver_count)
    if printf '%s\n' "$reply" | grep -q '^error='; then
      ok=0
      why="${why} release ctl failed."
    fi
    # Protocol success is `restored` (every step proved, machine reads back
    # clean). `partial` with anchor_loaded=true is a failed restore.
    if ! printf '%s\n' "$reply" | grep -q '^outcome=restored$'; then
      ok=0
      why="${why} outcome is not restored."
    fi
    if ! printf '%s\n' "$reply" | grep -q '^anchor_loaded=false$'; then
      ok=0
      why="${why} anchor_loaded is not false."
    fi
    if ! printf '%s\n' "$reply" | grep -q '^intent_cleared=true$'; then
      ok=0
      why="${why} report intent not cleared."
    fi
    if ! printf '%s\n' "$reply" | grep -q '^dns_mode=system$'; then
      ok=0
      why="${why} report dns_mode is not system."
    fi
    if ! printf '%s\n' "$reply" | grep -q '^resolver_files_remaining=$'; then
      ok=0
      why="${why} report still lists resolver files."
    fi
    if ! printf '%s\n' "$reply" | grep -q '^failures=$'; then
      ok=0
      why="${why} report has failures."
    fi
    if anchor_rules_present "$anchor_text"; then
      ok=0
      why="${why} anchor still has rules."
    fi
    if [[ "$marked" != "0" ]]; then
      ok=0
      why="${why} marked resolver files remain."
    fi
    if intent_is_armed; then
      ok=0
      why="${why} intent file still armed."
    fi
    if ! printf '%s\n' "$dns_line" | grep -q '^match=yes$'; then
      ok=0
      why="${why} DNS does not match the pre-arm snapshot."
    fi
  fi
  if [[ -n "$paused" ]]; then
    kill -CONT "$paused" 2>/dev/null || true
  fi
  local evidence="why:${why}
paused=${paused}
marked_resolvers=${marked}
dns:${dns_line}
--- ctl ---
${reply}
--- anchor rules ---
${anchor_text}
--- release.err ---
$(log_tail "${WORK}/logs/release.err")"
  if [[ "$ok" == 1 ]]; then
    record "$name" PASS "$evidence"
  else
    record "$name" FAIL "$evidence"
  fi
}

row_leak() {
  local name=expected-leak-doh-quic
  # Do not "fix" this leak. Hard-coded DoH/QUIC to an IP outside the fixture
  # CIDR must stay reachable. Blocking it here would make the row green by
  # claiming a lock the anchor does not have.
  if dry; then
    priv /sbin/ifconfig lo0 alias "$LEAK_HOST" netmask 255.255.255.255
    plan /usr/bin/python3 "$PROBES" serve "$LEAK_HOST" "$LEAK_PORT" leak-ok
    plan /usr/bin/python3 "$PROBES" udp-echo "$LEAK_HOST" "$LEAK_PORT"
    priv /sbin/pfctl -a "$ANCHOR" -sr
    plan /usr/bin/python3 "$PROBES" tcp "$LEAK_HOST" "$LEAK_PORT" 2
    plan /usr/bin/python3 "$PROBES" udp "$LEAK_HOST" "$LEAK_PORT" 1
    record "$name" DRY-RUN "Do not fix this leak. PASS when the anchor still blocks only ${FIXTURE_CIDR}, TCP to ${LEAK_HOST}:${LEAK_PORT} connects, and UDP round-trips. That address is a lo0 alias in a different TEST-NET (expected leak to an unlisted IP). A broader block, a failed connect, or a fixture-rule packet increase is FAIL."
    return 0
  fi
  if ! /sbin/ifconfig lo0 | grep -q '203\.0\.113\.10'; then
    if ! /sbin/ifconfig lo0 alias "$LEAK_HOST" netmask 255.255.255.255; then
      record "$name" FAIL "could not add lo0 alias ${LEAK_HOST}"
      return 0
    fi
  fi
  start_bg "${WORK}/state/leak-tcp.pid" /usr/bin/python3 "$PROBES" serve "$LEAK_HOST" "$LEAK_PORT" leak-ok
  start_bg "${WORK}/state/leak-udp.pid" /usr/bin/python3 "$PROBES" udp-echo "$LEAK_HOST" "$LEAK_PORT"
  sleep 0.3
  local rules verdict before after tcp udp bp ap be ae
  rules=$(/sbin/pfctl -a "$ANCHOR" -sr 2>&1 || true)
  verdict=$(printf '%s\n' "$rules" | /usr/bin/python3 "$PROBES" leak-rules || true)
  before=$(/sbin/pfctl -a "$ANCHOR" -sr -v 2>&1 || true)
  tcp=$(/usr/bin/python3 "$PROBES" tcp "$LEAK_HOST" "$LEAK_PORT" 2 2>&1 || true)
  udp=$(/usr/bin/python3 "$PROBES" udp "$LEAK_HOST" "$LEAK_PORT" 1 2>&1 || true)
  after=$(/sbin/pfctl -a "$ANCHOR" -sr -v 2>&1 || true)
  bp=$(num "$(kv packets "$(printf '%s\n' "$before" | /usr/bin/python3 "$PROBES" counter)")")
  ap=$(num "$(kv packets "$(printf '%s\n' "$after" | /usr/bin/python3 "$PROBES" counter)")")
  be=$(num "$(kv evaluations "$(printf '%s\n' "$before" | /usr/bin/python3 "$PROBES" counter)")")
  ae=$(num "$(kv evaluations "$(printf '%s\n' "$after" | /usr/bin/python3 "$PROBES" counter)")")
  local evidence="verdict:${verdict}
tcp:${tcp}
udp:${udp}
fixture-counter packets ${bp}->${ap} evaluations ${be}->${ae}
--- rules ---
${rules}"
  # Evaluations may move for unrelated packets. Packets on the fixture rule
  # must not: lo0 is passed before that rule, so this leak is not a drop.
  # Do not "fix" this leak.
  if printf '%s\n' "$verdict" | grep -q 'ok=yes' \
    && printf '%s\n' "$tcp" | grep -q 'connect=ok' \
    && printf '%s\n' "$udp" | grep -q 'recv=1' \
    && [[ "$ap" == "$bp" ]]; then
    record "$name" PASS "$evidence"
  else
    record "$name" FAIL "$evidence"
  fi
}

request_reboot() {
  cat <<EOF
REBOOT_REQUEST expect=${1}
The orchestrator should reboot this VM now. This script does not reboot.
Then, as root, with SEGUE_VM_MATRIX=throwaway:
  bash ${SCRIPT_PATH} --phase post-reboot --expect ${1} --work-dir ${WORK} --json ${WORK}/vm-ailock-matrix-post-reboot-${1}.json
Copy the JSON out before this volume is reused or destroyed.
EOF
}

run_pre() {
  prepare_tree || return 1
  # Snapshot before the helper can edit pf.conf or DNS.
  backup_pf || return 1
  save_dns || return 1
  enable_pf || return 1
  install_daemons || return 1
  if [[ "$EXPECT" == "armed" ]]; then
    arm_helper || return 1
  else
    clear_for_boot || return 1
  fi
  if dry; then
    request_reboot "$EXPECT"
    return 0
  fi
  if [[ "$EXPECT" == "armed" ]]; then
    if ! resolver_present || ! anchor_has_fixture; then
      record reboot-armed FAIL "pre-reboot: resolver or fixture anchor missing"
      return 1
    fi
    printf 'armed\n' > "${WORK}/state/reboot-expect"
    record reboot-armed PREPARED "intent armed; ${RESOLVER_FILE} present; anchor has ${FIXTURE_CIDR}. Waiting for reboot."
  else
    if resolver_present || anchor_has_fixture; then
      record reboot-clear FAIL "pre-reboot: resolver or fixture block still present after clear"
      return 1
    fi
    printf 'clear\n' > "${WORK}/state/reboot-expect"
    record reboot-clear PREPARED "intent clear; resolver absent; anchor has no fixture block. Waiting for reboot."
  fi
  request_reboot "$EXPECT"
  SKIP_CLEANUP=1
}

run_post() {
  local name="reboot-${EXPECT}"
  if dry; then
    plan /usr/bin/dig +time=2 +tries=1 "www.${FIXTURE_SUFFIX}" A
    priv /sbin/pfctl -a "$ANCHOR" -sr
    priv /sbin/pfctl -sr
    plan /bin/cat "$RESOLVER_FILE"
    plan /bin/cat "$INTENT"
    note "armed: resolver file and fixture block are back, main rules reference ${ANCHOR}, rules have no block drop all, kernel was not required"
    note "clear: resolver file absent, anchor has no fixture block, intent is not armed"
    return 0
  fi
  local rules leak main intent
  if [[ "$EXPECT" == "armed" ]]; then
    wait_until 45 helper_running || true
    wait_until 20 resolver_present || true
    wait_until 20 anchor_has_fixture || true
  else
    wait_until 45 helper_running || true
    sleep 2
  fi
  rules=$(/sbin/pfctl -a "$ANCHOR" -sr 2>&1 || true)
  leak=$(printf '%s\n' "$rules" | /usr/bin/python3 "$PROBES" leak-rules || true)
  main=$(/sbin/pfctl -sr 2>&1 || true)
  intent=$(cat "$INTENT" 2>/dev/null || printf 'missing\n')
  local evidence="intent:${intent}
leak:${leak}
resolver_present=$(resolver_present && echo yes || echo no)
--- anchor ---
${rules}
--- main ---
${main}"
  if [[ "$EXPECT" == "armed" ]]; then
    if resolver_present && anchor_has_fixture && printf '%s\n' "$leak" | grep -q 'ok=yes' && printf '%s\n' "$main" | grep -F "$ANCHOR" >/dev/null && printf '%s\n' "$intent" | grep -q '"armed":true'; then
      record "$name" PASS "$evidence"
    else
      record "$name" FAIL "$evidence"
    fi
  else
    if ! resolver_present && ! anchor_has_fixture && ! printf '%s\n' "$intent" | grep -q '"armed":true'; then
      record "$name" PASS "$evidence"
    else
      record "$name" FAIL "$evidence"
    fi
  fi
}

run_all() {
  plan_fail_probes
  if ! prepare_tree; then
    record build FAIL "fetch or build failed; see ${WORK}/logs"
    skip_pending "build failed"
    return 0
  fi
  backup_pf || true
  save_dns || true
  enable_pf || true
  if ! install_daemons; then
    record install FAIL "helper install failed"
    skip_pending "install failed"
    return 0
  fi
  start_bg "${WORK}/state/loopback.pid" /usr/bin/python3 "$PROBES" serve 127.0.0.1 "$LOOPBACK_PORT" non-ai-ok
  if ! arm_helper; then
    record armed-kernel-not-running FAIL "helper did not arm (step ${ARM_FAIL_STEP:-unknown})
${ARM_FAIL_DUMP}
$(log_tail "${WORK}/logs/helper.err")"
    skip_pending "arm failed"
    return 0
  fi
  row_connected
  row_kill_kernel
  row_armed
  row_kill_helper
  # Leak while the anchor is still armed. Restore flushes it.
  row_leak
  row_restore
}

print_cleanup() {
  printf '\nPLAN cleanup on exit (not run after a successful pre-reboot)\n'
  priv /bin/launchctl bootout system "$HELPER_PLIST"
  priv /bin/launchctl bootout system "$RELEASE_PLIST"
  priv /bin/rm -f "$HELPER_PLIST" "$RELEASE_PLIST" "$HELPER_DST" "$KERNEL_DST" "$SEGUE_DST" "$RELAY_DST" "$RELEASE_DST" "$RELEASE_CTL_DST" "$UID_DST"
  priv /sbin/pfctl -a "$ANCHOR" -F all
  priv /bin/cp "${WORK}/state/pf.conf.bak" /etc/pf.conf
  priv /sbin/pfctl -f /etc/pf.conf
  priv /bin/rm -f "$RESOLVER_FILE" "$INTENT" "$FIXTURE_LIST" "${SUPPORT}/kernel.json" "${SUPPORT}/policy.bundle" "${SUPPORT}/dns-snapshot.json"
  priv /bin/rm -rf "${SUPPORT}/kernel"
  priv /sbin/ifconfig lo0 -alias "$FIXTURE_HOST"
  priv /sbin/ifconfig lo0 -alias "$LEAK_HOST"
  if exit_via_alias; then
    priv /sbin/ifconfig "${CARRIER_IFACE:-<physical-iface>}" -alias "$CARRIER_HOST"
    priv /sbin/route -n delete -host "$CARRIER_HOST"
  fi
  note "remove the segue-vm-matrix line from /etc/hosts"
  restore_dns
  priv /sbin/pfctl -X '<pf-token>'
  priv /bin/kill -TERM '<kernel-pid>'
  priv /bin/kill -TERM '<fixture-server-pid>'
  priv /bin/kill -TERM '<relay-pid>'
  if exit_via_alias; then
    priv /bin/kill -TERM '<carrier-pid>'
  fi
  priv /bin/kill -TERM '<ai-host-pid>'
  priv /bin/kill -TERM '<leak-tcp-pid>'
  priv /bin/kill -TERM '<leak-udp-pid>'
}

cleanup() {
  if [[ "$CLEANED" == 1 || "$SKIP_CLEANUP" == 1 ]]; then
    return 0
  fi
  CLEANED=1
  if dry; then
    print_cleanup
    return 0
  fi
  set +e
  printf '\ncleanup: daemons, anchor, resolver file, DNS, alias\n'
  kill_pidfile "${WORK}/state/kernel.pid" segue-kernel
  kill_pidfile "${WORK}/state/fixture.pid" segue
  kill_pidfile "${WORK}/state/relay.pid" segue-relay
  kill_pidfile "${WORK}/state/carrier.pid" probes.py
  kill_pidfile "${WORK}/state/ai-host.pid" probes.py
  kill_pidfile "${WORK}/state/loopback.pid" probes.py
  kill_pidfile "${WORK}/state/leak-tcp.pid" probes.py
  kill_pidfile "${WORK}/state/leak-udp.pid" probes.py
  /bin/launchctl bootout system "$HELPER_PLIST" >/dev/null 2>&1 || true
  /bin/launchctl bootout system "$RELEASE_PLIST" >/dev/null 2>&1 || true
  /bin/rm -f "$HELPER_PLIST" "$RELEASE_PLIST" "$HELPER_DST" "$KERNEL_DST" "$SEGUE_DST" "$RELAY_DST" "$RELEASE_DST" "$RELEASE_CTL_DST" "$UID_DST"
  /sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
  if [[ -f "${WORK}/state/pf.conf.bak" ]]; then
    /bin/cp "${WORK}/state/pf.conf.bak" /etc/pf.conf || true
    /sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
  fi
  /bin/rm -f "$RESOLVER_FILE" "$INTENT" "$FIXTURE_LIST" "${SUPPORT}/kernel.json" "${SUPPORT}/policy.bundle" "${SUPPORT}/dns-snapshot.json"
  /bin/rm -rf "${SUPPORT}/kernel"
  /sbin/ifconfig lo0 -alias "$FIXTURE_HOST" >/dev/null 2>&1 || true
  /sbin/ifconfig lo0 -alias "$LEAK_HOST" >/dev/null 2>&1 || true
  remove_carrier_alias
  hosts_remove
  restore_dns
  if [[ -f "${WORK}/state/pf.token" ]]; then
    /sbin/pfctl -X "$(cat "${WORK}/state/pf.token")" >/dev/null 2>&1 || true
  fi
  /bin/rm -f "${WORK}/state/policy.key" "${WORK}/state/relay.key" "${WORK}/state/device.ticket"
}

skip_reboot_rows() {
  local why="Satellite is destroyed on reboot; run reboot rows on a Tart VM"
  record reboot-armed SKIP "$why"
  record reboot-clear SKIP "$why"
}

show_reboot_plan() {
  if [[ "${HOST_KIND:-vm}" == "satellite" ]]; then
    note "reboot rows are SKIP on a Satellite"
    skip_reboot_rows
    return 0
  fi
  local saved="$EXPECT"
  EXPECT=armed
  printf '\nPLAN --phase pre-reboot --expect armed\n'
  run_pre || true
  printf '\nPLAN --phase post-reboot --expect armed\n'
  run_post || true
  record reboot-armed DRY-RUN "pre-reboot leaves the helper installed with armed intent and prints REBOOT_REQUEST. post-reboot checks the resolver file and the fixture anchor came back and that the rules are not block drop all. The script never reboots."
  EXPECT=clear
  printf '\nPLAN --phase pre-reboot --expect clear\n'
  run_pre || true
  printf '\nPLAN --phase post-reboot --expect clear\n'
  run_post || true
  record reboot-clear DRY-RUN "pre-reboot clears intent, removes the resolver file, flushes the anchor, and prints REBOOT_REQUEST. post-reboot checks the resolver file is absent and the anchor has no fixture block. The script never reboots."
  EXPECT="$saved"
}
