# RH:wg:rh-wg
# WireGuard tunnel watchdog. Replaces the manual wg-health/wg-routes-on-off/
# wg-flush-web scheme: pings a set of hosts through the tunnel, and on enough
# consecutive failures/successes flips a set of routes (tagged by comment)
# between enabled/disabled, optionally flushing web connections on switch.
# Run every 30s by its own scheduler (module.json) - stateless between runs
# except for what is persisted via rhStateSave.
#
# Config (rhConfig):
#   wg.check-hosts      comma-separated IPs to ping through the tunnel (required)
#   wg.fail-threshold   consecutive failures before going down (default 3)
#   wg.recover-threshold consecutive successes before going back up (default 3)
#   wg.routes-comment   comment tag on the /ip route entries to toggle (required)
#   wg.flush-web        yes/no - drop web (80/443) connections on switch (default no)

:global rhLog
:global rhConfigGet
:global rhStateLoad
:global rhStateSave
:global rhEventPublish
:global rhNow

:global rhWgState

:if ([:typeof $rhWgState] = "nothing") do={
  :set rhWgState [$rhStateLoad module="wg"]
  :if ([:typeof ($rhWgState->"status")] = "nothing") do={ :set ($rhWgState->"status") "up" }
  :if ([:typeof ($rhWgState->"fails")] = "nothing") do={ :set ($rhWgState->"fails") 0 }
  :if ([:typeof ($rhWgState->"oks")] = "nothing") do={ :set ($rhWgState->"oks") 0 }
  :if ([:typeof ($rhWgState->"history")] = "nothing") do={ :set ($rhWgState->"history") [:toarray ""] }
}

# Pings every configured host once; returns 1 if any of them answered.
:global rhWgCheck do={
  :global rhLog
  :global rhConfigGet
  :local hosts [$rhConfigGet key="wg.check-hosts" dflt=""]
  :local list [:toarray $hosts]
  :if ([:len $list] = 0) do={
    [$rhLog module="wg" level="warn" text="wg.check-hosts not configured"]
    :return 1
  }
  :local ok 0
  :foreach h in=$list do={
    :local received 0
    :do {
      :set received [/ping $h count=2]
    } on-error={ :set received 0 }
    :if ($received > 0) do={ :set ok 1 }
  }
  :return $ok
}

# Delegates the actual route change to rh-wg-apply, run as a separate script -
# calling rhConfigGet (which touches /file) and then /ip route set in the same
# execution occasionally corrupts the match on this CHR build; see
# rh-wg-apply.rsc for the full explanation and the retry/verify logic itself.
:global rhWgSetRoutes do={
  :global rhConfigGet
  :global rhWgPendingComment
  :global rhWgPendingEnabled
  :set rhWgPendingComment [$rhConfigGet key="wg.routes-comment" dflt=""]
  :set rhWgPendingEnabled $enabled
  /system script run rh-wg-apply
}

:global rhWgFlushWeb do={
  :global rhConfigGet
  :local flush [$rhConfigGet key="wg.flush-web" dflt="no"]
  :if ($flush = "yes") do={
    /ip firewall connection remove [find dst-port=80 || dst-port=443]
  }
}

:local ok [$rhWgCheck]
:local status ($rhWgState->"status")

:if ($ok = 1) do={
  :set ($rhWgState->"fails") 0
  :set ($rhWgState->"oks") (($rhWgState->"oks") + 1)
  :local recoverN [:tonum [$rhConfigGet key="wg.recover-threshold" dflt="3"]]
  :if ($status = "down" && ($rhWgState->"oks") >= $recoverN) do={
    :set ($rhWgState->"status") "up"
    [$rhWgSetRoutes enabled=1]
    [$rhWgFlushWeb]
    :local h ($rhWgState->"history")
    :local idx ([:len $h] - 1)
    :if ($idx >= 0) do={
      :local last ($h->$idx)
      :set ($last->"end") [$rhNow]
      :set ($h->$idx) $last
      :set ($rhWgState->"history") $h
    }
    [$rhLog module="wg" level="warn" text="tunnel recovered, routes enabled"]
    [$rhEventPublish name="wg.up" level="warn" module="wg" text="tunnel recovered"]
  }
} else={
  :set ($rhWgState->"oks") 0
  :set ($rhWgState->"fails") (($rhWgState->"fails") + 1)
  :local failN [:tonum [$rhConfigGet key="wg.fail-threshold" dflt="3"]]
  :if ($status = "up" && ($rhWgState->"fails") >= $failN) do={
    :set ($rhWgState->"status") "down"
    [$rhWgSetRoutes enabled=0]
    [$rhWgFlushWeb]
    :local h ($rhWgState->"history")
    :local entry [:toarray ""]
    :set ($entry->"start") [$rhNow]
    :set ($entry->"end") ""
    :set ($h->[:len $h]) $entry
    :set ($rhWgState->"history") $h
    [$rhLog module="wg" level="crit" text="tunnel down, routes disabled"]
    [$rhEventPublish name="wg.down" level="crit" module="wg" text="tunnel down"]
  }
}

[$rhStateSave module="wg" data=$rhWgState]
