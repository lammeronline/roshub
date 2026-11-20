# RH:notify-telegram:rh-notify-telegram
# Telegram channel for the notify bus. Run by rh-notify as "rh-notify-telegram" with
# :global rhNotifyMsgText already set to the text to send; :error on any failure so
# the bus queues it for retry.
#
# Secrets (rh-secrets, never in the repo): notify.telegram.token, notify.telegram.chat-id.

:global rhNotifyMsgText
:global rhSecretGet

:if ([:typeof $rhNotifyMsgText] = "nothing") do={
  :error "rhNotifyMsgText not set (channel run outside the notify bus)"
}

:local token [$rhSecretGet key="notify.telegram.token" dflt=""]
:local chatId [$rhSecretGet key="notify.telegram.chat-id" dflt=""]
:if ($token = "" || $chatId = "") do={
  :error "notify.telegram.token/chat-id not set in rh-secrets"
}

:local body [:serialize to=json ({"chat_id"=$chatId; "text"=$rhNotifyMsgText})]
:local r [/tool fetch url=("https://api.telegram.org/bot" . $token . "/sendMessage") http-method=post http-data=$body http-header-field="Content-Type: application/json" as-value output=user]
:if (($r->"status") != "finished") do={
  :error ("telegram send failed: " . ($r->"status"))
}
