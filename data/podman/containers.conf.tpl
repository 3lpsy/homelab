[containers]
default_sysctls = [
"net.ipv4.ping_group_range=0 0",
]
log_driver = "journald"

[engine]
runtime = "kata"

[engine.runtimes]
kata = ["/usr/bin/kata-runtime"]
