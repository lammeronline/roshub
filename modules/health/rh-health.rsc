# RH:health:rh-health
# Router health checks with warn/crit thresholds and hysteresis (N consecutive
# readings at a new level before it counts), run every minute by its own
# scheduler. Publishes rhEventPublish only on a confirmed level change
# (ok -> warn -> crit -> ok), never on every run.
#
# Config (rhConfig):
#   health.cpu-warn / health.cpu-crit       percent, default 80 / 95
#   health.mem-warn / health.mem-crit       percent FREE below this, default 15 / 5
#   health.disk-warn / health.disk-crit     percent FREE below this, default 15 / 5
#   health.ping-hosts                       comma-separated IPs/hosts (optional)
#   health.dns-check                        hostname to resolve each run (optional)
#   health.hysteresis                       consecutive readings to confirm a
#                                            level change, default 3

:global rhLog
:global rhConfigGet
:global rhStateLoad
:global rhStateSave
:global rhEventPublish
:global rhNow

:global rhHealthState

:if ([:typeof $rhHealthState] = "nothing") do={
  :set rhHealthState [$rhStateLoad module="health"]
  :if ([:typeof ($rhHealthState->"checks")] = "nothing") do={
    :set ($rhHealthState->"checks") [:toarray ""]
  }
  :if ([:typeof ($rhHealthState->"last-uptime")] = "nothing") do={
    :set ($rhHealthState->"last-uptime") ""
  }
  :if ([:typeof ($rhHealthState->"reboot-count")] = "nothing") do={
    :set ($rhHealthState->"reboot-count") 0
  }
}

# Feeds one check's raw level ("ok"/"warn"/"crit") through hysteresis and
# publishes an event if the confirmed level actually changes. args: name, level, text
:global rhHealthEval do={
  :global rhHealthState
  :global rhConfigGet
  :global rhLog
  :global rhEventPublish
  :local hyst [:tonum [$rhConfigGet key="health.hysteresis" dflt="3"]]

  :local checks ($rhHealthState->"checks")
  :local st ($checks->$name)
  :if ([:typeof $st] = "nothing") do={
    :set st [:toarray ""]
    :set ($st->"level") "ok"
    :set ($st->"pending") ""
    :set ($st->"count") 0
  }
  :local curLevel ($st->"level")

  :if ($level = $curLevel) do={
    :set ($st->"pending") ""
    :set ($st->"count") 0
  } else={
    :if ($level = ($st->"pending")) do={
      :set ($st->"count") (($st->"count") + 1)
    } else={
      :set ($st->"pending") $level
      :set ($st->"count") 1
    }
    :if (($st->"count") >= $hyst) do={
      :set ($st->"level") $level
      :set ($st->"pending") ""
      :set ($st->"count") 0
      :local evLevel "info"
      :if ($level = "warn") do={ :set evLevel "warn" }
      :if ($level = "crit") do={ :set evLevel "crit" }
      [$rhEventPublish name=("health." . $name) level=$evLevel module="health" text=($name . ": " . $curLevel . " -> " . $level . " (" . $text . ")")]
    }
  }

  :set ($checks->$name) $st
  :set ($rhHealthState->"checks") $checks
}

# args: value, warnAt, critAt - "higher is worse" (cpu load, ...)
:global rhHealthLevelHigh do={
  :if ($value >= $critAt) do={ :return "crit" }
  :if ($value >= $warnAt) do={ :return "warn" }
  :return "ok"
}

# args: value, warnBelow, critBelow - "lower is worse" (free memory %, ...)
:global rhHealthLevelLow do={
  :if ($value <= $critBelow) do={ :return "crit" }
  :if ($value <= $warnBelow) do={ :return "warn" }
  :return "ok"
}

:local resourceInfo [/system resource print as-value]

:local cpuLoad ($resourceInfo->"cpu-load")
:local cpuWarn [:tonum [$rhConfigGet key="health.cpu-warn" dflt="80"]]
:local cpuCrit [:tonum [$rhConfigGet key="health.cpu-crit" dflt="95"]]
[$rhHealthEval name="cpu" level=[$rhHealthLevelHigh value=$cpuLoad warnAt=$cpuWarn critAt=$cpuCrit] text=($cpuLoad . "%")]

:local freeMem ($resourceInfo->"free-memory")
:local totalMem ($resourceInfo->"total-memory")
:local memPct 100
:if ($totalMem > 0) do={ :set memPct (($freeMem * 100) / $totalMem) }
:local memWarn [:tonum [$rhConfigGet key="health.mem-warn" dflt="15"]]
:local memCrit [:tonum [$rhConfigGet key="health.mem-crit" dflt="5"]]
[$rhHealthEval name="memory" level=[$rhHealthLevelLow value=$memPct warnBelow=$memWarn critBelow=$memCrit] text=($memPct . "% free")]

:local freeDisk ($resourceInfo->"free-hdd-space")
:local totalDisk ($resourceInfo->"total-hdd-space")
:local diskPct 100
:if ($totalDisk > 0) do={ :set diskPct (($freeDisk * 100) / $totalDisk) }
:local diskWarn [:tonum [$rhConfigGet key="health.disk-warn" dflt="15"]]
:local diskCrit [:tonum [$rhConfigGet key="health.disk-crit" dflt="5"]]
[$rhHealthEval name="disk" level=[$rhHealthLevelLow value=$diskPct warnBelow=$diskWarn critBelow=$diskCrit] text=($diskPct . "% free")]

:local pingHosts [$rhConfigGet key="health.ping-hosts" dflt=""]
:if ($pingHosts != "") do={
  :local list [:toarray $pingHosts]
  :local anyOk 0
  :foreach h in=$list do={
    :local received 0
    :do { :set received [/ping $h count=2] } on-error={ :set received 0 }
    :if ($received > 0) do={ :set anyOk 1 }
  }
  :local pingLevel "crit"
  :if ($anyOk = 1) do={ :set pingLevel "ok" }
  [$rhHealthEval name="ping" level=$pingLevel text="configured ping targets"]
}

:local dnsHost [$rhConfigGet key="health.dns-check" dflt=""]
:if ($dnsHost != "") do={
  :local dnsLevel "ok"
  :do { [:resolve $dnsHost] } on-error={ :set dnsLevel "crit" }
  [$rhHealthEval name="dns" level=$dnsLevel text=("resolve " . $dnsHost)]
}

:local curUptime [:tonum ($resourceInfo->"uptime")]
:local lastUptime ($rhHealthState->"last-uptime")
:if ([:typeof $lastUptime] = "num" && $curUptime < $lastUptime) do={
  :set ($rhHealthState->"reboot-count") (($rhHealthState->"reboot-count") + 1)
  [$rhLog module="health" level="warn" text=("unexpected reboot detected, uptime reset to " . $curUptime . "s")]
  [$rhEventPublish name="health.reboot" level="warn" module="health" text="router rebooted"]
}
:set ($rhHealthState->"last-uptime") $curUptime

[$rhStateSave module="health" data=$rhHealthState]
