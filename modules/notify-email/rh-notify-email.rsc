# RH:notify-email:rh-notify-email
# E-mail channel for the notify bus, via RouterOS's built-in /tool e-mail (one SMTP
# profile, router-wide). Run by rh-notify as "rh-notify-email" with
# :global rhNotifyMsgText already set; :error on any failure so the bus queues it.
#
# Config (rhConfig, not secret): notify.email.server, notify.email.port (default 587),
# notify.email.tls (default yes), notify.email.from, notify.email.to.
# Secrets (rh-secrets): notify.email.user, notify.email.password.

:global rhNotifyMsgText
:global rhConfigGet
:global rhSecretGet

:local server [$rhConfigGet key="notify.email.server" dflt=""]
:local to [$rhConfigGet key="notify.email.to" dflt=""]
:if ($server = "" || $to = "") do={
  :error "notify.email.server/to not set in rh-config"
}
:local port [$rhConfigGet key="notify.email.port" dflt="587"]
:local tls [$rhConfigGet key="notify.email.tls" dflt="yes"]
:local from [$rhConfigGet key="notify.email.from" dflt=""]
:local user [$rhSecretGet key="notify.email.user" dflt=""]
:local password [$rhSecretGet key="notify.email.password" dflt=""]

/tool e-mail set server=$server port=[:tonum $port] tls=$tls from=$from user=$user password=$password
/tool e-mail send to=$to subject="ROSHub" body=$rhNotifyMsgText
