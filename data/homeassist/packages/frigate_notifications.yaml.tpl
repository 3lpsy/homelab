# TF-authoritative HA package: Frigate person-detection notifications.
# Rendered by services/homeassist.tf templatefile() and copied to
# /config/packages/frigate-notifications.yaml by the seed-packages init
# container on every pod start. UI / file edits to this file will be
# overwritten on the next restart — change the .tpl source instead.
#
# Image attachments are intentionally omitted: the iOS HA Companion
# app's notification-service-extension fetches `image:` URLs anonymously
# when the host is not HA itself, so https://frigate.<magic>/...
# 302s to Zitadel and fails to render. To add snapshots later, install
# the Frigate HACS integration and switch image to
# /api/frigate/notifications/{{ trigger.payload_json.after.id }}/snapshot.jpg
# (HA-proxied, app token reused).

%{ if length(notify_devices) > 0 && length(cameras) > 0 ~}
automation:
%{ for cam_name, _ in cameras ~}
  - id: frigate_person_${cam_name}
    alias: "Frigate: person at ${cam_name}"
    mode: single
    trigger:
      - platform: mqtt
        topic: frigate/events
    condition:
      - "{{ trigger.payload_json.type == 'new' }}"
      - "{{ trigger.payload_json.after.camera == '${cam_name}' }}"
      - "{{ trigger.payload_json.after.label == 'person' }}"
    action:
%{ for device in notify_devices ~}
      - service: notify.mobile_app_${device}
        data:
          title: "Person at ${cam_name}"
          message: "Frigate detected a person"
          data:
            url: https://${frigate_url}
            tag: "frigate-${cam_name}-{{ trigger.payload_json.after.id }}"
%{ endfor ~}
      # Per-camera cooldown: mode:single drops new triggers while sleeping.
      - delay: '00:03:00'
%{ endfor ~}
%{ else ~}
# No automations rendered: either homeassist_notify_devices is empty or no
# camera has notifications=true. Set notifications=true on a frigate_cameras
# entry AND add device IDs to var.homeassist_notify_devices to enable.
# Empty list keeps !include_dir_named happy (package becomes a no-op).
automation: []
%{ endif ~}
