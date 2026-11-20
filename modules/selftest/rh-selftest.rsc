# RH:selftest:rh-selftest
# Diagnostic module with no function of its own: installing and removing it is
# how rhPkg's fetch/install/run/remove round trip is verified on a real router,
# without risking a real module. Not listed in README - it is a QA tool, not a feature.

:global rhLog
:global rhStateSave

:local state [:toarray ""]
:set ($state->"last-run") ([/system clock get date] . " " . [/system clock get time])
[$rhStateSave module="selftest" data=$state]

[$rhLog module="selftest" level="info" text="rh-selftest ran"]
