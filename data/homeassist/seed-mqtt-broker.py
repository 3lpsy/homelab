"""Pre-wires the HA MQTT integration so the broker config-flow does not have
to be done by hand, and so Vault rotations of homeassist/mosquitto:ha_password
flow through to HA on the next pod restart.

First boot (file missing): seeds /config/.storage/core.config_entries with one
MQTT entry pointing at the in-cluster mosquitto Service. Schema follows HA's
core_config_entries STORAGE_VERSION at the time of writing; HA's storage
manager auto-migrates on read if the schema bumps.

Subsequent boots: parses the existing file, finds the entry whose
`domain == "mqtt"`, and patches data.{broker,port,username,password} in place.
Other entries (UI-added integrations) are left alone. Self-healing: if the
user deletes the MQTT integration via the UI, the next pod restart re-adds it.

Reads the password from /mnt/secrets/ha_password (CSI-mounted from Vault) at
runtime so the password never lands in a ConfigMap or image layer.
"""

import json
import os
import uuid
from datetime import datetime, timezone

PATH = "/config/.storage/core.config_entries"
BROKER = "mosquitto.homeassist.svc.cluster.local"
PORT = 1883
USERNAME = "ha"
PASSWORD_FILE = "/mnt/secrets/ha_password"


def make_entry(password: str, now: str) -> dict:
    return {
        "created_at": now,
        "data": {
            "broker": BROKER,
            "port": PORT,
            "username": USERNAME,
            "password": password,
            "discovery": True,
            "discovery_prefix": "homeassistant",
        },
        "disabled_by": None,
        "discovery_keys": {},
        "domain": "mqtt",
        "entry_id": uuid.uuid5(uuid.NAMESPACE_DNS, "homeassist-mqtt").hex,
        "minor_version": 2,
        "modified_at": now,
        "options": {},
        "pref_disable_new_entities": False,
        "pref_disable_polling": False,
        "source": "user",
        "subentries": [],
        "title": "Mosquitto",
        "unique_id": None,
        "version": 1,
    }


def main() -> None:
    with open(PASSWORD_FILE) as f:
        password = f.read().strip()
    now = datetime.now(timezone.utc).isoformat()

    if os.path.exists(PATH):
        with open(PATH) as f:
            cfg = json.load(f)
        entries = cfg.setdefault("data", {}).setdefault("entries", [])
        mqtt = next((e for e in entries if e.get("domain") == "mqtt"), None)
        if mqtt:
            mqtt.setdefault("data", {})
            mqtt["data"]["broker"] = BROKER
            mqtt["data"]["port"] = PORT
            mqtt["data"]["username"] = USERNAME
            mqtt["data"]["password"] = password
            mqtt["modified_at"] = now
            print("Patched existing MQTT config_entry password")
        else:
            entries.append(make_entry(password, now))
            print("Appended MQTT config_entry to existing file")
    else:
        os.makedirs(os.path.dirname(PATH), exist_ok=True)
        cfg = {
            "version": 1,
            "minor_version": 5,
            "key": "core.config_entries",
            "data": {"entries": [make_entry(password, now)]},
        }
        print("Seeded new core.config_entries with MQTT entry")

    tmp = PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=4)
    os.replace(tmp, PATH)


if __name__ == "__main__":
    main()
