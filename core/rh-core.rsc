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

:global rhCoreVersion "0.1.0"

# ---- small helpers -----------------------------------------------------

:global rhNow do={
  :return ([/system clock get date] . " " . [/system clock get time])
}

# Splits a dotted version string ("7.25.1") into an array of numbers.
:global rhVerParts do={
  :local s $1
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
# buffer for tools like tg-control's future "/log" command. Not persisted to
# disk - it does not need to survive a reboot.

:global rhLogBuf [:toarray ""]
:global rhLogBufMax 200

# args: module, level (debug|info|warn|crit), text, data (optional)
:global rhLog do={
  :global rhLogBuf
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

# ---- rhEvent ---------------------------------------------------------------
# Simple publish/subscribe. A subscriber is the name of an already-installed
# RouterOS script (e.g. "rh-notify-onevent"), not a function - RouterOS has no
# reliable way to call a global function by a name held in a variable.
# rhEventPublish sets rhEv* globals and runs each subscriber script in turn;
# a subscriber (e.g. the notify module) is responsible for its own routing
# rules and de-duplication.

:global rhEventSubs [:toarray ""]
:global rhEvName ""
:global rhEvLevel ""
:global rhEvModule ""
:global rhEvText ""
:global rhEvData ""

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

  :set rhEvName $name
  :set rhEvLevel $level
  :set rhEvModule $module
  :set rhEvText $text
  :set rhEvData $dataVal

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
    /system script run ($installed->0)
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

# ---- startup ---------------------------------------------------------------

[$rhConfigLoad]
:set rhModules [$rhStateLoad module="core"]
[$rhLog module="core" level="info" text=("rh-core " . $rhCoreVersion . " loaded")]
