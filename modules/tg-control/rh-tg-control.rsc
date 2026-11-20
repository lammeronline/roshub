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

# The persistent inline keyboard attached to every built-in reply/view, so a
# chat that only ever taps buttons never needs to type a command at all.
# "reboot" is a real control action, not a read-only view (see rhTgViewNames
# below) - tapping it still goes through the normal /confirm flow, a button
# can start that but never skip it.
:global rhTgMenuMarkup do={
  :return [:serialize to=json ({"inline_keyboard"={
    {{"text"="📊 Status"; "callback_data"="status"}; {"text"="📦 Modules"; "callback_data"="modules"}};
    {{"text"="📜 Log"; "callback_data"="log"}; {"text"="❓ Help"; "callback_data"="help"}};
    {{"text"="🔄 Check updates"; "callback_data"="check-updates"}; {"text"="⬆️ Apply updates"; "callback_data"="apply-updates"}};
    {{"text"="♻️ Reboot"; "callback_data"="reboot"}}
  }})]
}

# args: chatId, text, markup (optional JSON string, e.g. rhTgMenuMarkup)
:global rhTgSend do={
  :global rhTgApi
  :global rhLog
  :local payload ({"chat_id"=$chatId; "text"=$text; "parse_mode"="HTML"})
  :local markupVal $markup
  :if ([:typeof $markupVal] != "nothing" && $markupVal != "") do={
    :set ($payload->"reply_markup") [:deserialize from=json $markupVal]
  }
  :local body [:serialize to=json $payload]
  :do {
    [$rhTgApi apiMethod="sendMessage" body=$body]
  } on-error={
    [$rhLog module="tg-control" level="warn" text=("could not send to chat " . $chatId)]
  }
}

# args: chatId, messageId, text, markup (optional) - rewrites an existing
# message in place (used for button taps) instead of sending a new one, so
# tapping through Status/Modules/Log/Help/Menu updates one card rather than
# spamming a fresh message per tap.
:global rhTgEditMessage do={
  :global rhTgApi
  :global rhLog
  :local payload ({"chat_id"=$chatId; "message_id"=$messageId; "text"=$text; "parse_mode"="HTML"})
  :local markupVal $markup
  :if ([:typeof $markupVal] != "nothing" && $markupVal != "") do={
    :set ($payload->"reply_markup") [:deserialize from=json $markupVal]
  }
  :local body [:serialize to=json $payload]
  :do {
    [$rhTgApi apiMethod="editMessageText" body=$body]
  } on-error={
    [$rhLog module="tg-control" level="warn" text=("could not edit message in chat " . $chatId)]
  }
}

# args: id (callback_query_id) - clears the loading spinner on the tapped button
:global rhTgAnswerCallback do={
  :global rhTgApi
  :local body [:serialize to=json ({"callback_query_id"=$id})]
  :do {
    [$rhTgApi apiMethod="answerCallbackQuery" body=$body]
  } on-error={ }
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
  :global rhRouterName
  :local res [/system resource print as-value]
  :return ("🖥 <b>" . [$rhRouterName] . "</b>\n" . [$rhNow] . "\n\ncpu: <code>" . ($res->"cpu-load") . "%</code>\nfree mem: <code>" . ($res->"free-memory") . "</code>\nuptime: <code>" . ($res->"uptime") . "</code>")
}

:global rhTgBuiltinModules do={
  :global rhPkgList
  :local mods [$rhPkgList]
  :local out "📦 <b>Installed modules</b>"
  :foreach name,rec in=$mods do={
    :set out ($out . "\n• " . $name . " — <code>" . ($rec->"version") . "</code>")
  }
  :if ([:len $mods] = 0) do={ :set out ($out . "\n<i>none installed</i>") }
  :return $out
}

:global rhTgBuiltinLog do={
  :global rhLogGet
  :local entries [$rhLogGet limit=10]
  :local out "📜 <b>Last log entries</b>"
  :foreach e in=$entries do={
    :set out ($out . "\n<code>[" . ($e->"level") . "]</code> " . ($e->"module") . ": " . ($e->"text"))
  }
  :if ([:len $entries] = 0) do={ :set out ($out . "\n<i>empty</i>") }
  :return $out
}

:global rhTgBuiltinHelp do={
  :global rhTgCommands
  :local out "❓ <b>Commands</b>\n/status /modules /log /help /menu /check-updates /apply-updates /reboot (needs /confirm)"
  :foreach name,script in=$rhTgCommands do={
    :set out ($out . " /" . $name)
  }
  :return $out
}

# Diffs installed module (and core) versions against manifest.json, as text
# for the chat - a read-only view of exactly what rhPkgCheck would publish
# events for, without needing to go dig through /log for those events.
:global rhTgBuiltinCheckUpdates do={
  :global rhPkgList
  :global rhPkgManifest
  :global rhVerCmp
  :global rhCoreVersion
  :local mods [$rhPkgList]
  :local manifest [$rhPkgManifest]
  :local availMods ($manifest->"modules")
  :local out "🔄 <b>Update check</b>"
  :local anyUpdate 0
  :foreach name,rec in=$mods do={
    :local avail ($availMods->$name)
    :if ([:typeof $avail] != "nothing" && [$rhVerCmp ($avail->"version") ($rec->"version")] > 0) do={
      :set out ($out . "\n⬆️ " . $name . ": <code>" . ($rec->"version") . "</code> → <code>" . ($avail->"version") . "</code>")
      :set anyUpdate 1
    }
  }
  :local coreAvail ($manifest->"core")
  :if ([:typeof $coreAvail] != "nothing" && [$rhVerCmp ($coreAvail->"version") $rhCoreVersion] > 0) do={
    :set out ($out . "\n⬆️ core: <code>v" . $rhCoreVersion . "</code> → <code>" . ($coreAvail->"version") . "</code>")
    :set anyUpdate 1
  }
  :if ($anyUpdate = 0) do={ :set out ($out . "\n✅ everything up to date") }
  :return $out
}

# Actually installs whatever rhTgBuiltinCheckUpdates would list (modules
# only - a core update still needs bootstrap.rsc run by hand, see its own
# line below). Each rhPkgUpdate backs the module's files up to a ".bak"
# script first, so a bad update can still be walked back with rhPkgRollback.
:global rhTgBuiltinApplyUpdates do={
  :global rhPkgList
  :global rhPkgManifest
  :global rhVerCmp
  :global rhCoreVersion
  :global rhPkgUpdate
  :local mods [$rhPkgList]
  :local manifest [$rhPkgManifest]
  :local availMods ($manifest->"modules")
  :local out "⬆️ <b>Applying updates</b>"
  :local any 0
  :foreach name,rec in=$mods do={
    :local avail ($availMods->$name)
    :if ([:typeof $avail] != "nothing" && [$rhVerCmp ($avail->"version") ($rec->"version")] > 0) do={
      :set any 1
      :do {
        [$rhPkgUpdate module=$name]
        :set out ($out . "\n✅ " . $name . " → <code>" . ($avail->"version") . "</code>")
      } on-error={
        :set out ($out . "\n❌ " . $name . " failed - see /log")
      }
    }
  }
  :local coreAvail ($manifest->"core")
  :if ([:typeof $coreAvail] != "nothing" && [$rhVerCmp ($coreAvail->"version") $rhCoreVersion] > 0) do={
    :set out ($out . "\nℹ️ core <code>v" . $rhCoreVersion . "</code> → <code>" . ($coreAvail->"version") . "</code> available - re-run bootstrap.rsc by hand to apply")
    :set any 1
  }
  :if ($any = 0) do={ :set out ($out . "\n✅ nothing to update") }
  :return $out
}

# Read-only views renderable both as a fresh message (typed command) and as
# an in-place edit of the menu card (button tap) - kept in one place so the
# two code paths can't drift apart on which names are "safe" to show without
# running anything. args: view
:global rhTgRenderView do={
  :global rhTgBuiltinStatus
  :global rhTgBuiltinModules
  :global rhTgBuiltinLog
  :global rhTgBuiltinHelp
  :global rhTgBuiltinCheckUpdates
  :if ($view = "status") do={ :return [$rhTgBuiltinStatus] }
  :if ($view = "modules") do={ :return [$rhTgBuiltinModules] }
  :if ($view = "log") do={ :return [$rhTgBuiltinLog] }
  :if ($view = "help") do={ :return [$rhTgBuiltinHelp] }
  :if ($view = "check-updates") do={ :return [$rhTgBuiltinCheckUpdates] }
  :if ($view = "menu" || $view = "start") do={ :return "🤖 <b>ROSHub control menu</b>" }
  :return ""
}

:global rhTgViewNames {"status"; "modules"; "log"; "help"; "check-updates"; "menu"; "start"}

:global rhTgIsView do={
  :global rhTgViewNames
  :local found 0
  :foreach v in=$rhTgViewNames do={
    :if ($v = $view) do={ :set found 1 }
  }
  :return $found
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
  :global rhTgRenderView
  :global rhTgIsView
  :global rhTgBuiltinApplyUpdates
  :global rhTgMenuMarkup

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
    :if ([$rhTgIsView view=$cmd] = 1) do={
      [$rhTgSend chatId=$chatId text=[$rhTgRenderView view=$cmd] markup=[$rhTgMenuMarkup]]
    } else={
    :if ($cmd = "apply-updates") do={
      [$rhTgSend chatId=$chatId text=[$rhTgBuiltinApplyUpdates] markup=[$rhTgMenuMarkup]]
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
        # A tapped inline-keyboard button. A read-only view (rhTgIsView) edits
        # the existing menu card in place, so clicking through Status/
        # Modules/Log/Help/Menu updates one message instead of spamming a new
        # one per tap. Anything else (currently only "reboot") is a real
        # control action - routed through the normal command handler exactly
        # as if typed, so it still goes through the whitelist/dangerous/
        # confirm machinery and sends its own separate message, not an edit.
        :local cbq ($upd->"callback_query")
        :if ([:typeof $cbq] != "nothing") do={
          :local cbMsg ($cbq->"message")
          :local cbChat ($cbMsg->"chat")
          :local cbFrom ($cbq->"from")
          :local cbData ($cbq->"data")
          :if ([:typeof $cbData] = "nothing") do={ :set cbData "" }
          :if ([$rhTgIsWhitelisted chatId=($cbChat->"id")] = 1 && [$rhTgIsView view=$cbData] = 1) do={
            [$rhTgEditMessage chatId=($cbChat->"id") messageId=($cbMsg->"message_id") text=[$rhTgRenderView view=$cbData] markup=[$rhTgMenuMarkup]]
          } else={
            [$rhTgHandleUpdate chatId=($cbChat->"id") fromId=($cbFrom->"id") text=("/" . $cbData)]
          }
          [$rhTgAnswerCallback id=($cbq->"id")]
        }
      }
    }
  }
} on-error={
  [$rhLog module="tg-control" level="debug" text="getUpdates failed (no token yet?)"]
}

[$rhStateSaveThrottled module="tg-control" data=$rhTgState minIntervalSec=60]
[$rhLockRelease name="tg-control"]
