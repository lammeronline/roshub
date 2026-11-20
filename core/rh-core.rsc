# RH:core:rh-core
# ROSHub core loader. Installed as RouterOS script "rh-core", run at startup by
# scheduler "rh-core" (start-time=startup) and safe to re-run manually at any time:
# it only (re)declares global functions and reloads config/state from disk.
#
# Naming convention: every object this project creates on the router is prefixed
# "rh-" (scripts, schedulers) or "rh" (global variables), with comments "RH:<module>:<what>".
# A module never calls another module directly, only these core functions.
#
# Caveat worth keeping in mind when touching this file: ":local x $x" (declaring a
# local with the same name as an already-bound variable, including a function's own
# named argument) always evaluates the right-hand side against the *new* binding, so
# it reads back "nothing"/the local's own value, not the original. Anywhere a default
# is needed, the incoming value is first captured under a different local name.

:global rhCoreVersion "0.1.10"

# ---- small helpers -----------------------------------------------------

:global rhNow do={
  :return ([/system clock get date] . " " . [/system clock get time])
}

# Re-entrancy guard for a scheduled module script that can be slow (a network
# call, a /ping with its own timeout) and so might still be running when its
# own scheduler fires again - RouterOS does not serialize scheduled script
# runs against each other. A stale lock (left behind by a run that crashed
# before releasing it) expires after maxAgeSec so a module never gets stuck
# locked out of itself.
:global rhLocks
:if ([:typeof $rhLocks] = "nothing") do={ :set rhLocks [:toarray ""] }

# args: name, maxAgeSec (optional, default 120) - returns 1 if acquired, 0 if
# already held by a still-fresh lock
:global rhLockTry do={
  :global rhLocks
  :local maxAgeVal $maxAgeSec
  :if ([:typeof $maxAgeVal] = "nothing") do={ :set maxAgeVal 120 }
  :local now [:tonum [/system resource get uptime]]
  :local held ($rhLocks->$name)
  :if ([:typeof $held] != "nothing" && $held > 0 && ($now - $held) < $maxAgeVal) do={
    :return 0
  }
  :set ($rhLocks->$name) $now
  :return 1
}

# args: name
:global rhLockRelease do={
  :global rhLocks
  :set ($rhLocks->$name) 0
}

# Splits a dotted version string ("7.25.1" or "v7.25.1") into an array of
# numbers. The "v" prefix is accepted (and expected from JSON: RouterOS's
# JSON parser silently mangles a bare dotted-number string into an IP-address
# value, e.g. "0.1.0" -> "0.1.0.0", so every version in manifest.json/
# module.json is written as "v0.1.0" to avoid that).
:global rhVerParts do={
  :local s $1
  :if ([:len $s] > 0 && ([:pick $s 0 1] = "v" || [:pick $s 0 1] = "V")) do={
    :set s [:pick $s 1 [:len $s]]
  }
  :local parts [:toarray ""]
  :local cur ""
  :local i 0
  :local n [:len $s]
  :while ($i < $n) do={
    :local c [:pick $s $i ($i + 1)]
    :if ($c = ".") do={
      :set parts ($parts , [:tonum $cur])
      :set cur ""
    } else={
      :set cur ($cur . $c)
    }
    :set i ($i + 1)
  }
  :set parts ($parts , [:tonum $cur])
  :return $parts
}

# Compares two dotted version strings. Returns -1, 0 or 1.
:global rhVerCmp do={
  :local a [$rhVerParts $1]
  :local b [$rhVerParts $2]
  :local n [:len $a]
  :if ([:len $b] > $n) do={ :set n [:len $b] }
  :local i 0
  :local result 0
  :while ($i < $n) do={
    :local av 0
    :local bv 0
    :if ($i < [:len $a]) do={ :set av ($a->$i) }
    :if ($i < [:len $b]) do={ :set bv ($b->$i) }
    :if ($result = 0) do={
      :if ($av > $bv) do={ :set result 1 }
      :if ($av < $bv) do={ :set result -1 }
    }
    :set i ($i + 1)
  }
  :return $result
}

# ---- rhLog --------------------------------------------------------------
# Levels: debug, info, warn, crit. Writes to /log (RouterOS has no "critical"
# add-command, so crit is logged as error) and keeps a small in-memory ring
# buffer for tools like tg-control's "/log" command. Not persisted to disk -
# it does not need to survive a reboot, but it also should not survive a
# same-uptime core re-run (rhPkgUpdate/rhPkgInstall of core itself) any less
# than rhEventSubs/rhLocks/rhEvSeq do, for the same reason.
:global rhLogBuf
:if ([:typeof $rhLogBuf] = "nothing") do={ :set rhLogBuf [:toarray ""] }
:global rhLogBufMax 200

# args: module, level (debug|info|warn|crit), text, data (optional)
:global rhLog do={
  :global rhLogBuf
  :local moduleVal $module
  :local levelVal $level
  :local textVal $text
  :if ([:typeof $moduleVal] = "nothing" || [:typeof $levelVal] = "nothing" || [:typeof $textVal] = "nothing") do={
    :return ""
  }
  :local dataVal $data
  :if ([:typeof $dataVal] = "nothing") do={ :set dataVal "" }

  :local minLevel [$rhConfigGet key="core.log-level" dflt="info"]
  :local levelNum {"debug"=0; "info"=1; "warn"=2; "crit"=3}
  :local lvlN ($levelNum->$level)
  :local minN ($levelNum->$minLevel)
  :if ([:typeof $lvlN] = "nothing") do={ :set lvlN 1 }
  :if ([:typeof $minN] = "nothing") do={ :set minN 1 }

  :if ($lvlN >= $minN) do={
    :local line ("RH:" . $module . ": " . $text)
    :if ($level = "debug") do={ /log debug $line }
    :if ($level = "info") do={ /log info $line }
    :if ($level = "warn") do={ /log warning $line }
    :if ($level = "crit") do={ /log error $line }
  }

  :local entry [:toarray ""]
  :set ($entry->"time") [$rhNow]
  :set ($entry->"module") $module
  :set ($entry->"level") $level
  :set ($entry->"text") $text
  :set ($entry->"data") $dataVal
  :set ($rhLogBuf->[:len $rhLogBuf]) $entry
  :while ([:len $rhLogBuf] > $rhLogBufMax) do={
    :local trimmed [:toarray ""]
    :local i 1
    :while ($i < [:len $rhLogBuf]) do={
      :set ($trimmed->[:len $trimmed]) ($rhLogBuf->$i)
      :set i ($i + 1)
    }
    :set rhLogBuf $trimmed
  }
}

# Returns up to "limit" most recent log entries (default/negative: all buffered).
:global rhLogGet do={
  :local n [:len $rhLogBuf]
  :local limitVal $limit
  :if ([:typeof $limitVal] = "nothing" || $limitVal < 0 || $limitVal > $n) do={
    :set limitVal $n
  }
  :local start ($n - $limitVal)
  :local out [:toarray ""]
  :local i $start
  :while ($i < $n) do={
    :set ($out->[:len $out]) ($rhLogBuf->$i)
    :set i ($i + 1)
  }
  :return $out
}

# ---- rhConfig ------------------------------------------------------------
# Flat key/value settings (not secret), persisted to file rh-config.json.

:global rhConfig [:toarray ""]
:global rhConfigFile "rh-config.json"

:global rhConfigLoad do={
  :global rhConfig
  :local f [/file find name=$rhConfigFile]
  :if ([:len $f] > 0) do={
    :set rhConfig [:deserialize from=json ([/file get $f contents])]
  } else={
    :set rhConfig [:toarray ""]
  }
}

:global rhConfigSave do={
  :local json [:serialize to=json $rhConfig]
  :local f [/file find name=$rhConfigFile]
  :if ([:len $f] > 0) do={
    /file set $f contents=$json
  } else={
    /file add name=$rhConfigFile contents=$json
  }
}

# args: key, dflt (optional)
:global rhConfigGet do={
  :local dfltVal $dflt
  :if ([:typeof $dfltVal] = "nothing") do={ :set dfltVal "" }
  :local v ($rhConfig->$key)
  :if ([:typeof $v] = "nothing") do={ :return $dfltVal }
  :return $v
}

# args: key, value
:global rhConfigSet do={
  :global rhConfig
  :local cfg $rhConfig
  :set ($cfg->$key) $value
  :set rhConfig $cfg
  [$rhConfigSave]
}

# ---- rhSecret ------------------------------------------------------------
# Secrets (bot tokens, passwords) live only on the router, in a script named
# "rh-secrets" that the admin creates by hand and that is never fetched by
# rhPkg or committed to the repo. It is expected to set :global rhSecrets to
# a flat key/value map and must be run once (e.g. from startup, before
# rh-core, or manually) so the global exists.

# args: key, dflt (optional)
:global rhSecretGet do={
  :local dfltVal $dflt
  :if ([:typeof $dfltVal] = "nothing") do={ :set dfltVal "" }
  :global rhSecrets
  :if ([:typeof $rhSecrets] = "nothing") do={
    [$rhLog module="core" level="debug" text=("rh-secrets not loaded, no value for " . $key)]
    :return $dfltVal
  }
  :local v ($rhSecrets->$key)
  :if ([:typeof $v] = "nothing") do={ :return $dfltVal }
  :return $v
}

# ---- rhState ---------------------------------------------------------------
# Per-module state, persisted to rh-state-<module>.json. Modules are expected
# to call rhStateSave in batches (e.g. from their own scheduler, every few
# minutes) rather than on every change, to limit flash writes.

# args: module
:global rhStateLoad do={
  :local fname ("rh-state-" . $module . ".json")
  :local f [/file find name=$fname]
  :if ([:len $f] > 0) do={
    :return [:deserialize from=json ([/file get $f contents])]
  }
  :return [:toarray ""]
}

# args: module, data
:global rhStateSave do={
  :local fname ("rh-state-" . $module . ".json")
  :local json [:serialize to=json $data]
  :local f [/file find name=$fname]
  :if ([:len $f] > 0) do={
    /file set $f contents=$json
  } else={
    /file add name=$fname contents=$json
  }
}

# A module with a fast scheduler (tg-control every 10s, wg every 30s) calling
# rhStateSave unconditionally on every tick writes to flash far more often
# than the data actually needs to survive a crash for - thousands of writes a
# day, which matters for flash wear on a router left running for years.
# Writes at most once per minIntervalSec per module, tracked in memory (not
# persisted, not reset on a core re-run - same reasoning as rhEventSubs).
# args: module, data, minIntervalSec (optional, default 60), force (optional,
# 1 to bypass the throttle - e.g. a module's own state transition worth
# persisting immediately rather than losing up to minIntervalSec of it)
:global rhStateSaveLast
:if ([:typeof $rhStateSaveLast] = "nothing") do={ :set rhStateSaveLast [:toarray ""] }

:global rhStateSaveThrottled do={
  :global rhStateSaveLast
  :global rhStateSave
  :local minInterval $minIntervalSec
  :if ([:typeof $minInterval] = "nothing") do={ :set minInterval 60 }
  :local forceVal $force
  :if ([:typeof $forceVal] = "nothing") do={ :set forceVal 0 }
  :local now [:tonum [/system resource get uptime]]
  :local last ($rhStateSaveLast->$module)
  :if ($forceVal = 0 && [:typeof $last] != "nothing" && ($now - $last) < $minInterval) do={
    :return ""
  }
  [$rhStateSave module=$module data=$data]
  :set ($rhStateSaveLast->$module) $now
}

# ---- rhEvent ---------------------------------------------------------------
# Simple publish/subscribe. A subscriber is the name of an already-installed
# RouterOS script (e.g. "rh-notify-onevent"), not a function - RouterOS has no
# reliable way to call a global function by a name held in a variable.
# rhEventPublish sets rhEv* globals and runs each subscriber script in turn;
# a subscriber (e.g. the notify module) is responsible for its own routing
# rules and de-duplication.

#   Not reset on a core re-run (e.g. rhPkgUpdate/rhPkgInstall of core itself) -
#   only cleared on an actual reboot - otherwise every subscriber would go
#   deaf until its own scheduler happened to re-subscribe it.
:global rhEventSubs
:if ([:typeof $rhEventSubs] = "nothing") do={ :set rhEventSubs [:toarray ""] }
:global rhEvName ""
:global rhEvLevel ""
:global rhEvModule ""
:global rhEvText ""
:global rhEvData ""
# Bumped by every rhEventPublish, never reset on a core re-run (same reasoning
# as rhEventSubs above). A subscriber script's body runs unconditionally
# whenever it is run at all - by rhEventPublish's own dispatch, by its own
# periodic scheduler, or by a manual re-run - so without a sequence number to
# compare against, it has no way to tell "a fresh event just happened" from
# "I'm just being re-run with whatever rhEv* happened to be set last time" -
# which, right after a core reload, is "" for everything, and was confirmed on
# the CHR stand to reach Telegram as a blank "[] : " message.
:global rhEvSeq
:if ([:typeof $rhEvSeq] = "nothing") do={ :set rhEvSeq 0 }

# args: script
:global rhEventSubscribe do={
  :global rhEventSubs
  :local already 0
  :foreach h in=$rhEventSubs do={
    :if ($h = $script) do={ :set already 1 }
  }
  :if ($already = 0) do={
    :set rhEventSubs ($rhEventSubs , $script)
  }
}

# args: name, level, module, text, data (optional)
:global rhEventPublish do={
  :global rhEventSubs
  :global rhEvName
  :global rhEvLevel
  :global rhEvModule
  :global rhEvText
  :global rhEvData
  :local dataVal $data
  :if ([:typeof $dataVal] = "nothing") do={ :set dataVal "" }

  [$rhLog module=$module level=$level text=$text data=$dataVal]

  :global rhEvSeq
  :set rhEvName $name
  :set rhEvLevel $level
  :set rhEvModule $module
  :set rhEvText $text
  :set rhEvData $dataVal
  :set rhEvSeq ($rhEvSeq + 1)

  :foreach h in=$rhEventSubs do={
    :do {
      /system script run $h
    } on-error={
      [$rhLog module="core" level="warn" text=("event handler " . $h . " failed")]
    }
  }
}

# ---- rhPkg -----------------------------------------------------------------
# Installs/removes modules fetched from GitHub. manifest.json (always read
# from the "main" branch - it is just an index) lists, per module, the
# release tag to install from. Module code itself is only ever fetched from
# that tag, never from main, so a half-finished commit can't reach a router.

:global rhModules [:toarray ""]

# args: url
:global rhPkgFetch do={
  :local r [/tool fetch url=$url output=user as-value]
  :if (($r->"status") != "finished") do={
    :error ("fetch failed: " . $url)
  }
  :return ($r->"data")
}

:global rhPkgManifest do={
  :local repo [$rhConfigGet key="core.repo" dflt="lammeronline/roshub"]
  :local url ("https://raw.githubusercontent.com/" . $repo . "/main/manifest.json")
  :return [:deserialize from=json ([$rhPkgFetch url=$url])]
}

# args: module
:global rhPkgInstall do={
  :global rhModules
  :local repo [$rhConfigGet key="core.repo" dflt="lammeronline/roshub"]
  :local manifest [$rhPkgManifest]
  :local modules ($manifest->"modules")
  :local entry ($modules->$module)
  :if ([:typeof $entry] = "nothing") do={
    [$rhLog module="core" level="warn" text=("unknown module: " . $module)]
    :error ("unknown module: " . $module)
  }
  :local tag ($entry->"tag")
  :local base ("https://raw.githubusercontent.com/" . $repo . "/" . $tag . "/modules/" . $module . "/")

  :local mjson [:deserialize from=json ([$rhPkgFetch url=($base . "module.json")])]
  :local minRouteros ($mjson->"min_routeros")
  :if ([:typeof $minRouteros] != "nothing") do={
    :local cur [/system resource get version]
    :if ([$rhVerCmp $cur $minRouteros] < 0) do={
      [$rhLog module="core" level="crit" text=($module . " needs RouterOS >= " . $minRouteros . ", have " . $cur)]
      :error "routeros too old"
    }
  }
  :local minCore ($mjson->"min_core")
  :if ([:typeof $minCore] != "nothing") do={
    :if ([$rhVerCmp $rhCoreVersion $minCore] < 0) do={
      [$rhLog module="core" level="crit" text=($module . " needs rh-core >= " . $minCore . ", have " . $rhCoreVersion)]
      :error "core too old"
    }
  }

  :local files ($mjson->"files")
  :local installed [:toarray ""]
  :foreach file in=$files do={
    :local content [$rhPkgFetch url=($base . $file)]
    :local scriptName [:pick $file 0 ([:len $file] - 4)]
    :if ([:len [/system script find name=$scriptName]] > 0) do={
      /system script set [find name=$scriptName] source=$content comment=("RH:" . $module . ":" . $scriptName)
    } else={
      /system script add name=$scriptName source=$content comment=("RH:" . $module . ":" . $scriptName)
    }
    :set installed ($installed , $scriptName)
  }

  :local sched ($mjson->"scheduler")
  :if ([:typeof $sched] != "nothing") do={
    :local mainName ($installed->0)
    :local interval ($sched->"interval")
    :local startTime ($sched->"start-time")
    :if ([:typeof $startTime] = "nothing") do={ :set startTime "startup" }
    :if ([:len [/system scheduler find name=$mainName]] > 0) do={
      /system scheduler set [find name=$mainName] interval=$interval start-time=$startTime on-event=("/system script run " . $mainName)
    } else={
      /system scheduler add name=$mainName interval=$interval start-time=$startTime on-event=("/system script run " . $mainName)
    }
  }

  :local rec [:toarray ""]
  :set ($rec->"version") ($mjson->"version")
  :set ($rec->"tag") $tag
  :set ($rec->"files") $installed
  :set ($rec->"installed-at") [$rhNow]
  :local mods $rhModules
  :set ($mods->$module) $rec
  :set rhModules $mods
  [$rhStateSave module="core" data=$rhModules]

  :if ([:len $installed] > 0) do={
    :do {
      /system script run ($installed->0)
    } on-error={
      [$rhLog module="core" level="warn" text=($module . " installed but its first run failed (likely needs config/secrets)")]
    }
  }

  [$rhEventPublish name="core.module.installed" level="info" module="core" text=($module . " " . ($mjson->"version") . " installed")]
}

# args: module
:global rhPkgRemove do={
  :global rhModules
  :local rec ($rhModules->$module)
  :if ([:typeof $rec] = "nothing") do={
    [$rhLog module="core" level="warn" text=("module not installed: " . $module)]
    :error ("module not installed: " . $module)
  }
  :local prefix ("rh-" . $module)
  /system scheduler remove [find name~("^" . $prefix . "(-|\$)")]
  /system script remove [find name~("^" . $prefix . "(-|\$)")]

  :local newModules [:toarray ""]
  :foreach name,val in=$rhModules do={
    :if ($name != $module) do={ :set ($newModules->$name) $val }
  }
  :set rhModules $newModules
  [$rhStateSave module="core" data=$rhModules]

  [$rhEventPublish name="core.module.removed" level="info" module="core" text=($module . " removed")]
}

:global rhPkgList do={
  :return $rhModules
}

# Compares installed versions (core + every installed module) against
# manifest.json on main, and publishes core.update.available once per call
# for anything newer - no state of its own, so it is safe to call as often
# or as rarely as wanted (manually, from tg-control, or from a scheduler).
:global rhPkgCheck do={
  :global rhModules
  :global rhCoreVersion
  :local manifest [$rhPkgManifest]
  :local mods ($manifest->"modules")
  :foreach name,rec in=$rhModules do={
    :local avail ($mods->$name)
    :if ([:typeof $avail] != "nothing") do={
      :if ([$rhVerCmp ($avail->"version") ($rec->"version")] > 0) do={
        [$rhEventPublish name="core.update.available" level="info" module="core" text=($name . ": " . ($rec->"version") . " -> " . ($avail->"version"))]
      }
    }
  }
  :local coreAvail ($manifest->"core")
  :if ([:typeof $coreAvail] != "nothing") do={
    :if ([$rhVerCmp ($coreAvail->"version") $rhCoreVersion] > 0) do={
      [$rhEventPublish name="core.update.available" level="info" module="core" text=("core: " . $rhCoreVersion . " -> " . ($coreAvail->"version"))]
    }
  }
}

# Backs up every installed file of a module to "<file>.bak" (a second
# /system script object, not a file - no extra /file writes), then installs
# it again, which naturally pulls whatever tag manifest.json points at now.
# args: module
:global rhPkgUpdate do={
  :global rhModules
  :local rec ($rhModules->$module)
  :if ([:typeof $rec] = "nothing") do={
    [$rhLog module="core" level="warn" text=("module not installed: " . $module)]
    :error ("module not installed: " . $module)
  }
  :foreach f in=($rec->"files") do={
    :if ([:len [/system script find name=$f]] > 0) do={
      :local src [/system script get [find name=$f] source]
      :local bakName ($f . ".bak")
      :if ([:len [/system script find name=$bakName]] > 0) do={
        /system script set [find name=$bakName] source=$src
      } else={
        /system script add name=$bakName source=$src comment=("RH:" . $module . ":backup")
      }
    }
  }
  [$rhPkgInstall module=$module]
}

# Restores every installed file of a module from its "<file>.bak" backup
# (made by the last rhPkgUpdate) without re-fetching anything from GitHub.
# args: module
:global rhPkgRollback do={
  :global rhModules
  :local rec ($rhModules->$module)
  :if ([:typeof $rec] = "nothing") do={
    [$rhLog module="core" level="warn" text=("module not installed: " . $module)]
    :error ("module not installed: " . $module)
  }
  :foreach f in=($rec->"files") do={
    :local bakName ($f . ".bak")
    :if ([:len [/system script find name=$bakName]] > 0) do={
      :local src [/system script get [find name=$bakName] source]
      /system script set [find name=$f] source=$src
    } else={
      [$rhLog module="core" level="warn" text=("no backup for " . $f . ", skipped")]
    }
  }
  [$rhLog module="core" level="warn" text=($module . " rolled back")]
}

# ---- startup ---------------------------------------------------------------

[$rhConfigLoad]
:set rhModules [$rhStateLoad module="core"]
[$rhLog module="core" level="info" text=("rh-core " . $rhCoreVersion . " loaded")]
