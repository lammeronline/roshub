#!/usr/bin/env bash
# Pushes a .rsc file to the test stand under a disposable script name, runs it once,
# reports whether it parsed/ran without error, and removes the throwaway script.
# RouterOS only reports syntax/runtime errors when a script actually executes, so
# running it is the only real "check" available; side effects the script makes under
# its own rh-<module> prefix (log lines, state files, other script/scheduler objects)
# are not reverted by this tool.
#
# Usage: tools/rh-check.sh <file.rsc>
#
# Multi-line RouterOS blocks (:do/on-error here) sent as an inline ssh command run
# line by line, not as one script, and silently fall apart - so this goes through an
# uploaded wrapper .rsc that gets /import-ed, never through an inline ssh argument.

set -euo pipefail

file="$1"
host="roshub-chr"
name="rh-check-tmp"
tmp="rh-check-$$.rsc"
wrapper="rh-check-wrap-$$.rsc"
localwrapper=$(mktemp)

cat > "$localwrapper" <<EOF
/system script remove [find name="$name"]
/system script add name="$name" source=[/file get [find name="$tmp"] contents]
/file remove [find name="$tmp"]
:do {
  /system script run $name
  :put "RH-CHECK-OK"
} on-error={
  :put "RH-CHECK-FAIL"
}
EOF

scp "$file" "$host:$tmp" >/dev/null
scp "$localwrapper" "$host:$wrapper" >/dev/null
rm -f "$localwrapper"

set +e
out=$(ssh "$host" "/import $wrapper" 2>&1)
status=$?
set -e

ssh "$host" "/file remove [find name=\"$wrapper\"]" 2>/dev/null || true
ssh "$host" "/system script remove [find name=\"$name\"]" 2>/dev/null || true

echo "$out"
if [ $status -ne 0 ] || echo "$out" | grep -q "RH-CHECK-FAIL\|Script Error"; then
  echo "FAIL: $file" >&2
  exit 1
fi
echo "OK: $file"
