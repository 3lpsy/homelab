# Use the official Ubuntu image as the base
FROM ubuntu:latest
# Set environment variable to prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
# Update the package list and install dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    python3-setuptools \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Radicale

RUN python3 -m venv /opt/venv && source /opt/venv/bin/activate && /opt/venv/bin/pip install --no-cache-dir radicale
# Create a non-root user for security
RUN useradd -ms /bin/bash radicale

# Create a directory to store Radicale data and set permissions
RUN mkdir -p /var/lib/radicale/collections && chown radicale:radicale /var/lib/radicale/collections
RUN mkdir -p /etc/radicale && chown radicale:radicale /etc/radicale

# Expose the default Radicale port
EXPOSE 5232

# Switch to the non-root user
USER radicale

# Set the working directory
WORKDIR /home/radicale

# Run Radicale in the foreground with the data directory specified
ENTRYPOINT [ "/opt/venv/bin/radicale", "--storage-filesystem-folder=/var/lib/radicale/collections", "--logging-level=info", "--server-hosts=127.0.0.1:5232", "--server-max-connections=5", "--server-max-content-length=100000000", "--server-timeout=30", "--auth-type=http_x_remote_user", "--auth-htpasswd-filename=/etc/radicale/users", "--auth-htpasswd-encryption=md5", "--auth-delay=2", "--web-type=none" ]
