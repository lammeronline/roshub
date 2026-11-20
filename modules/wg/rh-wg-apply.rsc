# RH:wg:rh-wg-apply
# Applies a pending route enable/disable. rh-wg sets rhWgPendingComment/
# rhWgPendingEnabled and triggers this as a separate "/system script run".
#
# Naming note: the local holding the comment value is NOT called "comment" -
# naming it the same as the "comment" property being queried in
# "/ip route find comment=$comment" makes RouterOS return extra bogus matches
# for the same live route (reproduced repeatedly on this CHR build; renaming
# the local var is what actually fixes it, not retries or delays).

:global rhLog
:global rhWgPendingComment
:global rhWgPendingEnabled

:local routeComment $rhWgPendingComment
:local enabled $rhWgPendingEnabled

:if ($routeComment != "" && [:len [/ip route find comment=$routeComment]] > 0) do={
  :local wantDisabled "yes"
  :if ($enabled = 1) do={ :set wantDisabled "no" }
  :local tries 0
  :local done 0
  :while ($tries < 3 && $done = 0) do={
    :do {
      /ip route set [find comment=$routeComment] disabled=$wantDisabled
      :local actual [/ip route get [find comment=$routeComment] disabled]
      :local actualStr "yes"
      :if ($actual = false) do={ :set actualStr "no" }
      :if ($actualStr = $wantDisabled) do={ :set done 1 }
    } on-error={ }
    :if ($done = 0) do={
      :set tries ($tries + 1)
      :delay 300ms
    }
  }
  :if ($done = 0) do={
    [$rhLog module="wg" level="warn" text=("could not toggle routes with comment " . $routeComment)]
  }
}
