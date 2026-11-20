# RH:notify-ntfy:rh-notify-ntfy
# ntfy/Gotify channel for the notify bus (plain HTTP POST, no account needed
# for a public ntfy.sh topic). Run by rh-notify as "rh-notify-ntfy" with
# :global rhNotifyMsgText already set; :error on any failure so the bus
# queues it for retry.
#
# Config (rhConfig): notify.ntfy.server (default https://ntfy.sh), notify.ntfy.topic (required).
# Secrets (rh-secrets, optional): notify.ntfy.token - Bearer token for a protected topic.

:global rhNotifyMsgText
:global rhConfigGet
:global rhSecretGet

:local server [$rhConfigGet key="notify.ntfy.server" dflt="https://ntfy.sh"]
:local topic [$rhConfigGet key="notify.ntfy.topic" dflt=""]
:if ($topic = "") do={
  :error "notify.ntfy.topic not set in rh-config"
}
:local token [$rhSecretGet key="notify.ntfy.token" dflt=""]
:local url ($server . "/" . $topic)

:local r ""
:if ($token != "") do={
  :set r [/tool fetch url=$url http-method=post http-data=$rhNotifyMsgText http-header-field=("Authorization: Bearer " . $token) as-value output=user]
} else={
  :set r [/tool fetch url=$url http-method=post http-data=$rhNotifyMsgText as-value output=user]
}
:if (($r->"status") != "finished") do={
  :error ("ntfy send failed: " . ($r->"status"))
}
