[Unit]
Description=Heal headscale OIDC-discovery startup deadlock
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/headscale-oidc-watchdog.sh
