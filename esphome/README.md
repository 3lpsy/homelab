# esphome/

ESPHome device configs for homelab IR/sensor/etc. devices that live on the
LAN (not in the K3s cluster). Built and flashed from this workstation via
Podman; HA pairs them by LAN IP.

## Layout

| File | Committed | Notes |
|---|---|---|
| `<device>.yaml` | yes | One per device. References `!secret` keys. |
| `secrets.yaml.tpl` | yes | envsubst placeholders for every device's secrets. |
| `secrets.yaml` | no (gitignored) | Rendered fresh by `run.sh` on every invocation. |
| `run.sh` | yes | Wrapper: sources the private `.env.esphome`, renders secrets, runs podman. |
| `.esphome/`, `*.bin` | no (gitignored) | ESPHome build artifacts. |

Private values live in `$HOME/Playground/private/envs/homelab/.env.esphome`
(same dir the terraform state lives in — outside the repo). Copy from
`<repo>/.env.esphome.example` and fill in. The path is hard-coded in
`run.sh`; edit that file if it ever moves.

## Usage

```sh
# First USB flash (XIAO plugged into USB-C; hold BOOT + tap RESET if
# auto-reset fails to enter download mode)
./esphome/run.sh esp32c6-dreo-fan-1.yaml

# Subsequent OTA after the device is on Wi-Fi
./esphome/run.sh esp32c6-dreo-fan-1.yaml

# Tail logs only, no rebuild
./esphome/run.sh esp32c6-dreo-fan-1.yaml logs
```

`run.sh` does:

1. Source the private `.env.esphome` (path hard-coded in the script).
2. `envsubst < secrets.yaml.tpl > secrets.yaml`
3. `podman run --rm -it -v .:/config:Z [--device=/dev/ttyACM0] ghcr.io/esphome/esphome:latest run <yaml>`

If `/dev/ttyACM0` doesn't exist at run time, the `--device` flag is
omitted and the build falls back to OTA (must already have a flashed
device on the network).

## Adding a new device

1. Copy an existing `*.yaml` to `<new-name>.yaml`. Update `esphome.name`,
   `friendly_name`, AP fallback SSID, and the `!secret` keys it
   references (e.g. `<new_name>_api_key`, `<new_name>_ota_password`).
2. Add `<new_name>_api_key` and `<new_name>_ota_password` to
   `secrets.yaml.tpl` and matching `ESPHOME_<NEW_NAME>_API_KEY` /
   `ESPHOME_<NEW_NAME>_OTA_PASSWORD` to the private `.env.esphome` (and
   the committed `.env.esphome.example`).
3. Generate keys: `openssl rand -base64 32` (api), `openssl rand -hex 16` (ota).
4. Wire hardware, plug into USB, run `./esphome/run.sh <new-name>.yaml`.
5. Pair in HA: Settings → Devices & Services → Add Integration → ESPHome
   → host=LAN IP (or `<name>.local`), port=6053, encryption key from
   `.env.esphome`.
