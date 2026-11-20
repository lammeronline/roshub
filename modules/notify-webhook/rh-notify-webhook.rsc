# RH:notify-webhook:rh-notify-webhook
# Generic HTTP webhook channel for the notify bus - POSTs {"text": message}
# as JSON to any URL (own server, or anything that accepts a plain "text"
# field). Run by rh-notify as "rh-notify-webhook" with :global
# rhNotifyMsgText already set; :error on any failure so the bus queues it.
#
# Config (rhConfig): notify.webhook.url (required).

:global rhNotifyMsgText
:global rhConfigGet

:if ([:typeof $rhNotifyMsgText] = "nothing" || $rhNotifyMsgText = "") do={
  :error "rhNotifyMsgText not set (channel run outside the notify bus)"
}

:local url [$rhConfigGet key="notify.webhook.url" dflt=""]
:if ($url = "") do={
  :error "notify.webhook.url not set in rh-config"
}

:local body [:serialize to=json ({"text"=$rhNotifyMsgText})]
:local r [/tool fetch url=$url http-method=post http-data=$body http-header-field="Content-Type: application/json" as-value output=user]
:if (($r->"status") != "finished") do={
  :error ("webhook send failed: " . ($r->"status"))
}
