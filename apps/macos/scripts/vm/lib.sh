# Shared helpers for vm-ailock-matrix.sh. Bash 3.2 (macOS /bin/bash).
# The entry script sets DRY_RUN, PHASE, EXPECT, WORK, JSON, repo revisions.

FIXTURE_SUFFIX=ai-fixture.test
FIXTURE_CIDR=198.51.100.0/24
FIXTURE_HOST=198.51.100.10
FIXTURE_TCP_PORT=8080
SOCKS_PORT=18081
KERNEL_DNS_PORT=15353
KERNEL_SOCKS_PORT=18080
GUARD_PORT=5354
UNLISTED_HOST=203.0.113.50
UNLISTED_PORT=443
LOOPBACK_PORT=18099
ANCHOR=segue.ailock
HELPER_LABEL=com.segue.core-helper
SUPPORT="/Library/Application Support/Segue"
HELPER_DST=/Library/PrivilegedHelperTools/segue-core-helper
KERNEL_DST=/Library/PrivilegedHelperTools/segue-kernel
SEGUE_DST=/Library/PrivilegedHelperTools/segue
RELEASE_DST=/Library/PrivilegedHelperTools/segue-release
UID_DST=/Library/PrivilegedHelperTools/segue.allowed-uid
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
  printf '\nROW %s %s\n%s\n' "$result" "$name" "$evidence"
  printf '%s' "$evidence" | /usr/bin/python3 "$REPORT" add "$JSON" "$name" "$result"
  if [[ "$result" == "FAIL" ]]; then
    EXIT_CODE=1
  fi
}

skip_pending() {
  local why="$1" name
  for name in \
    armed-kernel-not-started \
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

dig_has_answer() {
  printf '%s\n' "$1" | grep -Eq 'ANSWER: [1-9]'
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
    plan cargo build --release --manifest-path "${CORE_SRC}/Cargo.toml" -p segue-kernel -p segue-cli
    plan swift build -c release --package-path "${APP_SRC}/apps/macos"
    KERNEL_BUILT="${CARGO_TARGET_DIR}/release/segue-kernel"
    SEGUE_BUILT="${CARGO_TARGET_DIR}/release/segue"
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
    if ! cargo build --release --manifest-path "${CORE_SRC}/Cargo.toml" -p segue-kernel -p segue-cli >"${WORK}/logs/cargo.log" 2>&1; then
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
  HELPER_BIN="${APP_SRC}/apps/macos/.build/release/segue-core-helper"
  if [[ ! -x "$KERNEL_BUILT" || ! -x "$SEGUE_BUILT" || ! -x "$HELPER_BIN" ]]; then
    echo "missing segue-kernel, segue, or segue-core-helper" >&2
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
		<string>--intent</string>
		<string>${INTENT}</string>
		<string>--socket</string>
		<string>/var/run/segue/service.sock</string>
		<string>--allowed-uids</string>
		<string>${UID_DST}</string>
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
  note "segue has no VLESS inbound (socks, http, tun, tproxy). The fixture exit is a loopback SOCKS server."
  note "fixture AI suffix and CIDR are added by a signed policy bundle. The product ai-lock.txt is not edited."
  note "the helper supervisor does not publish a utun and its argv passes --config, which segue-kernel rejects. This matrix starts segue-kernel itself."
  write_helper_plist
  printf '0\n' > "${WORK}/state/allowed-uid"
  priv /bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons /var/run/segue "$SUPPORT" "${SUPPORT}/kernel" "${WORK}/logs" || return 1
  priv /bin/cp "$HELPER_BIN" "$HELPER_DST" || return 1
  priv /bin/chmod 755 "$HELPER_DST" || return 1
  priv /bin/cp "$KERNEL_BUILT" "$KERNEL_DST" || return 1
  priv /bin/chmod 755 "$KERNEL_DST" || return 1
  priv /bin/cp "$SEGUE_BUILT" "$SEGUE_DST" || return 1
  priv /bin/chmod 755 "$SEGUE_DST" || return 1
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
  payload='{"version":1,"kind":"arm","arm":{"schemaVersion":1,"generation":1,"intent":"user_connect","anchor_revision":1,"manifest_digest":"vm-matrix","egress":[{"ip":"127.0.0.1","port":18081}],"exit_ifaces":["lo0"],"strict":false,"evidence":{"policy_version":1,"posture":"vm-matrix"}}}'
  if dry; then
    plan /usr/bin/python3 "$PROBES" helper /var/run/segue/service.sock '<arm-json>'
    printf 'socket=dry-run\n'
    return 0
  fi
  /usr/bin/python3 "$PROBES" helper /var/run/segue/service.sock "$payload" 2>&1 || true
}

arm_helper() {
  copy_fixture_list || return 1
  write_intent true user_connect 1 || return 1
  note "same-boot PF: the helper writes the anchor line into /etc/pf.conf but does not reload it. The harness runs pfctl -f /etc/pf.conf so the anchor is referenced, then restarts the helper to refill the anchor. A reboot loads that file itself."
  if dry; then
    priv /bin/launchctl kickstart -k "system/${HELPER_LABEL}"
    try_socket_arm >/dev/null
    priv /sbin/pfctl -f /etc/pf.conf
    priv /bin/launchctl kickstart -k "system/${HELPER_LABEL}"
    priv /usr/bin/dscacheutil -flushcache
    priv /usr/bin/killall -HUP mDNSResponder
    return 0
  fi
  try_socket_arm > "${WORK}/state/socket-arm.txt" || true
  if ! wait_until 20 resolver_present; then
    /bin/launchctl kickstart -k "system/${HELPER_LABEL}" || return 1
    wait_until 15 resolver_present || return 1
  fi
  if ! main_has_anchor; then
    /sbin/pfctl -f /etc/pf.conf || return 1
    /bin/launchctl kickstart -k "system/${HELPER_LABEL}" || return 1
    wait_until 15 resolver_present || return 1
  fi
  wait_until 15 anchor_has_fixture || return 1
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
  local file="$1" expect="$2" pid cmd
  [[ -f "$file" ]] || return 0
  pid=$(cat "$file" 2>/dev/null || true)
  case "$pid" in
    ""|*[!0-9]*) rm -f "$file"; return 0 ;;
  esac
  cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$cmd" in
    *"$expect"*)
      kill "$pid" 2>/dev/null || true
      sleep 0.3
      kill -9 "$pid" 2>/dev/null || true
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

sign_bundle() {
  local key="${WORK}/state/policy.key"
  local body="${WORK}/state/policy-body.json"
  local pub="<public-key>"
  mkdir -p "${WORK}/state"
  cat > "$body" <<EOF
{"version":1,"expires_at":4000000000,"ai_domains":["${FIXTURE_SUFFIX}"],"ai_cidrs":["${FIXTURE_CIDR}"],"default":{"type":"direct"}}
EOF
  if dry; then
    plan "${KERNEL_DST}" policy-keygen "$key"
    plan "${KERNEL_DST}" sign-bundle --key "$key" --key-id 1 "$body"
    priv /bin/cp "${WORK}/state/policy.bundle" "${SUPPORT}/policy.bundle"
    note "kernel.json home outbound is SOCKS 127.0.0.1:${SOCKS_PORT}; dns.listen is 127.0.0.1:${KERNEL_DNS_PORT}; tun ipv6 is false; domestic resolver is 192.0.2.53 (TEST-NET, not a real server)"
    return 0
  fi
  rm -f "$key"
  pub=$("${KERNEL_DST}" policy-keygen "$key") || return 1
  pub=$(printf '%s' "$pub" | tr -d '[:space:]')
  printf '%s\n' "$pub" > "${WORK}/state/policy.pub"
  "${KERNEL_DST}" sign-bundle --key "$key" --key-id 1 "$body" > "${WORK}/state/policy.bundle" || return 1
  priv /bin/cp "${WORK}/state/policy.bundle" "${SUPPORT}/policy.bundle" || return 1
  priv /bin/chmod 644 "${SUPPORT}/policy.bundle" || return 1
  cat > "${WORK}/state/kernel.json" <<EOF
{
  "listen": "127.0.0.1:${KERNEL_SOCKS_PORT}",
  "outbounds": {
    "home": {
      "role": "home",
      "protocol": "socks",
      "settings": {"servers": [{"address": "127.0.0.1", "port": ${SOCKS_PORT}}]}
    },
    "direct": {"protocol": "freedom"}
  },
  "policy": {
    "public_keys": [{"key_id": 1, "public_key": "${pub}"}],
    "bundle": "policy.bundle",
    "installed": "policy.installed",
    "ai_route": "home"
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
  priv /bin/cp "${WORK}/state/kernel.json" "${SUPPORT}/kernel.json" || return 1
}

start_kernel_stack() {
  write_server_config
  if dry; then
    plan "${SEGUE_DST}" run -config "${WORK}/state/fixture-server.json"
    sign_bundle || return 1
    priv /sbin/ifconfig lo0 alias "${FIXTURE_HOST}" netmask 255.255.255.0
    plan /usr/bin/python3 "$PROBES" serve "${FIXTURE_HOST}" "$FIXTURE_TCP_PORT" ai-host
    plan "${KERNEL_DST}" run --state-dir "${SUPPORT}/kernel" --log "${WORK}/logs/kernel.log" "${SUPPORT}/kernel.json"
    return 0
  fi
  start_bg "${WORK}/state/fixture.pid" "${SEGUE_DST}" run -config "${WORK}/state/fixture-server.json" || return 1
  sign_bundle || return 1
  if ! /sbin/ifconfig lo0 | grep -q '198\.51\.100\.10'; then
    /sbin/ifconfig lo0 alias "${FIXTURE_HOST}" netmask 255.255.255.0 || return 1
  fi
  start_bg "${WORK}/state/ai-host.pid" /usr/bin/python3 "$PROBES" serve "${FIXTURE_HOST}" "$FIXTURE_TCP_PORT" ai-host || return 1
  UTUN_BEFORE=" $(utun_list) "
  mkdir -p "${WORK}/logs"
  nohup "${KERNEL_DST}" run --state-dir "${SUPPORT}/kernel" --log "${WORK}/logs/kernel.log" "${SUPPORT}/kernel.json" >>"${WORK}/logs/kernel.stdout" 2>&1 &
  echo $! > "${WORK}/state/kernel.pid"
  wait_until 20 saw_new_utun || return 1
  wait_until 15 kernel_dns_up || return 1
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
  local name=armed-kernel-not-started
  if dry; then
    plan /usr/bin/dig +time=2 +tries=1 "www.${FIXTURE_SUFFIX}" A
    plan /usr/bin/dig +time=2 +tries=1 example.com A
    plan /usr/bin/python3 "$PROBES" dns 127.0.0.1 "$GUARD_PORT" "www.${FIXTURE_SUFFIX}"
    plan /usr/bin/python3 "$PROBES" tcp 127.0.0.1 "$LOOPBACK_PORT" 2
    cidr_drop_probe || true
    note "kernel is not started for this row"
    record "$name" DRY-RUN "armed, kernel not started: dig of www.${FIXTURE_SUFFIX} is empty NOERROR; dig example.com is a real answer; TCP to ${FIXTURE_CIDR} is dropped (pf counter, alias removed so it is not passed on lo0); TCP to 127.0.0.1 works"
    return 0
  fi
  local dig_ai dig_ex guard loop rules leak
  dig_ai=$(dig_query "www.${FIXTURE_SUFFIX}")
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
  if ! dig_empty_noerror "$dig_ai"; then
    ok=0
    why="${why} armed dig was not empty NOERROR."
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
  if [[ -f "${WORK}/state/kernel.pid" ]]; then
    ok=0
    why="${why} kernel pid file exists."
  fi
  local evidence socket_reply
  socket_reply=$(cat "${WORK}/state/socket-arm.txt" 2>/dev/null || true)
  evidence="why:${why}
socket:${socket_reply}
guard:${guard}
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
    start_kernel_stack || true
    plan /usr/bin/python3 "$PROBES" dns 127.0.0.1 "$KERNEL_DNS_PORT" "www.${FIXTURE_SUFFIX}"
    plan /usr/bin/python3 "$PROBES" egress 198.18.0.1 "$FIXTURE_TCP_PORT" "$SOCKS_PORT" "$UNLISTED_HOST" "$UNLISTED_PORT" "$LOOPBACK_PORT"
    record "$name" DRY-RUN "kernel DNS for www.${FIXTURE_SUFFIX} is a 198.18.0.0/15 fake-IP; a TCP connection to that address opens a session to the fixture SOCKS exit; a non-AI address does not; loopback still connects. System DNS stays on the guard because the helper does not observe this utun."
    return 0
  fi
  if ! start_kernel_stack; then
    record "$name" FAIL "kernel stack did not come up
$(log_tail "${WORK}/logs/kernel.log")
$(log_tail "${WORK}/logs/kernel.stdout")
$(log_tail "${WORK}/logs/fixture.pid.log")"
    return 0
  fi
  local dns ip egress utun
  dns=$(/usr/bin/python3 "$PROBES" dns 127.0.0.1 "$KERNEL_DNS_PORT" "www.${FIXTURE_SUFFIX}" 2>&1 || true)
  ip="${dns#*answers=}"
  ip="${ip%%,*}"
  utun=$(cat "${WORK}/state/utun.name" 2>/dev/null || true)
  if ! printf '%s\n' "$ip" | grep -Eq '^198\.1[89]\.'; then
    record "$name" FAIL "fake-IP missing (${dns}) utun=${utun}
$(log_tail "${WORK}/logs/kernel.log")"
    return 0
  fi
  egress=$(/usr/bin/python3 "$PROBES" egress "$ip" "$FIXTURE_TCP_PORT" "$SOCKS_PORT" "$UNLISTED_HOST" "$UNLISTED_PORT" "$LOOPBACK_PORT" 2>&1 || true)
  local ai_delta other_delta loop
  ai_delta=$(num "$(kv ai_socks_delta "$egress")")
  other_delta=$(num "$(kv other_socks_delta "$egress")")
  loop=$(kv loopback "$egress")
  local evidence="utun=${utun}
dns:${dns}
egress:
${egress}
$(log_tail "${WORK}/logs/kernel.log")"
  if [[ "$ai_delta" -ge 1 && "$other_delta" == 0 && "$loop" == "ok" ]]; then
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
    plan /usr/bin/dig +time=2 +tries=1 "www.${FIXTURE_SUFFIX}" A
    plan /usr/bin/dig +time=2 +tries=1 example.com A
    cidr_drop_probe || true
    record "$name" DRY-RUN "after SIGTERM to segue-kernel only: its utun is gone; armed name is still empty NOERROR; example.com still answers; fixture CIDR still dropped; non-AI loopback still connects"
    return 0
  fi
  if [[ ! -f "${WORK}/state/kernel.pid" ]]; then
    record "$name" SKIP "kernel was not started"
    return 0
  fi
  local pid utun dig_ai dig_ex loop dropped=0
  pid=$(cat "${WORK}/state/kernel.pid")
  utun=$(cat "${WORK}/state/utun.name" 2>/dev/null || true)
  kill_pidfile "${WORK}/state/kernel.pid" segue-kernel
  sleep 2
  dig_ai=$(dig_query "www.${FIXTURE_SUFFIX}")
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
  if [[ "$still" != "no" ]]; then
    ok=0
    why="${why} utun ${utun} still present (${still})."
  fi
  if ! dig_empty_noerror "$dig_ai"; then
    ok=0
    why="${why} armed name was not empty NOERROR."
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
pid=${pid} utun=${utun} gone=${still}
loop:${loop}
${CIDR_EVIDENCE}
--- armed dig ---
${dig_ai}
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
    plan /usr/bin/dig +time=2 +tries=1 example.com A
    record "$name" DRY-RUN "SIGKILL the helper. launchd KeepAlive restarts it. During the gap the armed name times out or is empty NOERROR, and example.com still answers. After the helper is back the armed name is empty NOERROR again. A real answer for the armed name is a leak (FAIL)."
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
  fi
  after=$(dig_query "www.${FIXTURE_SUFFIX}")
  ex_after=$(dig_query example.com)
  local ok=1 why=""
  if dig_has_answer "$during"; then
    ok=0
    why="${why} armed name answered during the gap."
  elif dig_empty_noerror "$during" || dig_timed_out "$during"; then
    :
  else
    ok=0
    why="${why} armed dig during the gap was neither empty nor a timeout."
  fi
  if ! dig_has_answer "$before" || ! dig_has_answer "$during_ex" || ! dig_has_answer "$ex_after"; then
    ok=0
    why="${why} example.com failed before, during, or after the restart."
  fi
  if [[ "$restarted" != 1 ]]; then
    ok=0
    why="${why} helper did not restart."
  elif ! dig_empty_noerror "$after"; then
    ok=0
    why="${why} armed name was not empty NOERROR after the helper returned."
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

row_restore() {
  local name=restore-via-release-daemon
  local built="${APP_SRC}/apps/macos/.build/release/segue-release"
  if dry; then
    note "SKIP when ${built} and ${RELEASE_DST} are absent"
    priv /bin/cp "$built" "$RELEASE_DST"
    priv /bin/launchctl bootstrap system "$RELEASE_PLIST"
    priv /bin/kill -STOP '<helper-pid>'
    plan /usr/bin/python3 "$PROBES" helper /var/run/segue-release.sock '<restore>'
    priv /bin/kill -CONT '<helper-pid>'
    record "$name" DRY-RUN "SKIP if no segue-release binary. If one is built, install it, SIGSTOP the helper, and ask /var/run/segue-release.sock. There is no release binary in this tree, and this script will not invent a wire message and call that a pass."
    return 0
  fi
  if [[ ! -x "$built" && ! -x "$RELEASE_DST" ]]; then
    record "$name" SKIP "no segue-release at ${built} or ${RELEASE_DST}"
    return 0
  fi
  local src="$built"
  if [[ ! -x "$src" ]]; then
    src="$RELEASE_DST"
  fi
  priv /bin/cp "$src" "$RELEASE_DST" || true
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
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
EOF
  /bin/cp "${WORK}/state/release.plist" "$RELEASE_PLIST"
  /bin/launchctl bootout system "$RELEASE_PLIST" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap system "$RELEASE_PLIST" || true
  local pid
  pid=$(helper_pid)
  if [[ -n "$pid" ]]; then
    kill -STOP "$pid" 2>/dev/null || true
  fi
  sleep 2
  local sock="absent"
  if [[ -S /var/run/segue-release.sock ]]; then
    sock="present"
  fi
  if [[ -n "$pid" ]]; then
    kill -CONT "$pid" 2>/dev/null || true
  fi
  record "$name" FAIL "segue-release exists (${src}) but this matrix has no restore message to send. socket=${sock}. Left the helper resumed (SIGCONT)."
}

row_leak() {
  local name=expected-leak-doh-quic
  if dry; then
    priv /sbin/pfctl -a "$ANCHOR" -sr
    plan /usr/bin/python3 "$PROBES" tcp "$UNLISTED_HOST" "$UNLISTED_PORT" 1
    plan /usr/bin/python3 "$PROBES" udp "$UNLISTED_HOST" "$UNLISTED_PORT"
    record "$name" DRY-RUN "PASS only if the anchor blocks ${FIXTURE_CIDR} and does not block ${UNLISTED_HOST}:443 (TCP or UDP). An unlisted DoH/QUIC target staying reachable is the expected leak. A broad block, a UDP/443 block, or any block that is not the fixture CIDR is FAIL."
    return 0
  fi
  local rules verdict before after tcp udp bp ap be ae
  rules=$(/sbin/pfctl -a "$ANCHOR" -sr 2>&1 || true)
  verdict=$(printf '%s\n' "$rules" | /usr/bin/python3 "$PROBES" leak-rules || true)
  before=$(/sbin/pfctl -a "$ANCHOR" -sr -v 2>&1 || true)
  tcp=$(/usr/bin/python3 "$PROBES" tcp "$UNLISTED_HOST" "$UNLISTED_PORT" 1 2>&1 || true)
  udp=$(/usr/bin/python3 "$PROBES" udp "$UNLISTED_HOST" "$UNLISTED_PORT" 2>&1 || true)
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
  if printf '%s\n' "$verdict" | grep -q 'ok=yes' && [[ "$ap" == "$bp" && "$ae" == "$be" ]]; then
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
Archive the Amp Satellite thread only after that JSON is copied out.
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
    record armed-kernel-not-started FAIL "helper did not arm
$(log_tail "${WORK}/logs/helper.err")"
    skip_pending "arm failed"
    return 0
  fi
  row_armed
  row_connected
  row_kill_kernel
  row_kill_helper
  row_restore
  row_leak
}

print_cleanup() {
  printf '\nPLAN cleanup on exit (not run after a successful pre-reboot)\n'
  priv /bin/launchctl bootout system "$HELPER_PLIST"
  priv /bin/launchctl bootout system "$RELEASE_PLIST"
  priv /bin/rm -f "$HELPER_PLIST" "$RELEASE_PLIST" "$HELPER_DST" "$KERNEL_DST" "$SEGUE_DST" "$RELEASE_DST" "$UID_DST"
  priv /sbin/pfctl -a "$ANCHOR" -F all
  priv /bin/cp "${WORK}/state/pf.conf.bak" /etc/pf.conf
  priv /sbin/pfctl -f /etc/pf.conf
  priv /bin/rm -f "$RESOLVER_FILE" "$INTENT" "$FIXTURE_LIST" "${SUPPORT}/kernel.json" "${SUPPORT}/policy.bundle" "${SUPPORT}/dns-snapshot.json"
  priv /bin/rm -rf "${SUPPORT}/kernel"
  priv /sbin/ifconfig lo0 -alias "$FIXTURE_HOST"
  restore_dns
  priv /sbin/pfctl -X '<pf-token>'
  priv /bin/kill -TERM '<kernel-pid>'
  priv /bin/kill -TERM '<fixture-server-pid>'
  priv /bin/kill -TERM '<ai-host-pid>'
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
  kill_pidfile "${WORK}/state/ai-host.pid" probes.py
  kill_pidfile "${WORK}/state/loopback.pid" probes.py
  /bin/launchctl bootout system "$HELPER_PLIST" >/dev/null 2>&1 || true
  /bin/launchctl bootout system "$RELEASE_PLIST" >/dev/null 2>&1 || true
  /bin/rm -f "$HELPER_PLIST" "$RELEASE_PLIST" "$HELPER_DST" "$KERNEL_DST" "$SEGUE_DST" "$RELEASE_DST" "$UID_DST"
  /sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
  if [[ -f "${WORK}/state/pf.conf.bak" ]]; then
    /bin/cp "${WORK}/state/pf.conf.bak" /etc/pf.conf || true
    /sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
  fi
  /bin/rm -f "$RESOLVER_FILE" "$INTENT" "$FIXTURE_LIST" "${SUPPORT}/kernel.json" "${SUPPORT}/policy.bundle" "${SUPPORT}/dns-snapshot.json"
  /bin/rm -rf "${SUPPORT}/kernel"
  /sbin/ifconfig lo0 -alias "$FIXTURE_HOST" >/dev/null 2>&1 || true
  restore_dns
  if [[ -f "${WORK}/state/pf.token" ]]; then
    /sbin/pfctl -X "$(cat "${WORK}/state/pf.token")" >/dev/null 2>&1 || true
  fi
  /bin/rm -f "${WORK}/state/policy.key"
}

show_reboot_plan() {
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
