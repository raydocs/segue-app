#!/bin/bash
# AI-lock matrix for a throwaway macOS VM.
# See apps/macos/scripts/vm/README.md and docs/design/macos.md §5.
#
# Refuses unless SEGUE_VM_MATRIX=throwaway. A real run also requires
# kern.hv_vmm_present=1 and root. --dry-run prints every privileged command
# and does not run it. This script never reboots and never calls shutdown.

set -uo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
VM_DIR="$(cd "$(dirname "$0")" && pwd)/vm"

usage() {
  cat <<EOF
usage: SEGUE_VM_MATRIX=throwaway $SCRIPT_PATH [--dry-run]
       [--phase all|pre-reboot|post-reboot] [--expect armed|clear]
       [--core-rev REV] [--app-rev REV]
       [--core-repo URL] [--app-repo URL]
       [--work-dir DIR] [--json PATH] [--skip-build]

--dry-run prints the plan and exits 0. It still requires
SEGUE_VM_MATRIX=throwaway. A real run also requires a VM
(sysctl kern.hv_vmm_present = 1) and root.

Default JSON: <work-dir>/vm-ailock-matrix-<phase>[-<expect>].json
Default work dir: /var/tmp/segue-vm-matrix
EOF
}

DRY_RUN=0
PHASE=all
EXPECT=
CORE_REV=
APP_REV=
CORE_REPO=https://github.com/raydocs/segue-core.git
APP_REPO=https://github.com/raydocs/segue-app.git
WORK=/var/tmp/segue-vm-matrix
JSON=
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --phase) PHASE="${2:?}"; shift 2 ;;
    --expect) EXPECT="${2:?}"; shift 2 ;;
    --core-rev) CORE_REV="${2:?}"; shift 2 ;;
    --app-rev) APP_REV="${2:?}"; shift 2 ;;
    --core-repo) CORE_REPO="${2:?}"; shift 2 ;;
    --app-repo) APP_REPO="${2:?}"; shift 2 ;;
    --work-dir) WORK="${2:?}"; shift 2 ;;
    --json) JSON="${2:?}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$PHASE" in
  all|pre-reboot|post-reboot) ;;
  *)
    echo "unknown phase: $PHASE" >&2
    exit 2
    ;;
esac

if [[ "$PHASE" == "pre-reboot" || "$PHASE" == "post-reboot" ]]; then
  case "$EXPECT" in
    armed|clear) ;;
    *)
      echo "--expect armed|clear is required for --phase ${PHASE}" >&2
      exit 2
      ;;
  esac
elif [[ -n "$EXPECT" ]]; then
  echo "--expect is only valid with --phase pre-reboot or post-reboot" >&2
  exit 2
fi

if [[ -z "$JSON" ]]; then
  if [[ -n "$EXPECT" ]]; then
    JSON="${WORK}/vm-ailock-matrix-${PHASE}-${EXPECT}.json"
  else
    JSON="${WORK}/vm-ailock-matrix-${PHASE}.json"
  fi
fi

HV_PRESENT="$(/usr/sbin/sysctl -n kern.hv_vmm_present 2>/dev/null || true)"
if [[ -z "$HV_PRESENT" ]]; then
  HV_PRESENT=unavailable
fi

if [[ "${SEGUE_VM_MATRIX:-}" != "throwaway" ]]; then
  cat >&2 <<EOF
refusing: SEGUE_VM_MATRIX is not set to throwaway.
This script installs LaunchDaemons and changes PF, resolver files, and DNS.
Set SEGUE_VM_MATRIX=throwaway only for a throwaway VM. --dry-run still
requires that variable; it prints the privileged commands and does not run them.
EOF
  exit 2
fi

if [[ "$DRY_RUN" != 1 ]]; then
  if [[ "$HV_PRESENT" != "1" ]]; then
    cat >&2 <<EOF
refusing: this host is not a VM (sysctl kern.hv_vmm_present is ${HV_PRESENT}, need 1).
The matrix loads PF, writes resolver files, and installs LaunchDaemons.
On this Mac, re-run with --dry-run. Inside the throwaway VM, export
SEGUE_VM_MATRIX=throwaway and run as root.
EOF
    exit 2
  fi
  if [[ "$(id -u)" != "0" ]]; then
    echo "refusing: a real run must be root." >&2
    exit 2
  fi
else
  printf 'dry-run: not executing privileged commands (kern.hv_vmm_present=%s)\n' "$HV_PRESENT"
fi

mkdir -p "${WORK}/state" "${WORK}/logs" "${WORK}/src"
# shellcheck source=vm/lib.sh
source "${VM_DIR}/lib.sh"
/usr/bin/python3 "$REPORT" init "$JSON" "$DRY_RUN" "$PHASE" "$HV_PRESENT" "${CORE_REV:-}" "${APP_REV:-}"
trap cleanup EXIT

if [[ "$DRY_RUN" == 1 ]]; then
  note "a real run of this process would execute phase ${PHASE} expect=${EXPECT:-n/a}. The plan below is the whole matrix, including both reboot phases."
  run_all
  show_reboot_plan
  printf '\nSUMMARY dry-run json=%s\n' "$JSON"
  exit 0
fi

if [[ "$PHASE" != "post-reboot" ]]; then
  cleanup
  CLEANED=0
fi

case "$PHASE" in
  all)
    run_all
    ;;
  pre-reboot)
    if ! run_pre; then
      if ! seen "reboot-${EXPECT}"; then
        record "reboot-${EXPECT}" FAIL "pre-reboot setup failed"
      fi
      EXIT_CODE=1
    fi
    ;;
  post-reboot)
    run_post
    ;;
esac

printf '\nSUMMARY fails=%s json=%s\n' "$EXIT_CODE" "$JSON"
exit "$EXIT_CODE"
