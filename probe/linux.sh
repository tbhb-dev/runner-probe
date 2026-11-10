#!/usr/bin/env bash
# Linux probes. Usage: linux.sh OUT_DIR PROBE [ARG]
# Each probe writes a JSON fragment into OUT_DIR, then exits non-zero if the
# probed capability is missing or failed, so the workflow step shows red.
# All state changes (sysctl, AppArmor profile, udev rule) are on the ephemeral
# runner only.
set -uo pipefail

out=$1
probe=$2
arg=${3:-}
here=$(cd "$(dirname "$0")" && pwd)
rec() { python3 "$here/record.py" "$out" "$@"; }
sysctl_read() { cat "/proc/sys/kernel/$1" 2>/dev/null || echo absent; }

case "$probe" in
meta)
  rec meta \
    "kernel=$(uname -r)" \
    "os_release=$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")" \
    "image_version=${ImageVersion:-unknown}" \
    "apparmor_module_loaded=$([ -d /sys/module/apparmor ] && echo true || echo false)"
  ;;

sysctl)
  restrict=$(sysctl_read apparmor_restrict_unprivileged_userns)
  clone=$(sysctl_read unprivileged_userns_clone)
  max_userns=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo absent)
  rec sysctl \
    "apparmor_restrict_unprivileged_userns=$restrict" \
    "unprivileged_userns_clone=$clone" \
    "max_user_namespaces=$max_userns"
  ;;

bwrap-install)
  # Record whether bwrap is preinstalled; install it only if missing so the
  # tests below can run. The record says which happened.
  if command -v bwrap >/dev/null 2>&1; then
    rec bwrap_install "preinstalled=true" "path=$(command -v bwrap)" \
      "version=$(bwrap --version 2>&1)"
  else
    sudo apt-get install -y --no-install-recommends bubblewrap >/dev/null 2>&1
    rc=$?
    rec bwrap_install "preinstalled=false" "installed_by_probe=$([ $rc -eq 0 ] && echo true || echo false)" \
      "apt_rc=$rc" "version=$(bwrap --version 2>&1 || true)"
    exit $rc
  fi
  ;;

bwrap-test)
  # arg is the label: before, after-sysctl, after-profile
  if ! command -v bwrap >/dev/null 2>&1; then
    rec "bwrap_$arg" "ran=false" "reason=bwrap not installed"
    exit 1
  fi
  stderr=$(bwrap --unshare-user --ro-bind / / true 2>&1 >/dev/null)
  rc=$?
  rec "bwrap_$arg" "ran=true" "rc=$rc" "stderr=$stderr" \
    "restrict_sysctl=$(sysctl_read apparmor_restrict_unprivileged_userns)"
  exit $rc
  ;;

sysctl-off)
  # Runner-only change: disable the AppArmor userns restriction.
  orig=$(sysctl_read apparmor_restrict_unprivileged_userns)
  if [ "$orig" = absent ]; then
    rec sysctl_off "applied=false" "reason=sysctl absent"
    exit 1
  fi
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 >/dev/null
  rc=$?
  rec sysctl_off "applied=$([ $rc -eq 0 ] && echo true || echo false)" \
    "original=$orig" "now=$(sysctl_read apparmor_restrict_unprivileged_userns)"
  exit $rc
  ;;

sysctl-restore)
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=1 >/dev/null
  rc=$?
  rec sysctl_restore "rc=$rc" "now=$(sysctl_read apparmor_restrict_unprivileged_userns)"
  exit $rc
  ;;

profile)
  # Runner-only change: an AppArmor profile that lets bwrap use userns.
  bwrap_path=$(command -v bwrap || true)
  if [ -z "$bwrap_path" ] || ! command -v apparmor_parser >/dev/null 2>&1; then
    rec apparmor_profile "applied=false" "reason=bwrap or apparmor_parser missing"
    exit 1
  fi
  bwrap_path=$(readlink -f "$bwrap_path")
  tmp=$(mktemp)
  cat >"$tmp" <<EOF
abi <abi/4.0>,
include <tunables/global>
profile s69-bwrap $bwrap_path flags=(unconfined) {
  userns,
}
EOF
  sudo cp "$tmp" /etc/apparmor.d/s69-bwrap
  sudo apparmor_parser -r /etc/apparmor.d/s69-bwrap
  rc=$?
  rec apparmor_profile "applied=$([ $rc -eq 0 ] && echo true || echo false)" \
    "rc=$rc" "bwrap_path=$bwrap_path"
  exit $rc
  ;;

kvm-udev)
  # The documented udev rule that opens /dev/kvm to all users.
  echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' |
    sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null &&
    sudo udevadm control --reload-rules &&
    sudo udevadm trigger --name-match=kvm
  rc=$?
  rec kvm_udev_step "applied=$([ $rc -eq 0 ] && echo true || echo false)" "rc=$rc"
  exit $rc
  ;;

kvm)
  # arg is the udev variant: with-udev or without-udev
  present=false
  [ -e /dev/kvm ] && present=true
  rw=false
  [ -r /dev/kvm ] && [ -w /dev/kvm ] && rw=true
  rec kvm "variant=$arg" "present=$present" "user_rw=$rw" \
    "mode=$(stat -c '%a %U:%G' /dev/kvm 2>/dev/null || echo none)" \
    "user=$(id -un):$(id -Gn | tr ' ' ',')"
  [ "$rw" = true ]
  ;;

docker)
  if ! command -v docker >/dev/null 2>&1; then
    rec docker "installed=false"
    exit 1
  fi
  info=$(docker info --format '{{json .}}' 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    python3 - "$out" "$info" <<'PY'
import json, os, sys
info = json.loads(sys.argv[2])
keep = ["OSType", "Architecture", "ServerVersion", "Isolation", "CgroupDriver",
        "CgroupVersion", "SecurityOptions", "Runtimes", "DefaultRuntime"]
rec = {"installed": True, "rc": 0}
rec.update({k: info.get(k) for k in keep})
os.makedirs(sys.argv[1], exist_ok=True)
json.dump(rec, open(os.path.join(sys.argv[1], "docker.json"), "w"), indent=2)
PY
  else
    rec docker "installed=true" "rc=$rc" "error=$info"
  fi
  exit $rc
  ;;

*)
  echo "unknown probe: $probe" >&2
  exit 2
  ;;
esac
