[hypervisor.firecracker]
path = "/usr/local/bin/firecracker"
kernel = "/opt/kata/share/kata-containers/vmlinux.container"
image = "/opt/kata/share/kata-containers/kata-containers.img"
rootfs_type="ext4"
enable_annotations = ["kernel_params"]
# enable_annotations = ["enable_iommu", "virtio_fs_extra_args", "kernel_params"]
valid_hypervisor_paths = ["/usr/local/bin/firecracker"]
jailer_path = "/usr/local/bin/jailer"
valid_jailer_paths = ["/usr/local/bin/jailer"]
kernel_params = ""
default_vcpus = 1
default_maxvcpus = 0
default_bridges = 1
default_memory = 2048
#memory_slots = 10
#memory_offset = 0
default_maxmemory = 0

# Block storage driver to be used for the hypervisor in case the container
# rootfs is backed by a block device. This is virtio-scsi, virtio-blk
# or nvdimm.
block_device_driver = "virtio-mmio"
#block_device_cache_set = true
#block_device_cache_noflush = true

# Enable pre allocation of VM RAM, default false
# Enabling this will result in lower container density
# as all of the memory will be allocated and locked
# This is useful when you want to reserve all the memory
# upfront or in the cases where you want memory latencies
# to be very predictable
# Default false
#enable_mem_prealloc = true

# Enable huge pages for VM RAM, default false
# Enabling this will result in the VM memory
# being allocated using huge pages.
# This is useful when you want to use vhost-user network
# stacks within the container. This will automatically
# result in memory pre allocation
#enable_hugepages = true

# Enable vIOMMU, default false
# Enabling this will result in the VM having a vIOMMU device
# This will also add the following options to the kernel's
# command line: intel_iommu=on,iommu=pt
#enable_iommu = true

# This option changes the default hypervisor and kernel parameters
# to enable debug output where available.
#
# Default false
#enable_debug = true

# Disable the customizations done in the runtime when it detects
# that it is running on top a VMM. This will result in the runtime
# behaving as it would when running on bare metal.
#
#disable_nesting_checks = true

# This is the msize used for 9p shares. It is the number of bytes
# used for 9p packet payload.
#msize_9p = 8192

# VFIO devices are hotplugged on a bridge by default.
# Enable hotplugging on root bus. This may be required for devices with
# a large PCI bar, as this is a current limitation with hotplugging on
# a bridge.
# Default false
#hotplug_vfio_on_root_bus = true

#
# Default entropy source.
# The path to a host source of entropy (including a real hardware RNG)
# /dev/urandom and /dev/random are two main options.
# Be aware that /dev/random is a blocking source of entropy.  If the host
# runs out of entropy, the VMs boot time will increase leading to get startup
# timeouts.
# The source of entropy /dev/urandom is non-blocking and provides a
# generally acceptable source of entropy. It should work well for pretty much
# all practical purposes.
#entropy_source= "/dev/urandom"

# List of valid annotations values for entropy_source
# The default if not set is empty (all annotations rejected.)
# Your distribution recommends: ["/dev/urandom","/dev/random",""]
valid_entropy_sources = ["/dev/urandom","/dev/random",""]

# Path to OCI hook binaries in the *guest rootfs*.
# This does not affect host-side hooks which must instead be added to
# the OCI spec passed to the runtime.
#
# You can create a rootfs with hooks by customizing the osbuilder scripts:
# https://github.com/kata-containers/kata-containers/tree/main/tools/osbuilder
#
# Hooks must be stored in a subdirectory of guest_hook_path according to their
# hook type, i.e. "guest_hook_path/{prestart,poststart,poststop}".
# The agent will scan these directories for executable files and add them, in
# lexicographical order, to the lifecycle of the guest container.
# Hooks are executed in the runtime namespace of the guest. See the official documentation:
# https://github.com/opencontainers/runtime-spec/blob/v1.0.1/config.md#posix-platform-hooks
# Warnings will be logged if any error is encountered will scanning for hooks,
# but it will not abort container execution.
#guest_hook_path = "/usr/share/oci/hooks"
#
# Use rx Rate Limiter to control network I/O inbound bandwidth(size in bits/sec for SB/VM).
# In Firecracker, it provides a built-in rate limiter, which is based on TBF(Token Bucket Filter)
# queueing discipline.
# Default 0-sized value means unlimited rate.
#rx_rate_limiter_max_rate = 0
# Use tx Rate Limiter to control network I/O outbound bandwidth(size in bits/sec for SB/VM).
# In Firecracker, it provides a built-in rate limiter, which is based on TBF(Token Bucket Filter)
# queueing discipline.
# Default 0-sized value means unlimited rate.
#tx_rate_limiter_max_rate = 0

# disable applying SELinux on the VMM process (default false)
disable_selinux=false

[factory]
# VM templating support. Once enabled, new VMs are created from template
# using vm cloning. They will share the same initial kernel, initramfs and
# agent memory by mapping it readonly. It helps speeding up new container
# creation and saves a lot of memory if there are many kata containers running
# on the same host.
#
# When disabled, new VMs are created from scratch.
#
# Note: Requires "initrd=" to be set ("image=" is not supported).
#
# Default false
#enable_template = true

[agent.kata]
# If enabled, make the agent display debug-level messages.
# (default: disabled)
#enable_debug = true

# Enable agent tracing.
#
# If enabled, the agent will generate OpenTelemetry trace spans.
#
# Notes:
#
# - If the runtime also has tracing enabled, the agent spans will be
#   associated with the appropriate runtime parent span.
# - If enabled, the runtime will wait for the container to shutdown,
#   increasing the container shutdown time slightly.
#
# (default: disabled)
#enable_tracing = true

# Comma separated list of kernel modules and their parameters.
# These modules will be loaded in the guest kernel using modprobe(8).
# The following example can be used to load two kernel modules with parameters
#  - kernel_modules=["e1000e InterruptThrottleRate=3000,3000,3000 EEE=1", "i915 enable_ppgtt=0"]
# The first word is considered as the module name and the rest as its parameters.
# Container will not be started when:
#  * A kernel module is specified and the modprobe command is not installed in the guest
#    or it fails loading the module.
#  * The module is not available in the guest or it doesn't met the guest kernel
#    requirements, like architecture and version.
#
kernel_modules=[]

# Enable debug console.

# If enabled, user can connect guest OS running inside hypervisor
# through "kata-runtime exec <sandbox-id>" command

#debug_console_enabled = true

# Agent connection dialing timeout value in seconds
# (default: 45)
dial_timeout = 45

# Confidential Data Hub API timeout value in seconds
# (default: 50)
#cdh_api_timeout = 50

[runtime]
# If enabled, the runtime will log additional debug messages to the
# system log
# (default: disabled)
#enable_debug = true
#
# Internetworking model
# Determines how the VM should be connected to the
# the container network interface
# Options:
#
#   - macvtap
#     Used when the Container network interface can be bridged using
#     macvtap.
#
#   - none
#     Used when customize network. Only creates a tap device. No veth pair.
#
#   - tcfilter
#     Uses tc filter rules to redirect traffic from the network interface
#     provided by plugin to a tap interface connected to the VM.
#
internetworking_model="none"

# disable guest seccomp
# Determines whether container seccomp profiles are passed to the virtual
# machine and applied by the kata agent. If set to true, seccomp is not applied
# within the guest
# (default: true)
disable_guest_seccomp=true

# If enabled, the runtime will create opentracing.io traces and spans.
# (See https://www.jaegertracing.io/docs/getting-started).
# (default: disabled)
#enable_tracing = true

# Set the full url to the Jaeger HTTP Thrift collector.
# The default if not set will be "http://localhost:14268/api/traces"
#jaeger_endpoint = ""

# Sets the username to be used if basic auth is required for Jaeger.
#jaeger_user = ""

# Sets the password to be used if basic auth is required for Jaeger.
#jaeger_password = ""

# If enabled, the runtime will not create a network namespace for shim and hypervisor processes.
# This option may have some potential impacts to your host. It should only be used when you know what you're doing.
# `disable_new_netns` conflicts with `internetworking_model=tcfilter` and `internetworking_model=macvtap`. It works only
# with `internetworking_model=none`. The tap device will be in the host network namespace and can connect to a bridge
# (like OVS) directly.
# (default: false)
#disable_new_netns = true

# if enabled, the runtime will add all the kata processes inside one dedicated cgroup.
# The container cgroups in the host are not created, just one single cgroup per sandbox.
# The runtime caller is free to restrict or collect cgroup stats of the overall Kata sandbox.
# The sandbox cgroup path is the parent cgroup of a container with the PodSandbox annotation.
# The sandbox cgroup is constrained if there is no container type annotation.
# See: https://pkg.go.dev/github.com/kata-containers/kata-containers/src/runtime/virtcontainers#ContainerType
sandbox_cgroup_only=false

# If enabled, the runtime will attempt to determine appropriate sandbox size (memory, CPU) before booting the virtual machine. In
# this case, the runtime will not dynamically update the amount of memory and CPU in the virtual machine. This is generally helpful
# when a hardware architecture or hypervisor solutions is utilized which does not support CPU and/or memory hotplug.
# Compatibility for determining appropriate sandbox (VM) size:
# - When running with pods, sandbox sizing information will only be available if using Kubernetes >= 1.23 and containerd >= 1.6. CRI-O
#   does not yet support sandbox sizing annotations.
# - When running single containers using a tool like ctr, container sizing information will be available.
static_sandbox_resource_mgmt=true

# If enabled, the runtime will not create Kubernetes emptyDir mounts on the guest filesystem. Instead, emptyDir mounts will
# be created on the host and shared via virtio-fs. This is potentially slower, but allows sharing of files from host to guest.
disable_guest_empty_dir=false

# Enabled experimental feature list, format: ["a", "b"].
# Experimental features are features not stable enough for production,
# they may break compatibility, and are prepared for a big version bump.
# Supported experimental features:
# (default: [])
experimental=[]

# If enabled, user can run pprof tools with shim v2 process through kata-monitor.
# (default: false)
# enable_pprof = true

# Indicates the CreateContainer request timeout needed for the workload(s)
# It using guest_pull this includes the time to pull the image inside the guest
# Defaults to 60 second(s)
# Note: The effective timeout is determined by the lesser of two values: runtime-request-timeout from kubelet config
# (https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/#:~:text=runtime%2Drequest%2Dtimeout) and create_container_timeout.
# In essence, the timeout used for guest pull=runtime-request-timeout<create_container_timeout?runtime-request-timeout:create_container_timeout.
create_container_timeout = 60

# Base directory of directly attachable network config.
# Network devices for VM-based containers are allowed to be placed in the
# host netns to eliminate as many hops as possible, which is what we
# called a "Directly Attachable Network". The config, set by special CNI
# plugins, is used to tell the Kata containers what devices are attached
# to the hypervisor.
# (default: /run/kata-containers/dans)
dan_conf = "/run/kata-containers/dans"
