SHELL=/bin/bash
PATH=/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Run backup script as headscale user on the 1st of every month at midnight
0 0 1 * * headscale /usr/local/bin/backup-headscale.sh >> /var/log/backup-headscale.log 2>&1
