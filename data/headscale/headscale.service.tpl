[Unit]
Description=headscale controller
After=syslog.target
After=network.target

[Service]
Type=simple
User=headscale
Group=headscale
ExecStartPre=/usr/local/bin/headscale-merge-config.sh
ExecStart=/usr/local/bin/headscale serve --config /run/headscale/config.yaml
Restart=always
RestartSec=5

# Optional security enhancement
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
WorkingDirectory=/var/lib/headscale
ReadWritePaths=/var/lib/headscale /var/run/headscale
AmbientCapabilities=CAP_NET_BIND_SERVICE
RuntimeDirectory=headscale
RuntimeDirectoryMode=0750

[Install]
WantedBy=multi-user.target
