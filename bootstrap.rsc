# RH:core:bootstrap
# One-time installer for rh-core. Usage on the router:
#   /tool fetch url="https://raw.githubusercontent.com/lammeronline/roshub/main/bootstrap.rsc" dst-path=bootstrap.rsc
#   /import bootstrap.rsc
# Re-running it is safe - it just re-fetches and re-installs rh-core at the version
# pinned by manifest.json's "core" entry. Everything after this step is rhPkg's job.

:local repo "lammeronline/roshub"
:local manifestUrl ("https://raw.githubusercontent.com/" . $repo . "/main/manifest.json")
:local manifest [:deserialize from=json (([/tool fetch url=$manifestUrl output=user as-value])->"data")]
:local core ($manifest->"core")
:if ([:typeof $core] = "nothing") do={
  :error "manifest.json has no core entry"
}
:local tag ($core->"tag")
:local coreUrl ("https://raw.githubusercontent.com/" . $repo . "/" . $tag . "/core/rh-core.rsc")
:local content (([/tool fetch url=$coreUrl output=user as-value])->"data")

:if ([:len [/system script find name="rh-core"]] > 0) do={
  /system script set [find name="rh-core"] source=$content comment="RH:core:rh-core"
} else={
  /system script add name="rh-core" source=$content comment="RH:core:rh-core"
}

:if ([:len [/system scheduler find name="rh-core"]] > 0) do={
  /system scheduler set [find name="rh-core"] start-time=startup interval=0 on-event="/system script run rh-core"
} else={
  /system scheduler add name="rh-core" start-time=startup interval=0 on-event="/system script run rh-core"
}

/system script run rh-core
:put ("rh-core " . $tag . " installed")
