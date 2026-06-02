# Managed by Terraform (cluster/modules/node-provision-server). Do not edit by hand.
# Installed 0640 root:nut — carries the shared monitor password.
#
# Single read-only monitor user, used by both delphi's local upsmon and
# artemis's remote upsmon. "upsmon primary" grants only the upsmon role (status
# reads + the master/primary shutdown handshake), no SET/admin privileges.
[upsmon]
    password = ${monitor_password}
    upsmon primary
