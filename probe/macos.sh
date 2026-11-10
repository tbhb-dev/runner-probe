#!/usr/bin/env bash
# macOS probes. Usage: macos.sh OUT_DIR PROBE
set -uo pipefail

out=$1
probe=$2
here=$(cd "$(dirname "$0")" && pwd)
rec() { python3 "$here/record.py" "$out" "$@"; }

case "$probe" in
meta)
  rec meta "product_version=$(sw_vers -productVersion)" \
    "build=$(sw_vers -buildVersion)" "arch=$(uname -m)" \
    "image_version=${ImageVersion:-unknown}"
  ;;

seatbelt)
  # Trivial deny-file-read profile: reading the secret must fail under the
  # profile and succeed without it.
  dir=$(cd "${RUNNER_TEMP:-/tmp}" && pwd -P)
  secret="$dir/s69-secret.txt"
  echo hello >"$secret"
  if ! command -v sandbox-exec >/dev/null 2>&1; then
    rec seatbelt "present=false"
    exit 1
  fi
  plain=$(cat "$secret" 2>&1)
  plain_rc=$?
  profile="(version 1)(allow default)(deny file-read* (literal \"$secret\"))"
  denied=$(sandbox-exec -p "$profile" cat "$secret" 2>&1)
  denied_rc=$?
  enforced=false
  [ $plain_rc -eq 0 ] && [ $denied_rc -ne 0 ] && enforced=true
  rec seatbelt "present=true" "unsandboxed_rc=$plain_rc" "sandboxed_rc=$denied_rc" \
    "sandboxed_output=$denied" "enforced=$enforced"
  [ "$enforced" = true ]
  ;;

docker)
  if command -v docker >/dev/null 2>&1; then
    info=$(docker info 2>&1)
    rc=$?
    rec docker "installed=true" "rc=$rc" "info=$(printf '%s' "$info" | head -c 2000)"
    exit $rc
  fi
  rec docker "installed=false"
  exit 1
  ;;

*)
  echo "unknown probe: $probe" >&2
  exit 2
  ;;
esac
