# RH:tg-control:rh-tg-control
# Telegram bot control: polls getUpdates every 10s (short poll, not a held
# connection - RouterOS has no background long-poll, so "long polling" here
# means "ask again on every scheduler tick"), accepts commands only from
# whitelisted chats, and requires typing "/confirm <token>" for anything
# dangerous rather than running it straight away.
#
# NEVER executes arbitrary text from chat - only the fixed commands handled
# below, plus whatever a module registers via rhTgRegisterCommand (run as
# its own script, same indirection as rhEvent - see rh-core's notes on why).
#
# Config (rhConfig): tg.whitelist = comma-separated chat ids allowed to use the bot.
# Secrets (rh-secrets): tg.token = bot token.

:global rhLog
:global rhConfigGet
:global rhSecretGet
:global rhStateLoad
:global rhStateSaveThrottled
:global rhPkgList
:global rhLogGet
:global rhNow
:global rhLockTry
:global rhLockRelease

# Guards against this scheduler's own next tick overlapping a run still stuck
# on a slow getUpdates fetch - see rh-core's rhLockTry for why this matters.
:if ([$rhLockTry name="tg-control" maxAgeSec=30] = 0) do={
  :error "previous run still in progress"
}

:global rhTgState
:global rhTgCommands

:if ([:typeof $rhTgState] = "nothing") do={
  :set rhTgState [$rhStateLoad module="tg-control"]
  :if ([:typeof ($rhTgState->"offset")] = "nothing") do={ :set ($rhTgState->"offset") 0 }
  :if ([:typeof ($rhTgState->"pending")] = "nothing") do={ :set ($rhTgState->"pending") [:toarray ""] }
}
:if ([:typeof $rhTgCommands] = "nothing") do={ :set rhTgCommands [:toarray ""] }

# For other modules to add a command later: args: name, script (a script run
# via "/system script run" when /<name> is sent, same convention as rhEvent).
:global rhTgRegisterCommand do={
  :global rhTgCommands
  :set ($rhTgCommands->$name) $script
}

:global rhTgApi do={
  :global rhSecretGet
  :local token [$rhSecretGet key="tg.token" dflt=""]
  :if ($token = "") do={ :error "tg.token not set in rh-secrets" }
  :local url ("https://api.telegram.org/bot" . $token . "/" . $apiMethod)
  :local r [/tool fetch url=$url http-method=post http-data=$body http-header-field="Content-Type: application/json" as-value output=user]
  :if (($r->"status") != "finished") do={ :error ("telegram api failed: " . ($r->"status")) }
  :local parsed [:deserialize from=json ($r->"data")]
  :if (($parsed->"ok") != true) do={ :error ("telegram api error: " . ($parsed->"description")) }
  :return ($parsed->"result")
}

# args: chatId, text
:global rhTgSend do={
  :global rhTgApi
  :global rhLog
  :local body [:serialize to=json ({"chat_id"=$chatId; "text"=$text})]
  :do {
    [$rhTgApi apiMethod="sendMessage" body=$body]
  } on-error={
    [$rhLog module="tg-control" level="warn" text=("could not send to chat " . $chatId)]
  }
}

:global rhTgIsWhitelisted do={
  :global rhConfigGet
  :local wl [$rhConfigGet key="tg.whitelist" dflt=""]
  :local list [:toarray $wl]
  :local ok 0
  :foreach w in=$list do={
    :if ($w = [:tostr $chatId]) do={ :set ok 1 }
  }
  :return $ok
}

:global rhTgBuiltinStatus do={
  :global rhNow
  :local res [/system resource print as-value]
  :return ("ROSHub @ " . [$rhNow] . "\ncpu: " . ($res->"cpu-load") . "%\nfree mem: " . ($res->"free-memory") . "\nuptime: " . ($res->"uptime"))
}

:global rhTgBuiltinModules do={
  :global rhPkgList
  :local mods [$rhPkgList]
  :local out "modules:"
  :foreach name,rec in=$mods do={
    :set out ($out . "\n" . $name . " " . ($rec->"version"))
  }
  :return $out
}

:global rhTgBuiltinLog do={
  :global rhLogGet
  :local entries [$rhLogGet limit=10]
  :local out "last log entries:"
  :foreach e in=$entries do={
    :set out ($out . "\n[" . ($e->"level") . "] " . ($e->"module") . ": " . ($e->"text"))
  }
  :return $out
}

:global rhTgBuiltinHelp do={
  :global rhTgCommands
  :local out "/status /modules /log /help /reboot (needs /confirm)"
  :foreach name,script in=$rhTgCommands do={
    :set out ($out . " /" . $name)
  }
  :return $out
}

# Commands that must be confirmed before running - matched against the
# command name (without the leading "/").
:global rhTgDangerous {"reboot"}

:global rhTgIsDangerous do={
  :global rhTgDangerous
  :local found 0
  :foreach d in=$rhTgDangerous do={
    :if ($d = $cmd) do={ :set found 1 }
  }
  :return $found
}

# args: chatId, cmd - runs a confirmed dangerous command by name
:global rhTgRunConfirmed do={
  :global rhLog
  :global rhTgSend
  :if ($cmd = "reboot") do={
    [$rhLog module="tg-control" level="crit" text=("reboot confirmed via chat " . $chatId)]
    [$rhTgSend chatId=$chatId text="rebooting now"]
    /system reboot
  }
}

# args: chatId, fromId, text
:global rhTgHandleUpdate do={
  :global rhLog
  :global rhTgIsWhitelisted
  :global rhTgState
  :global rhTgCommands
  :global rhTgIsDangerous
  :global rhTgRunConfirmed
  :global rhTgSend
  :global rhTgBuiltinStatus
  :global rhTgBuiltinModules
  :global rhTgBuiltinLog
  :global rhTgBuiltinHelp

  :if ([$rhTgIsWhitelisted chatId=$chatId] = 0) do={
    [$rhLog module="tg-control" level="warn" text=("ignored message from non-whitelisted chat " . $chatId)]
    :return ""
  }
  :if ([:pick $text 0 1] != "/") do={ :return "" }

  :local spacePos [:find $text " "]
  :local cmd ""
  :local arg ""
  :if ([:typeof $spacePos] = "nil") do={
    :set cmd [:pick $text 1 [:len $text]]
  } else={
    :set cmd [:pick $text 1 $spacePos]
    :set arg [:pick $text ($spacePos + 1) [:len $text]]
  }
  :local atPos [:find $cmd "@"]
  :if ([:typeof $atPos] != "nil") do={ :set cmd [:pick $cmd 0 $atPos] }

  # Chained as if/else-if (not a sequence of early ":return"s) because ":return"
  # inside a one-line ":if (...) do={ stmt1 :return "" }" block (no ";" between
  # statements) does not actually exit the function - both that reply and the
  # final "unknown command" fallback ended up firing for every single message.
  :local script ($rhTgCommands->$cmd)
  :if ($cmd = "confirm") do={
    :global rhTgRunConfirmed
    :local pending ($rhTgState->"pending")
    :local chatKey [:tostr $chatId]
    :local entry ($pending->$chatKey)
    :local nowUptime [:tonum [/system resource get uptime]]
    :if ([:typeof $entry] != "nothing" && ($entry->"token") = $arg && $nowUptime <= ($entry->"expires")) do={
      :local dcmd ($entry->"cmd")
      :local newPending [:toarray ""]
      :foreach k,v in=$pending do={
        :if ($k != $chatKey) do={ :set ($newPending->$k) $v }
      }
      :set pending $newPending
      :set ($rhTgState->"pending") $pending
      [$rhTgRunConfirmed chatId=$chatId cmd=$dcmd]
    } else={
      [$rhTgSend chatId=$chatId text="no matching pending confirmation"]
    }
  } else={
    :if ($cmd = "status") do={
      [$rhTgSend chatId=$chatId text=[$rhTgBuiltinStatus]]
    } else={
      :if ($cmd = "modules") do={
        [$rhTgSend chatId=$chatId text=[$rhTgBuiltinModules]]
      } else={
        :if ($cmd = "log") do={
          [$rhTgSend chatId=$chatId text=[$rhTgBuiltinLog]]
        } else={
          :if ($cmd = "help") do={
            [$rhTgSend chatId=$chatId text=[$rhTgBuiltinHelp]]
          } else={
            :if ([$rhTgIsDangerous cmd=$cmd] = 1) do={
              :local tok [:tostr (([/system clock get time] . [:tostr $chatId]))]
              :local nowUptime [:tonum [/system resource get uptime]]
              :local pending ($rhTgState->"pending")
              :local entry [:toarray ""]
              :set ($entry->"cmd") $cmd
              :set ($entry->"token") $tok
              :set ($entry->"expires") ($nowUptime + 60)
              :set ($pending->[:tostr $chatId]) $entry
              :set ($rhTgState->"pending") $pending
              [$rhTgSend chatId=$chatId text=("type /confirm " . $tok . " within a minute to run /" . $cmd)]
            } else={
              :if ([:typeof $script] != "nothing") do={
                :do {
                  /system script run $script
                } on-error={
                  [$rhTgSend chatId=$chatId text=("/" . $cmd . " failed")]
                }
              } else={
                [$rhTgSend chatId=$chatId text=("unknown command: /" . $cmd)]
              }
            }
          }
        }
      }
    }
  }
}

# offset is tracked directly on the (global) rhTgState map rather than a
# plain :local, because ":set" to an outer :local from inside a ":do{}"
# block does not propagate back out - it silently mutates a scoped copy,
# which otherwise left this offset permanently stuck after the first poll.
:do {
  :local url ("https://api.telegram.org/bot" . [$rhSecretGet key="tg.token" dflt=""] . "/getUpdates?offset=" . ($rhTgState->"offset") . "&timeout=0")
  :local r [/tool fetch url=$url as-value output=user]
  :if (($r->"status") = "finished") do={
    :local parsed [:deserialize from=json ($r->"data")]
    :if (($parsed->"ok") = true) do={
      :local results ($parsed->"result")
      :foreach upd in=$results do={
        :local updId ($upd->"update_id")
        :if ($updId >= ($rhTgState->"offset")) do={ :set ($rhTgState->"offset") ($updId + 1) }
        :local msg ($upd->"message")
        :if ([:typeof $msg] != "nothing") do={
          :local chat ($msg->"chat")
          :local from ($msg->"from")
          :local text ($msg->"text")
          :if ([:typeof $text] = "nothing") do={ :set text "" }
          [$rhTgHandleUpdate chatId=($chat->"id") fromId=($from->"id") text=$text]
        }
      }
    }
  }
} on-error={
  [$rhLog module="tg-control" level="debug" text="getUpdates failed (no token yet?)"]
}

[$rhStateSaveThrottled module="tg-control" data=$rhTgState minIntervalSec=60]
[$rhLockRelease name="tg-control"]
