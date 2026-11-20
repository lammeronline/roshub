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

# Multi-level menu: "nav:<name>" is pure navigation (never runs anything,
# always handled by editing the card in place with that section's keyboard),
# everything else is either a read-only view (rhTgViewNames, also
# edit-in-place) or a real control action routed through the normal command
# handler - so a button can start the /confirm flow for something dangerous,
# but never skip it. args: section (optional, default "main")
:global rhTgMenuMarkup do={
  :local sectionVal $section
  :if ([:typeof $sectionVal] = "nothing") do={ :set sectionVal "main" }
  :if ($sectionVal = "info") do={
    :return [:serialize to=json ({"inline_keyboard"={
      {{"text"="📊 Status"; "callback_data"="status"}; {"text"="📦 Modules"; "callback_data"="modules"}};
      {{"text"="📜 Log"; "callback_data"="log"}; {"text"="❓ Help"; "callback_data"="help"}};
      {{"text"="⬅️ Back"; "callback_data"="nav:main"}}
    }})]
  }
  :if ($sectionVal = "tools") do={
    :return [:serialize to=json ({"inline_keyboard"={
      {{"text"="🔄 Check updates"; "callback_data"="check-updates"}; {"text"="⬆️ Apply updates"; "callback_data"="apply-updates"}};
      {{"text"="⬅️ Back"; "callback_data"="nav:main"}}
    }})]
  }
  :if ($sectionVal = "system") do={
    :return [:serialize to=json ({"inline_keyboard"={
      {{"text"="🔍 Check RouterOS update"; "callback_data"="sys-check"}};
      {{"text"="⬇️ Install RouterOS update"; "callback_data"="sys-update"}};
      {{"text"="↩️ Rollback RouterOS"; "callback_data"="sys-downgrade"}};
      {{"text"="🔧 Upgrade RouterBOARD firmware"; "callback_data"="fw-upgrade"}};
      {{"text"="♻️ Reboot"; "callback_data"="reboot"}};
      {{"text"="⬅️ Back"; "callback_data"="nav:main"}}
    }})]
  }
  :return [:serialize to=json ({"inline_keyboard"={
    {{"text"="ℹ️ Info"; "callback_data"="nav:info"}; {"text"="🧰 Tools"; "callback_data"="nav:tools"}; {"text"="⚙️ System"; "callback_data"="nav:system"}}
  }})]
}

# Which section's keyboard to attach under a view/action's own reply, so
# "Back" lands where it was tapped from rather than always the top level.
:global rhTgSectionOf do={
  :if ($name = "status" || $name = "modules" || $name = "log" || $name = "help") do={ :return "info" }
  :if ($name = "check-updates" || $name = "apply-updates") do={ :return "tools" }
  :if ($name = "sys-check" || $name = "sys-update" || $name = "sys-downgrade" || $name = "fw-upgrade" || $name = "reboot") do={ :return "system" }
  :return "main"
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

# args: chatId, text, markup (optional), messageId (optional) - edits that
# message in place if messageId is given (a button tap always has one),
# otherwise sends a fresh message (a typed command has no existing card to
# edit into). Every reply in this module goes through here now, so a button
# tap never has to spawn a second message next to the menu card - including
# the dangerous-command confirm prompt and its result, which used to always
# send a separate message even when started from a button.
:global rhTgReply do={
  :global rhTgSend
  :global rhTgEditMessage
  :local midVal $messageId
  :if ([:typeof $midVal] != "nothing" && $midVal != "") do={
    [$rhTgEditMessage chatId=$chatId messageId=$midVal text=$text markup=$markup]
  } else={
    [$rhTgSend chatId=$chatId text=$text markup=$markup]
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
  :local out "❓ <b>Commands</b>\n/status /modules /log /help /menu /check-updates /apply-updates /sys-check /sys-update /sys-downgrade /fw-upgrade /reboot (needs /confirm)"
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

# Read-only: asks RouterOS to check its update channel, waits a few seconds
# for that check to come back, then reports what it found. Does NOT download
# or install anything - see rhTgRunConfirmed's "sys-update" for that.
:global rhTgBuiltinSysCheck do={
  :local out "🔍 <b>RouterOS update check</b>"
  :do {
    /system package update check-for-updates
    :delay 3s
    :local upd [/system package update print as-value]
    :set out ($out . "\nchannel: <code>" . ($upd->"channel") . "</code>\ninstalled: <code>" . ($upd->"installed-version") . "</code>\nlatest: <code>" . ($upd->"latest-version") . "</code>\nstatus: <code>" . ($upd->"status") . "</code>")
  } on-error={
    :set out ($out . "\n❌ could not reach the update channel")
  }
  :return $out
}

# args: chatId, messageId (optional) - runs the actual RouterOS package
# install (downloads + installs + reboots on its own once ready, per
# RouterOS's own behaviour - not something this module controls or can
# prevent).
:global rhTgRunSysUpdate do={
  :global rhTgReply
  [$rhTgReply chatId=$chatId messageId=$messageId text="⬇️ Installing RouterOS update - the router will reboot on its own once it's done."]
  /system package update install
}

# args: chatId, messageId (optional) - reverts to the previously installed
# RouterOS package set (what /system package downgrade does natively).
# Confirmed on the CHR stand to reboot immediately, even with nothing
# meaningful to revert to - so this always warns about that reboot up front
# rather than waiting to see.
:global rhTgRunSysDowngrade do={
  :global rhTgReply
  [$rhTgReply chatId=$chatId messageId=$messageId text="↩️ Rolling back RouterOS - the router will reboot now."]
  /system package downgrade
}

# args: chatId, messageId (optional) - upgrades RouterBOARD firmware to
# match the installed RouterOS. Unlike a package install this does NOT
# reboot on its own - the new firmware only takes effect after a manual
# reboot.
:global rhTgRunFwUpgrade do={
  :global rhTgReply
  :global rhTgMenuMarkup
  :global rhTgSectionOf
  :do {
    /system routerboard upgrade
    [$rhTgReply chatId=$chatId messageId=$messageId text="🔧 RouterBOARD firmware upgraded - run /reboot for it to take effect." markup=[$rhTgMenuMarkup section=[$rhTgSectionOf name="fw-upgrade"]]]
  } on-error={
    [$rhTgReply chatId=$chatId messageId=$messageId text="❌ RouterBOARD upgrade failed or nothing to upgrade." markup=[$rhTgMenuMarkup section=[$rhTgSectionOf name="fw-upgrade"]]]
  }
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
  :global rhTgBuiltinSysCheck
  :if ($view = "status") do={ :return [$rhTgBuiltinStatus] }
  :if ($view = "modules") do={ :return [$rhTgBuiltinModules] }
  :if ($view = "log") do={ :return [$rhTgBuiltinLog] }
  :if ($view = "help") do={ :return [$rhTgBuiltinHelp] }
  :if ($view = "check-updates") do={ :return [$rhTgBuiltinCheckUpdates] }
  :if ($view = "sys-check") do={ :return [$rhTgBuiltinSysCheck] }
  :if ($view = "menu" || $view = "start") do={ :return "🤖 <b>ROSHub control menu</b>" }
  :return ""
}

:global rhTgViewNames {"status"; "modules"; "log"; "help"; "check-updates"; "sys-check"; "menu"; "start"}

:global rhTgIsView do={
  :global rhTgViewNames
  :local found 0
  :foreach v in=$rhTgViewNames do={
    :if ($v = $view) do={ :set found 1 }
  }
  :return $found
}

# Commands that must be confirmed before running - matched against the
# command name (without the leading "/"). sys-update and fw-upgrade are here
# alongside reboot because both can leave the router rebooting or otherwise
# unreachable on their own schedule, not just this module's.
:global rhTgDangerous {"reboot"; "sys-update"; "sys-downgrade"; "fw-upgrade"}

:global rhTgIsDangerous do={
  :global rhTgDangerous
  :local found 0
  :foreach d in=$rhTgDangerous do={
    :if ($d = $cmd) do={ :set found 1 }
  }
  :return $found
}

# args: chatId, cmd, messageId (optional) - runs a confirmed dangerous
# command by name
:global rhTgRunConfirmed do={
  :global rhLog
  :global rhTgReply
  :global rhTgRunSysUpdate
  :global rhTgRunSysDowngrade
  :global rhTgRunFwUpgrade
  :if ($cmd = "reboot") do={
    [$rhLog module="tg-control" level="crit" text=("reboot confirmed via chat " . $chatId)]
    [$rhTgReply chatId=$chatId messageId=$messageId text="rebooting now"]
    /system reboot
  }
  :if ($cmd = "sys-update") do={
    [$rhLog module="tg-control" level="crit" text=("RouterOS update confirmed via chat " . $chatId)]
    [$rhTgRunSysUpdate chatId=$chatId messageId=$messageId]
  }
  :if ($cmd = "sys-downgrade") do={
    [$rhLog module="tg-control" level="crit" text=("RouterOS downgrade confirmed via chat " . $chatId)]
    [$rhTgRunSysDowngrade chatId=$chatId messageId=$messageId]
  }
  :if ($cmd = "fw-upgrade") do={
    [$rhLog module="tg-control" level="crit" text=("RouterBOARD upgrade confirmed via chat " . $chatId)]
    [$rhTgRunFwUpgrade chatId=$chatId messageId=$messageId]
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
  :global rhTgSectionOf
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
      [$rhTgSend chatId=$chatId text=[$rhTgRenderView view=$cmd] markup=[$rhTgMenuMarkup section=[$rhTgSectionOf name=$cmd]]]
    } else={
    :if ($cmd = "apply-updates") do={
      [$rhTgSend chatId=$chatId text=[$rhTgBuiltinApplyUpdates] markup=[$rhTgMenuMarkup section=[$rhTgSectionOf name=$cmd]]]
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
        :local confirmMarkup [:serialize to=json ({"inline_keyboard"={{{"text"=("✅ Confirm /" . $cmd); "callback_data"=("confirm:" . $tok)}}}})]
        [$rhTgSend chatId=$chatId text=("⚠️ type /confirm " . $tok . " within a minute to run /" . $cmd . ", or just tap below:") markup=$confirmMarkup]
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
        # A tapped inline-keyboard button. Every path below ends up calling
        # rhTgReply with this button's own message_id, so whatever happens -
        # navigation, a read-only view, a confirm prompt, running a confirmed
        # dangerous command, or a direct action like apply-updates - edits
        # the SAME card in place. Nothing from a button tap ever spawns a
        # second message next to the menu; only a typed command (which has
        # no existing card to edit into) still gets its own reply.
        :local cbq ($upd->"callback_query")
        :if ([:typeof $cbq] != "nothing") do={
          :local cbMsg ($cbq->"message")
          :local cbChat ($cbMsg->"chat")
          :local cbChatId ($cbChat->"id")
          :local cbMsgId ($cbMsg->"message_id")
          :local cbData ($cbq->"data")
          :if ([:typeof $cbData] = "nothing") do={ :set cbData "" }
          :local navPrefix [:pick $cbData 0 4]
          :local confirmPrefix [:pick $cbData 0 8]
          :if ([$rhTgIsWhitelisted chatId=$cbChatId] = 0) do={
            [$rhLog module="tg-control" level="warn" text=("ignored button from non-whitelisted chat " . $cbChatId)]
          } else={
            :if ($navPrefix = "nav:") do={
              :local section [:pick $cbData 4 [:len $cbData]]
              :local title "🤖 <b>ROSHub control menu</b>"
              :if ($section = "info") do={ :set title "ℹ️ <b>Info</b>" }
              :if ($section = "tools") do={ :set title "🧰 <b>Tools</b>" }
              :if ($section = "system") do={ :set title "⚙️ <b>System</b>" }
              [$rhTgReply chatId=$cbChatId messageId=$cbMsgId text=$title markup=[$rhTgMenuMarkup section=$section]]
            } else={
              :if ($confirmPrefix = "confirm:") do={
                :local tok [:pick $cbData 8 [:len $cbData]]
                :local pending ($rhTgState->"pending")
                :local chatKey [:tostr $cbChatId]
                :local entry ($pending->$chatKey)
                :local nowUptime [:tonum [/system resource get uptime]]
                :if ([:typeof $entry] != "nothing" && ($entry->"token") = $tok && $nowUptime <= ($entry->"expires")) do={
                  :local dcmd ($entry->"cmd")
                  :local newPending [:toarray ""]
                  :foreach k,v in=$pending do={
                    :if ($k != $chatKey) do={ :set ($newPending->$k) $v }
                  }
                  :set pending $newPending
                  :set ($rhTgState->"pending") $pending
                  [$rhTgRunConfirmed chatId=$cbChatId cmd=$dcmd messageId=$cbMsgId]
                } else={
                  [$rhTgReply chatId=$cbChatId messageId=$cbMsgId text="no matching pending confirmation" markup=[$rhTgMenuMarkup section="system"]]
                }
              } else={
                :if ([$rhTgIsView view=$cbData] = 1) do={
                  [$rhTgReply chatId=$cbChatId messageId=$cbMsgId text=[$rhTgRenderView view=$cbData] markup=[$rhTgMenuMarkup section=[$rhTgSectionOf name=$cbData]]]
                } else={
                  :if ($cbData = "apply-updates") do={
                    [$rhTgReply chatId=$cbChatId messageId=$cbMsgId text=[$rhTgBuiltinApplyUpdates] markup=[$rhTgMenuMarkup section=[$rhTgSectionOf name=$cbData]]]
                  } else={
                    :if ([$rhTgIsDangerous cmd=$cbData] = 1) do={
                      :local tok2 [:tostr (([/system clock get time] . [:tostr $cbChatId]))]
                      :local nowUptime2 [:tonum [/system resource get uptime]]
                      :local pending2 ($rhTgState->"pending")
                      :local entry2 [:toarray ""]
                      :set ($entry2->"cmd") $cbData
                      :set ($entry2->"token") $tok2
                      :set ($entry2->"expires") ($nowUptime2 + 60)
                      :set ($pending2->[:tostr $cbChatId]) $entry2
                      :set ($rhTgState->"pending") $pending2
                      :local confirmMarkup2 [:serialize to=json ({"inline_keyboard"={{{"text"=("✅ Confirm /" . $cbData); "callback_data"=("confirm:" . $tok2)}}; {{"text"="❌ Cancel"; "callback_data"=("nav:" . [$rhTgSectionOf name=$cbData])}}}})]
                      [$rhTgReply chatId=$cbChatId messageId=$cbMsgId text=("⚠️ Confirm running /" . $cbData . "?") markup=$confirmMarkup2]
                    } else={
                      :local cbFrom ($cbq->"from")
                      [$rhTgHandleUpdate chatId=$cbChatId fromId=($cbFrom->"id") text=("/" . $cbData)]
                    }
                  }
                }
              }
            }
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
