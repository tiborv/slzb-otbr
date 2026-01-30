# =============================================================================
# SLZB-OTBR: OpenThread Border Router for Networked Thread Radios
# =============================================================================
# This image wraps the official OpenThread Border Router with support for
# network-connected Thread radios like SLZB-MR1, providing a drop-in solution
# for Docker-based Home Assistant deployments.
# =============================================================================

# Base image reference - override via build-arg for pinned builds
# CI passes per-arch digests, local builds use :latest
ARG BASE_IMAGE=openthread/border-router:latest
FROM ${BASE_IMAGE}

# Install additional tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        socat \
        curl \
        jq \
        netcat-openbsd \
        iproute2 \
        avahi-daemon \
        avahi-utils \
        python3 \
        python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install zeroconf --break-system-packages

# Copy scripts
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/otbr_manager.py

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Copy dependency test script
COPY test-deps.sh /test-deps.sh
RUN chmod +x /test-deps.sh

# =============================================================================
# Environment Variables
# =============================================================================
# Required:
#   SLZB_HOST         - IP address or hostname of the SLZB device
#
# Optional (Thread radio):
#   SLZB_PORT         - Port for the radio (default: 6638)
#   SERIAL_DEVICE     - Virtual serial device path (default: /dev/ttyACM0)
#   BAUD_RATE         - Baud rate for RCP communication (default: 460800)
#
# Optional (Thread network credentials):
#   THREAD_DATASET_TLV - Hex-encoded Thread dataset TLV (highest priority)
#   HA_URL            - Home Assistant URL to fetch credentials from API
#   HA_TOKEN          - Home Assistant Long-Lived Access Token
#   HA_STORAGE_PATH   - Path to HA .storage/thread.datasets (default: /config/.storage/thread.datasets)
#
# Optional (OTBR configuration):
#   OT_THREAD_IF      - Thread interface name (default: wpan0)
#   OT_INFRA_IF       - Backhaul interface (detected automatically if not set)
#   OT_LOG_LEVEL      - Log level 1-7 (default: 5)
#   OT_REST_LISTEN_PORT - REST API port (default: 8081)
# =============================================================================

ENV SLZB_HOST=""
ENV SLZB_PORT="6638"
ENV SERIAL_DEVICE="/dev/ttyACM0"
ENV BAUD_RATE="460800"

ENV THREAD_DATASET_TLV=""
ENV HA_URL=""
ENV HA_TOKEN=""
ENV HA_STORAGE_PATH="/config/.storage/thread.datasets"
ENV TLV_FILE_PATH=""
ENV TLV_EXPORT_PATH="/data/dataset.hex"
ENV AUTO_EXTRACT="false"
ENV AUTO_EXTRACT_INTERVAL="300"

ENV OT_THREAD_IF="wpan0"
ENV OT_INFRA_IF=""
ENV OT_LOG_LEVEL="5"
ENV OT_REST_LISTEN_ADDR="0.0.0.0"
ENV OT_REST_LISTEN_PORT="8081"

# Expose REST API
EXPOSE 8081

ENTRYPOINT ["/entrypoint.sh"]
