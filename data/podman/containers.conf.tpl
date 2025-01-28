[containers]
default_sysctls = [
"net.ipv4.ping_group_range=0 0",
]
log_driver = "journald"
[secrets]
[secrets.opts]
[network]
[engine]
runtime = "runc"
[engine.runtimes]
[engine.volume_plugins]
[machine]
[farms]
[podmansh]
