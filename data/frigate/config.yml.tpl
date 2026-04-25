mqtt:
  enabled: false

ffmpeg:
  hwaccel_args: preset-vaapi

detectors:
  cpu1:
    type: cpu

record:
  enabled: true
  alerts:
    retain:
      days: 14
  detections:
    retain:
      days: 7

snapshots:
  enabled: true
  retain:
    default: 14

# Two auth layers by design:
#   1. Tailnet ACL (group:frigate-clients -> group:frigate-server:443)
#      controls who can REACH the pod.
#   2. Frigate's built-in auth (this block) controls who can USE the UI.
# The admin password is seeded from Vault by the seed-admin-user init
# container in frigate.tf; UI password changes are not supported because
# they get overwritten on the next pod restart.
auth:
  enabled: true

cameras: {}
