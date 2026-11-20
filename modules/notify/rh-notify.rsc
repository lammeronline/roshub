# RH:notify:rh-notify
# Event bus. Subscribes itself to core events (re-subscribing on every run, since
# rhEventSubs does not survive a reboot - see rh-core's rhEvent). Applies a global
# min-level + enabled-channels filter, de-dupes repeated events (same module+name
# sending the same level again is skipped until the level changes), and dispatches
# to channel modules by script name: a channel is "rh-notify-<channel>", found and
# run by that name - never called directly, so a missing/not-installed channel is
# just a failed /system script run, caught and queued for retry.
#
# Config (rhConfig): notify.channels = comma-separated list, e.g. "telegram,email"
# (default: none). notify.min-level = debug|info|warn|crit (default: warn).

:global rhLog
:global rhConfigGet
:global rhStateLoad
:global rhStateSave
:global rhEventSubscribe
:global rhEvName
:global rhEvLevel
:global rhEvModule
:global rhEvText

:global rhNotifyLast
:global rhNotifyQueue
:global rhNotifyMsgText

[$rhEventSubscribe script="rh-notify"]

:if ([:typeof $rhNotifyQueue] = "nothing") do={ :set rhNotifyQueue [:toarray ""] }
:if ([:typeof $rhNotifyLast] = "nothing") do={ :set rhNotifyLast [$rhStateLoad module="notify"] }

# args: text, channel - runs "rh-notify-<channel>" with rhNotifyMsgText set and
# returns 1/0. No side effect on the queue - callers decide what to do on failure
# (rhNotifySend queues it, rhNotifyFlush drops it back into the queue it owns).
:global rhNotifyTryOne do={
  :global rhNotifyMsgText
  :set rhNotifyMsgText $text
  :local scriptName ("rh-notify-" . $channel)
  :local ok 1
  :do {
    /system script run $scriptName
  } on-error={ :set ok 0 }
  :set rhNotifyMsgText ""
  :return $ok
}

# args: text - sends to every channel listed in notify.channels, queueing failures
:global rhNotifySend do={
  :global rhNotifyQueue
  :local channels [$rhConfigGet key="notify.channels" dflt=""]
  :local list [:toarray $channels]
  :foreach ch in=$list do={
    :local ok [$rhNotifyTryOne channel=$ch text=$text]
    :if ($ok = 0) do={
      [$rhLog module="notify" level="warn" text=("channel " . $ch . " failed, queued")]
      :local item [:toarray ""]
      :set ($item->"channel") $ch
      :set ($item->"text") $text
      :set ($rhNotifyQueue->[:len $rhNotifyQueue]) $item
    }
  }
}

:global rhNotifyOnEvent do={
  :global rhNotifyLast
  :local minLevel [$rhConfigGet key="notify.min-level" dflt="warn"]
  :local levelNum {"debug"=0; "info"=1; "warn"=2; "crit"=3}
  :local lvlN ($levelNum->$rhEvLevel)
  :local minN ($levelNum->$minLevel)
  :if ([:typeof $lvlN] = "nothing") do={ :set lvlN 1 }
  :if ([:typeof $minN] = "nothing") do={ :set minN 2 }
  :if ($lvlN < $minN) do={ :return "" }

  :local key ($rhEvModule . "." . $rhEvName)
  :local prev ($rhNotifyLast->$key)
  :if ($prev = $rhEvLevel) do={ :return "" }
  :set ($rhNotifyLast->$key) $rhEvLevel
  [$rhStateSave module="notify" data=$rhNotifyLast]

  :local line ("[" . $rhEvLevel . "] " . $rhEvModule . ": " . $rhEvText)
  [$rhNotifySend text=$line]
}

# Retries anything queued by a failed rhNotifySend. Called on every run of this
# script (event dispatch or the periodic scheduler) - cheap no-op when empty. Takes
# the queue out of the global before retrying, so a retry failing again (which
# pushes back into rhNotifyQueue through here, not through rhNotifySend) can't
# collide with whatever rhNotifySend appends concurrently to the same run.
:global rhNotifyFlush do={
  :global rhNotifyQueue
  :local snapshot $rhNotifyQueue
  :set rhNotifyQueue [:toarray ""]
  :foreach item in=$snapshot do={
    :local ok [$rhNotifyTryOne channel=($item->"channel") text=($item->"text")]
    :if ($ok = 0) do={
      :set ($rhNotifyQueue->[:len $rhNotifyQueue]) $item
    }
  }
}

[$rhNotifyOnEvent]
[$rhNotifyFlush]
