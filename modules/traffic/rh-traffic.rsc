# RH:traffic:rh-traffic
# Per-interface traffic accounting: daily and monthly totals, surviving a
# counter reset on reboot (RouterOS interface byte counters start back at 0;
# a negative delta is treated as "counter restarted", adding the new raw
# value instead of a negative delta). Run every 5m by its own scheduler.
#
# Config (rhConfig):
#   traffic.interfaces           comma-separated interface names (required)
#   traffic.<iface>.limit-mb     optional monthly limit in MiB; publishes
#                                 traffic.limit once per calendar month if
#                                 exceeded
#
# Day/month are tracked as plain numbers (YYYYMMDD / YYYYMM), not date
# strings - RouterOS's JSON round-trip rewrites a bare "YYYY-MM-DD" string
# into a full datetime ("...  00:00:00"), so a date-shaped string is not
# safe to store as-is.

:global rhLog
:global rhConfigGet
:global rhStateLoad
:global rhStateSave
:global rhEventPublish

:global rhTrafficState

:if ([:typeof $rhTrafficState] = "nothing") do={
  :set rhTrafficState [$rhStateLoad module="traffic"]
  :if ([:typeof ($rhTrafficState->"ifaces")] = "nothing") do={
    :set ($rhTrafficState->"ifaces") [:toarray ""]
  }
}

:local dateStr [/system clock get date]
:local year [:tonum [:pick $dateStr 0 4]]
:local month [:tonum [:pick $dateStr 5 7]]
:local day [:tonum [:pick $dateStr 8 10]]
:local dayKey ((($year * 10000) + ($month * 100)) + $day)
:local monthKey (($year * 100) + $month)

:local ifaceNames [$rhConfigGet key="traffic.interfaces" dflt=""]
:local list [:toarray $ifaceNames]
:local ifaces ($rhTrafficState->"ifaces")

:foreach ifname in=$list do={
  :local rxNow 0
  :local txNow 0
  :do {
    :set rxNow [/interface get $ifname rx-byte]
    :set txNow [/interface get $ifname tx-byte]
  } on-error={
    [$rhLog module="traffic" level="warn" text=("interface not found: " . $ifname)]
  }

  :local st ($ifaces->$ifname)
  :if ([:typeof $st] = "nothing") do={
    :set st [:toarray ""]
    :set ($st->"last-rx") $rxNow
    :set ($st->"last-tx") $txNow
    :set ($st->"day-key") $dayKey
    :set ($st->"day-rx") 0
    :set ($st->"day-tx") 0
    :set ($st->"month-key") $monthKey
    :set ($st->"month-rx") 0
    :set ($st->"month-tx") 0
    :set ($st->"notified") 0
  }

  :local deltaRx ($rxNow - ($st->"last-rx"))
  :local deltaTx ($txNow - ($st->"last-tx"))
  :if ($deltaRx < 0) do={ :set deltaRx $rxNow }
  :if ($deltaTx < 0) do={ :set deltaTx $txNow }
  :set ($st->"last-rx") $rxNow
  :set ($st->"last-tx") $txNow

  :if (($st->"day-key") != $dayKey) do={
    :set ($st->"day-key") $dayKey
    :set ($st->"day-rx") 0
    :set ($st->"day-tx") 0
  }
  :set ($st->"day-rx") (($st->"day-rx") + $deltaRx)
  :set ($st->"day-tx") (($st->"day-tx") + $deltaTx)

  :if (($st->"month-key") != $monthKey) do={
    :set ($st->"month-key") $monthKey
    :set ($st->"month-rx") 0
    :set ($st->"month-tx") 0
    :set ($st->"notified") 0
  }
  :set ($st->"month-rx") (($st->"month-rx") + $deltaRx)
  :set ($st->"month-tx") (($st->"month-tx") + $deltaTx)

  :local limitMb [$rhConfigGet key=("traffic." . $ifname . ".limit-mb") dflt=""]
  :if ($limitMb != "" && ($st->"notified") = 0) do={
    :local totalMb ((($st->"month-rx") + ($st->"month-tx")) / 1048576)
    :if ($totalMb >= [:tonum $limitMb]) do={
      :set ($st->"notified") 1
      [$rhEventPublish name="traffic.limit" level="warn" module="traffic" text=($ifname . ": " . $totalMb . " MiB this month, limit " . $limitMb . " MiB")]
    }
  }

  :set ($ifaces->$ifname) $st
}

:set ($rhTrafficState->"ifaces") $ifaces
[$rhStateSave module="traffic" data=$rhTrafficState]
