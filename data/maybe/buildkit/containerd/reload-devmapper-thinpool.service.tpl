[Unit]
Description=Devmapper reload script

[Service]
ExecStart=/usr/local/bin/reload-devmapper-thinpool.sh

[Install]
WantedBy=multi-user.target
