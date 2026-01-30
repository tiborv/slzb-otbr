#!/bin/bash
set -e

# =============================================================================
# SLZB-OTBR Entrypoint (Simplified)
# Connects to a networked Thread radio (SLZB-MR1, etc.) and runs OTBR.
# =============================================================================

log() {
    echo "[$(date -Iseconds)] $1"
}

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
if [ -z "$SLZB_HOST" ]; then
    log "ERROR: SLZB_HOST environment variable is required"
    log "Example: -e SLZB_HOST=192.168.1.235"
    exit 1
fi

SLZB_PORT="${SLZB_PORT:-6638}"
SERIAL_DEVICE="${SERIAL_DEVICE:-/dev/ttyACM0}"
BAUD_RATE="${BAUD_RATE:-460800}"
MDNS_PUBLISH="${MDNS_PUBLISH:-true}"

log "Configuration:"
log "  SLZB_HOST: $SLZB_HOST"
log "  SLZB_PORT: $SLZB_PORT"
log "  MDNS_PUBLISH: $MDNS_PUBLISH"

# -----------------------------------------------------------------------------
# Infrastructure Interface
# -----------------------------------------------------------------------------
if [ -z "$OT_INFRA_IF" ]; then
    DETECTED_IF=$(ip route | grep default | head -n 1 | awk '{print $5}')
    if [ -n "$DETECTED_IF" ]; then
        export OT_INFRA_IF="$DETECTED_IF"
        log "Auto-detected infrastructure interface: $OT_INFRA_IF"
    else
        log "WARNING: Could not auto-detect infrastructure interface. OTBR may fail to start."
    fi
else
    log "Using provided infrastructure interface: $OT_INFRA_IF"
fi

# Set RCP device URL
export OT_RCP_DEVICE="spinel+hdlc+uart://${SERIAL_DEVICE}?uart-baudrate=${BAUD_RATE}&bus-latency=50000"

# -----------------------------------------------------------------------------
# Socat Bridge
# -----------------------------------------------------------------------------
log "Starting socat bridge to $SLZB_HOST:$SLZB_PORT..."
(
    while true; do
        socat -d -d pty,raw,echo=0,link=${SERIAL_DEVICE},ignoreeof tcp:${SLZB_HOST}:${SLZB_PORT},keepalive,nodelay,keepidle=10,keepintvl=10,keepcnt=3
        log "WARNING: socat bridge exited, restarting in 1 second..."
        sleep 1
    done
) &
SOCAT_PID=$!

# -----------------------------------------------------------------------------
# OTBR Configuration & Routing
# -----------------------------------------------------------------------------
(
    log "Waiting for ${SERIAL_DEVICE}..."
    for i in $(seq 1 30); do
        if [ -e "${SERIAL_DEVICE}" ]; then
            break
        fi
        if ! kill -0 $SOCAT_PID 2>/dev/null; then
            log "ERROR: socat process died."
            exit 1
        fi
        sleep 1
    done

    if [ ! -e "${SERIAL_DEVICE}" ]; then
        log "ERROR: Timeout waiting for ${SERIAL_DEVICE}"
        exit 1
    fi

    log "Waiting for OTBR agent..."
    until ot-ctl -I $OT_THREAD_IF state > /dev/null 2>&1; do
        sleep 2
    done
    log "OTBR agent is ready"

    # Disable Backbone Router (often causes issues in Docker/K8s)
    ot-ctl -I $OT_THREAD_IF bbr disable || true

    # -------------------------------------------------------------------------
    # System Services (D-Bus / Avahi / SRP)
    # Required for OTBR Agent's SRP Server
    # -------------------------------------------------------------------------
    log "Starting system services (D-Bus & Avahi)..."
    mkdir -p /var/run/dbus
    rm -f /var/run/dbus/pid
    dbus-daemon --system --fork 2>/dev/null || true
    
    mkdir -p /var/run/avahi-daemon
    chown avahi:avahi /var/run/avahi-daemon || true
    avahi-daemon --daemonize --no-chroot || log "WARNING: avahi-daemon failed to start"
    
    # Enable SRP Server
    ot-ctl -I $OT_THREAD_IF srp server enable || true

    # -------------------------------------------------------------------------
    # Thread Provisioning
    # -------------------------------------------------------------------------
    if [ -n "$THREAD_DATASET_TLV" ]; then
         current_tlv=$(ot-ctl -I $OT_THREAD_IF dataset active -x 2>/dev/null | tr -d '\r' | head -n 1 | tr -d '[:space:]')
         if [ -z "$current_tlv" ] || [ "$current_tlv" = "0e080000000000000000" ]; then 
             log "Applying THREAD_DATASET_TLV from environment..."
             ot-ctl -I $OT_THREAD_IF dataset set active "$THREAD_DATASET_TLV"
             ot-ctl -I $OT_THREAD_IF dataset commit active
         fi
    fi
    
    # Ensure interface is up and thread is started
    ot-ctl -I $OT_THREAD_IF ifconfig up
    ot-ctl -I $OT_THREAD_IF thread start

    # -------------------------------------------------------------------------
    # Launch OTBR Manager (Smart Routing + mDNS)
    # -------------------------------------------------------------------------
    log "Starting OTBR Manager..."
    /usr/local/bin/otbr_manager.py &

) >/tmp/entrypoint_loop.log 2>&1 &

# -----------------------------------------------------------------------------
# Start OTBR
# -----------------------------------------------------------------------------
log "Starting OTBR..."
exec /init
