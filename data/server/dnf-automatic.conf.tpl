[commands]
upgrade_type = default
random_sleep = 0
network_online_timeout = 60
download_updates = yes
apply_updates = yes

[emitters]
emit_via = stdio

[email]
email_from = root@localhost
email_to = root
email_host = localhost

[command]
[command_email]
email_from = root@localhost
email_to = root

[base]
debuglevel = 1
# Block in-place upgrades of the COPR-sourced Coral driver. coral_dkms in
# node-provision-server/main.tf sed-patches /usr/src/gasket-*/ for kernel-6.13+
# compile; a package upgrade re-extracts source, blowing away the patches and
# breaking DKMS on the next kernel rebuild.
excludepkgs = gasket-dkms
