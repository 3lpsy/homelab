[Unit]
Description=Kopia snapshot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/kopia/env
ExecStart=/usr/bin/kopia snapshot create ${snapshot_args}
ExecStartPost=/usr/bin/kopia maintenance run --safety=full
SuccessExitStatus=0
TimeoutStartSec=4h
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target
