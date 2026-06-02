[Unit]
Description=Schedule kopia snapshots
Requires=kopia-backup.service

[Timer]
OnCalendar=${on_calendar}
RandomizedDelaySec=1h
Persistent=true
AccuracySec=1m

[Install]
WantedBy=timers.target
