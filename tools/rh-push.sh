#!/usr/bin/env bash
# Uploads a .rsc file to the test stand (ssh alias "roshub-chr") and creates/updates
# a RouterOS script object with the same content. Does not run it - see rh-check.sh
# for push+run+cleanup, or pass --run here to run it in place afterwards.
#
# Usage: tools/rh-push.sh <file.rsc> [--name <script-name>] [--run]
#
# Multi-line RouterOS blocks (:if/:do/...) sent as an inline ssh command run line by
# line, not as one script, and silently fall apart - so all control flow here goes
# through an uploaded wrapper .rsc that gets /import-ed, never through an inline
# multi-line ssh argument.

set -euo pipefail

file=""
name=""
run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --run) run=1; shift ;;
    *) file="$1"; shift ;;
  esac
done

if [ -z "$file" ]; then
  echo "usage: $0 <file.rsc> [--name <script-name>] [--run]" >&2
  exit 1
fi

if [ -z "$name" ]; then
  base=$(basename "$file")
  name="${base%.rsc}"
fi

host="roshub-chr"
tmp="rh-push-$$.rsc"
wrapper="rh-push-wrap-$$.rsc"
localwrapper=$(mktemp)

cat > "$localwrapper" <<EOF
:if ([:len [/system script find name="$name"]] > 0) do={
  /system script set [find name="$name"] source=[/file get [find name="$tmp"] contents]
} else={
  /system script add name="$name" source=[/file get [find name="$tmp"] contents]
}
/file remove [find name="$tmp"]
EOF

scp "$file" "$host:$tmp" >/dev/null
scp "$localwrapper" "$host:$wrapper" >/dev/null
rm -f "$localwrapper"
ssh "$host" "/import $wrapper"
ssh "$host" "/file remove [find name=\"$wrapper\"]"

echo "pushed $file as script \"$name\""

if [ "$run" -eq 1 ]; then
  ssh "$host" "/system script run $name"
  echo "ran \"$name\""
fi
