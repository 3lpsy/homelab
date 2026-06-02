# Managed by Terraform (cluster/modules/node-provision-server). Do not edit by hand.
#
# NUT operating mode for this node:
#   netserver — delphi: drives the USB UPS, runs upsd, serves status to the LAN.
#   netclient — artemis: no UPS of its own; upsmon monitors delphi's upsd.
MODE=${mode}
