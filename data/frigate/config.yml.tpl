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

# go2rtc restream. Without this block Frigate's live view falls back to
# jsmpeg (low-res canvas render of the detect substream). With it,
# Frigate's UI serves the mainstream over MSE through the existing
# auth-proxy port 8971 — no extra ports to expose, the existing nginx
# `/live/` + `/ws` location blocks already carry the WS upgrade.
#
# Both Frigate's detect+record ffmpeg inputs point at this restream
# (`rtsp://127.0.0.1:8554/<name>{,_sub}`) so each camera serves ONE
# RTSP pull per stream regardless of how many consumers attach (per
# upstream docs: "One connection is made to the camera. One for the
# restream, detect and record connect to the restream.").
#
# Audio: Amcrest mainstream is AAC, substream is PCMU — both are MSE-
# compatible (PCMA/PCMU or AAC). No `ffmpeg:#audio=opus` transcode
# layer needed unless WebRTC is later opted in (separate port 8555).
%{ if length(cameras) > 0 ~}
go2rtc:
  streams:
%{ for name, cam in cameras ~}
    ${name}:
      - rtsp://${cam.username}:{FRIGATE_RTSP_PASSWORD_${cam.env_key}}@${cam.ip}:554/cam/realmonitor?channel=1&subtype=0
    ${name}_sub:
      - rtsp://${cam.username}:{FRIGATE_RTSP_PASSWORD_${cam.env_key}}@${cam.ip}:554/cam/realmonitor?channel=1&subtype=1
%{ endfor ~}
%{ endif ~}

# AMD R9700 (gfx1201/RDNA4) via the :stable-rocm image (ROCm 7.1.1). The onnx
# detector runs through onnxruntime's MIGraphXExecutionProvider on gfx1201 —
# gfx12 is supported natively, so no HSA_OVERRIDE_GFX_VERSION. Compute goes
# through /dev/kfd; ffmpeg VAAPI decode through /dev/dri (both mounted in
# services/frigate.tf). REQUIRES host kernel >= 7.0.9 — kernel 6.19's amdkfd
# can't open /dev/kfd for RDNA4 in a container (EINVAL). First detector init
# compiles the ONNX to a MIGraphX .mxr (RAM-heavy, one-time, cached to
# model_cache/) — frigate's mem limit is sized for that spike (see frigate.tf).
detectors:
  rocm:
    type: onnx

# Self-built YOLOv9-c @640 (COCO-80) — bigger + higher-res than the retired
# Coral 320 model; the R9700 has ample headroom. `yolo-generic` handles the
# YOLOv9 ONNX; labelmap is the image's built-in COCO-80 list. The model is
# carried by the frigate-model image (services/frigate-jobs.tf) and copied to
# /config/model_cache/yolo.onnx by the `seed-model` init container in
# services/frigate.tf. Bump model = MODEL_SIZE in frigate-jobs.tf.
model:
  model_type: yolo-generic
  width: 640
  height: 640
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

# Global per-class filters. Applied to every camera unless a cam-level
# `objects.filters.<class>` block overrides specific keys.
#
# Cat / dog: YOLOv9-c on the R9700 rarely emits these at high confidence at
# this image resolution — defaults (threshold 0.7) drop most small-mammal
# detections, so they never surface as events. Lowering to 0.5 lets the
# model's fuzzy hits through while still gating out the noisiest junk.
# Bird is left at Frigate's defaults — accepted tradeoff is that some
# cats will still surface as bird events.
objects:
  filters:
    cat:
      threshold: 0.5
      min_score: 0.5
    dog:
      threshold: 0.5
      min_score: 0.5

# Auth layers (outer-to-inner):
#   1. Tailnet ACL (group:frigate-clients -> group:frigate-server:443)
#      controls who can REACH the pod.
#   2. oauth2-proxy sidecar -> Zitadel OIDC code flow on the browser path.
#      nginx auth_request gates `/`, `/live`, `/api`, `/ws`, `/vod` against
#      the sidecar; on success nginx forwards X-Forwarded-User and
#      X-Forwarded-Groups (the Zitadel project role).
#   3. Frigate proxy auth (this block) trusts those headers, mapping
#      groups -> Frigate roles via role_map below. Frigate's built-in
#      user/password auth is OFF — `auth.enabled: false` is required when
#      proxy auth is configured (per upstream docs; the two modes do not
#      layer).
#
# The cluster-internal frigate-internal Service (port 443) is the unauth
# path for the Home Assistant Frigate integration. It routes to a second
# nginx listener (port 8443) in the same pod which terminates TLS with
# Frigate's existing cert and proxies to Frigate's port 5000 (anonymous-
# admin per upstream docs). HA keeps using `https://frigate.<magic>` via
# host_aliases on its pod; reachability is constrained by NetworkPolicy
# to the homeassist namespace only.
auth:
  enabled: false

proxy:
  header_map:
    user: x-forwarded-user
    role: x-forwarded-groups
  # Anyone who lands here without a recognised role gets read-only.
  # Granted users always carry an `admin` or `viewer` group from Zitadel,
  # so default_role only matters as a defensive floor.
  default_role: viewer
  # RP-initiated logout: clear oauth2-proxy cookie, then bounce through
  # Zitadel's end_session to terminate SSO, then back to Frigate. Without
  # the chain, SSO instantly re-issues a token and "logout" feels like a
  # page refresh. Built in services/frigate.tf as local.frigate_logout_url.
  logout_url: ${logout_url}
  # No role_map — that key requires a newer Frigate than `stable-rocm` is
  # currently pinned to. Zitadel's project role keys (`admin`, `viewer`,
  # declared in services/frigate.tf) intentionally match Frigate's built-in
  # role names so identity mapping works out of the box: oauth2-proxy
  # forwards the role key as X-Forwarded-Groups, Frigate matches it
  # directly against its own role names.

%{ if length(cameras) == 0 ~}
cameras: {}
%{ else ~}
cameras:
%{ for name, cam in cameras ~}
  ${name}:
    ffmpeg:
      inputs:
        # Both inputs go to go2rtc, not the camera directly. Camera sees
        # one pull per stream regardless of consumer count.
        - path: rtsp://127.0.0.1:8554/${name}
          input_args: preset-rtsp-restream
          roles:
            - record
        - path: rtsp://127.0.0.1:8554/${name}_sub
          input_args: preset-rtsp-restream
          roles:
            - detect
    # Live view source selection. Frigate's UI shows a dropdown per
    # camera with these labels; `Main` is the mainstream restream
    # (crisp, what the camera's own web UI shows), `Sub` is the same
    # 640x480 the detector consumes (low-bandwidth fallback). With
    # go2rtc present, the default tech is MSE — works over the
    # existing nginx /live/ + /ws proxy, no extra port forwarding.
    live:
      streams:
        Main: ${name}
        Sub: ${name}_sub
    detect:
      enabled: true
      width: 640
      height: 480
      # Per-cam — defaults to 5. PTZ autotracking cams want higher
      # (10-15) for tighter response; fixed cams stay at 5 to save
      # detector/GPU cycles and pod /dev/shm. Substream on the camera must
      # be ≥ this value or Frigate just samples what the source
      # delivers.
      fps: ${cam.fps}
    # Zones use Frigate 0.13+ normalised polygon coords (0.0-1.0 floats,
    # resolution-independent — pixel coords were deprecated). When
    # autotracking is on Frigate requires `required_zones` non-empty
    # as a safety so the camera doesn't chase every transient object;
    # the synthesised `all` zone (whole frame) is the no-op default.
    # Override via `zones` in the frigate_cameras tfvar to scope tracking
    # tighter — e.g. `coordinates = "0.2,0.3,0.8,0.3,0.8,0.9,0.2,0.9"`.
%{ if length(cam.zones) > 0 || (cam.onvif != null && cam.onvif.autotracking.enabled) ~}
    zones:
%{ if length(cam.zones) == 0 ~}
      all:
        coordinates: 0,0,1,0,1,1,0,1
%{ else ~}
%{ for zname, zone in cam.zones ~}
      ${zname}:
        coordinates: ${zone.coordinates}
%{ endfor ~}
%{ endif ~}
%{ endif ~}
    objects:
      track:
%{ for obj in cam.objects ~}
        - ${obj}
%{ endfor ~}
%{ if cam.onvif != null ~}
    onvif:
      host: ${cam.ip}
      port: ${cam.onvif.port}
      user: ${cam.username}
      password: "{FRIGATE_RTSP_PASSWORD_${cam.env_key}}"
      autotracking:
        enabled: ${cam.onvif.autotracking.enabled}
        calibrate_on_startup: ${cam.onvif.autotracking.calibrate_on_startup}
        return_preset: ${cam.onvif.autotracking.return_preset}
        track:
%{ for obj in cam.onvif.autotracking.track ~}
          - ${obj}
%{ endfor ~}
        required_zones:
%{ for zname in cam.onvif.autotracking.required_zones ~}
          - ${zname}
%{ endfor ~}
        timeout: ${cam.onvif.autotracking.timeout}
        zooming: ${cam.onvif.autotracking.zooming}
%{ endif ~}
%{ endfor ~}
%{ endif ~}
