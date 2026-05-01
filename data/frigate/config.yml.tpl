# Publish detection events to Mosquitto in the homeassist namespace so
# Home Assistant's Frigate integration can materialise per-camera object
# entities. Topic shape: `frigate/<cam>/<obj>/...`. The `{FRIGATE_*}`
# substitution mirrors the per-cam RTSP password pattern below — value
# comes from FRIGATE_MQTT_PASSWORD env, fed by the CSI-synced config
# secret in services/frigate.tf.
mqtt:
  enabled: true
  host: mosquitto.homeassist.svc.cluster.local
  port: 1883
  user: frigate
  password: "{FRIGATE_MQTT_PASSWORD}"
  topic_prefix: frigate
  client_id: frigate

ffmpeg:
  hwaccel_args: preset-vaapi

# ROCm execution provider via the stable-rocm image. In Frigate 0.17 the
# detector type is `onnx` — the runtime auto-selects ROCMExecutionProvider
# when available in the image (which it is in stable-rocm). gfx1035 is
# spoofed to gfx1030 via HSA_OVERRIDE_GFX_VERSION (set in frigate.tf) so
# the Rembrandt iGPU is treated as an officially-supported target. Model
# auto-downloads to /config/model_cache/ on first start.
detectors:
  ort:
    type: onnx

# Frigate 0.17 ONNX detector requires an explicit model path; no model is
# bundled or auto-downloaded. yolo-generic + YOLOv9-tiny (320x320) is the
# documented export path with a one-line Docker build (no super-gradients
# / Python deps, unlike YOLO-NAS). Export procedure + the kubectl cp into
# this PVC are documented in the README. The model file lives inside the
# frigate-config PVC so it survives pod restarts.
model:
  model_type: yolo-generic
  width: 320
  height: 320
  input_tensor: nchw
  input_dtype: float
  path: /config/model_cache/yolo.onnx
  labelmap_path: /labelmap/coco-80.txt

record:
  enabled: true
  alerts:
    retain:
      days: 5
      mode: motion
  detections:
    retain:
      days: 5
      mode: motion

snapshots:
  enabled: true
  retain:
    default: 5

# Two auth layers by design:
#   1. Tailnet ACL (group:frigate-clients -> group:frigate-server:443)
#      controls who can REACH the pod.
#   2. Frigate's built-in auth (this block) controls who can USE the UI.
# The admin password is seeded from Vault by the seed-admin-user init
# container in frigate.tf; UI password changes are not supported because
# they get overwritten on the next pod restart.
auth:
  enabled: true

%{ if length(cameras) == 0 ~}
cameras: {}
%{ else ~}
cameras:
%{ for name, cam in cameras ~}
  ${name}:
    ffmpeg:
      inputs:
        - path: rtsp://${cam.username}:{FRIGATE_RTSP_PASSWORD_${cam.env_key}}@${cam.ip}:554/cam/realmonitor?channel=1&subtype=0
          roles:
            - record
        - path: rtsp://${cam.username}:{FRIGATE_RTSP_PASSWORD_${cam.env_key}}@${cam.ip}:554/cam/realmonitor?channel=1&subtype=1
          roles:
            - detect
    detect:
      enabled: true
      width: 640
      height: 480
      fps: 5
    objects:
      track:
%{ for obj in cam.objects ~}
        - ${obj}
%{ endfor ~}
%{ endfor ~}
%{ endif ~}
