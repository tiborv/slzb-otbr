#!/bin/bash
set -e

# =============================================================================
# SLZB-OTBR Entrypoint
# Connects to a networked Thread radio (SLZB-MR1, etc.) and runs OpenThread
# Border Router with flexible credential provisioning including automatic
# extraction from Home Assistant.
# =============================================================================

log() {
    echo "[$(date -Iseconds)] $1"
}

# -----------------------------------------------------------------------------
# Step 1: Validate required configuration
# -----------------------------------------------------------------------------
if [ -z "$SLZB_HOST" ]; then
    log "ERROR: SLZB_HOST environment variable is required"
    log "Example: -e SLZB_HOST=192.168.1.235"
    exit 1
fi

SLZB_PORT="${SLZB_PORT:-6638}"
SERIAL_DEVICE="${SERIAL_DEVICE:-/dev/ttyACM0}"
BAUD_RATE="${BAUD_RATE:-460800}"

# Auto-extraction settings
AUTO_EXTRACT="${AUTO_EXTRACT:-false}"
AUTO_EXTRACT_INTERVAL="${AUTO_EXTRACT_INTERVAL:-300}"  # 5 minutes

log "Configuration:"
log "  SLZB_HOST: $SLZB_HOST"
log "  SLZB_PORT: $SLZB_PORT"
log "  AUTO_EXTRACT: $AUTO_EXTRACT"

# -----------------------------------------------------------------------------
# Step 2: Start socat bridge to networked radio
# -----------------------------------------------------------------------------
log "Starting socat bridge to $SLZB_HOST:$SLZB_PORT..."
socat -d -d pty,raw,echo=0,link=${SERIAL_DEVICE},ignoreeof tcp:${SLZB_HOST}:${SLZB_PORT} &
SOCAT_PID=$!

# Wait for the PTY device to be created
log "Waiting for ${SERIAL_DEVICE}..."
for i in $(seq 1 30); do
    if [ -e "${SERIAL_DEVICE}" ]; then
        log "Device ${SERIAL_DEVICE} created successfully"
        break
    fi
    if ! kill -0 $SOCAT_PID 2>/dev/null; then
        log "ERROR: socat process died. Check network connectivity to $SLZB_HOST:$SLZB_PORT"
        exit 1
    fi
    sleep 1
done

if [ ! -e "${SERIAL_DEVICE}" ]; then
    log "ERROR: Timeout waiting for ${SERIAL_DEVICE}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 3: Configure OTBR environment
# -----------------------------------------------------------------------------
export OT_THREAD_IF="${OT_THREAD_IF:-wpan0}"
export OT_LOG_LEVEL="${OT_LOG_LEVEL:-5}"
export OT_VENDOR_NAME="${OT_VENDOR_NAME:-SLZB-OTBR}"
export OT_VENDOR_MODEL="${OT_VENDOR_MODEL:-OpenThread Border Router}"
export NAT64="${NAT64:-0}"
export OTBR_BACKBONE_ROUTER="${OTBR_BACKBONE_ROUTER:-0}"
export BACKBONE_ROUTER="${BACKBONE_ROUTER:-0}"
export OT_INFRA_IF="${OT_INFRA_IF:-eth0}"
export OT_RCP_DEVICE="spinel+hdlc+uart://${SERIAL_DEVICE}?uart-baudrate=${BAUD_RATE}"
export OT_REST_LISTEN_ADDR="${OT_REST_LISTEN_ADDR:-0.0.0.0}"
export OT_REST_LISTEN_PORT="${OT_REST_LISTEN_PORT:-8081}"

log "OTBR Configuration:"
log "  OT_THREAD_IF: $OT_THREAD_IF"
log "  OT_REST_LISTEN_PORT: $OT_REST_LISTEN_PORT"

# -----------------------------------------------------------------------------
# Step 4: Start OTBR in background
# -----------------------------------------------------------------------------
log "Starting OTBR..."
/init &
OTBR_PID=$!

# Wait for OTBR agent to be ready
log "Waiting for OTBR agent to be ready..."
until ot-ctl -I $OT_THREAD_IF state > /dev/null 2>&1; do
    if ! kill -0 $OTBR_PID 2>/dev/null; then
        log "ERROR: OTBR process died unexpectedly"
        exit 1
    fi
    sleep 2
done
log "OTBR agent is ready"

# Disable Backbone Router (causes issues in containerized environments)
ot-ctl -I $OT_THREAD_IF bbr disable || true

# -----------------------------------------------------------------------------
# Step 5: TLV Extraction Functions
# -----------------------------------------------------------------------------

# Fetch TLV from Home Assistant Thread API
fetch_tlv_from_ha() {
    if [ -z "$HA_URL" ] || [ -z "$HA_TOKEN" ]; then
        return 1
    fi
    
    # Try the preferred Thread credentials endpoint
    TLV=$(curl -sf -H "Authorization: Bearer $HA_TOKEN" \
          "${HA_URL}/api/thread/dataset/tlvs" 2>/dev/null | jq -r '.[0].dataset // empty')
    
    if [ -z "$TLV" ]; then
        # Fallback to older API
        TLV=$(curl -sf -H "Authorization: Bearer $HA_TOKEN" \
              "${HA_URL}/api/thread/datasets" 2>/dev/null | jq -r '.[0].dataset_tlv // empty')
    fi
    
    echo "$TLV"
}

# Export current OTBR dataset to a file (for HA to pick up)
export_current_dataset() {
    local output_file="${TLV_EXPORT_PATH:-/data/dataset.hex}"
    local dataset=$(ot-ctl -I $OT_THREAD_IF dataset active -x 2>/dev/null | head -n 1)
    
    if [ -n "$dataset" ] && [ "$dataset" != "Error 23: NotFound" ]; then
        echo "$dataset" > "$output_file"
        log "Exported active dataset to $output_file"
        return 0
    fi
    return 1
}

# Apply a TLV dataset to OTBR
apply_tlv() {
    local tlv="$1"
    if [ -z "$tlv" ]; then
        return 1
    fi
    
    log "Applying TLV dataset..."
    ot-ctl -I $OT_THREAD_IF thread stop || true
    ot-ctl -I $OT_THREAD_IF ifconfig down || true
    ot-ctl -I $OT_THREAD_IF dataset set active "$tlv"
    ot-ctl -I $OT_THREAD_IF dataset commit active
    ot-ctl -I $OT_THREAD_IF ifconfig up
    ot-ctl -I $OT_THREAD_IF thread start
    log "TLV applied and Thread network restarted"
    return 0
}

# Check if current dataset matches provided TLV
dataset_matches() {
    local target_tlv="$1"
    local current_tlv=$(ot-ctl -I $OT_THREAD_IF dataset active -x 2>/dev/null | head -n 1)
    [ "$current_tlv" = "$target_tlv" ]
}

# -----------------------------------------------------------------------------
# Step 6: Provision Thread network credentials
# -----------------------------------------------------------------------------
provision_network() {
    # Priority 1: Explicit TLV provided via environment
    if [ -n "$THREAD_DATASET_TLV" ]; then
        log "Provisioning with provided THREAD_DATASET_TLV..."
        ot-ctl -I $OT_THREAD_IF dataset set active "$THREAD_DATASET_TLV"
        ot-ctl -I $OT_THREAD_IF dataset commit active
        return 0
    fi

    # Priority 2: Fetch from Home Assistant API
    if [ -n "$HA_URL" ] && [ -n "$HA_TOKEN" ]; then
        log "Fetching Thread credentials from Home Assistant..."
        TLV=$(fetch_tlv_from_ha)
        if [ -n "$TLV" ]; then
            log "Provisioning with credentials from Home Assistant..."
            ot-ctl -I $OT_THREAD_IF dataset set active "$TLV"
            ot-ctl -I $OT_THREAD_IF dataset commit active
            return 0
        else
            log "WARNING: Could not fetch TLV from Home Assistant"
        fi
    fi

    # Priority 3: Read from file (for manual provisioning or shared volume)
    if [ -n "$TLV_FILE_PATH" ] && [ -f "$TLV_FILE_PATH" ]; then
        TLV=$(cat "$TLV_FILE_PATH" | tr -d '[:space:]')
        if [ -n "$TLV" ]; then
            log "Provisioning with TLV from file: $TLV_FILE_PATH"
            ot-ctl -I $OT_THREAD_IF dataset set active "$TLV"
            ot-ctl -I $OT_THREAD_IF dataset commit active
            return 0
        fi
    fi

    # Priority 4: Check if we already have an active dataset (from persistent storage)
    if ! ot-ctl -I $OT_THREAD_IF dataset active 2>&1 | grep -q "Error 23"; then
        log "Using existing active dataset from persistent storage"
        return 0
    fi

    # Priority 5: Form a new network
    log "No credentials found, forming new Thread network..."
    ot-ctl -I $OT_THREAD_IF dataset init new
    ot-ctl -I $OT_THREAD_IF dataset commit active
    log "New network formed. Export with: docker exec <container> ot-ctl dataset active -x"
    return 0
}

provision_network

# -----------------------------------------------------------------------------
# Step 7: Start Thread network
# -----------------------------------------------------------------------------
log "Bringing up Thread interface..."
ot-ctl -I $OT_THREAD_IF ifconfig up
ot-ctl -I $OT_THREAD_IF thread start

log "Thread network started. REST API available on port $OT_REST_LISTEN_PORT"

# Export current dataset
sleep 3
export_current_dataset
DATASET=$(ot-ctl -I $OT_THREAD_IF dataset active -x | head -n 1)
log "Active Dataset TLV: $DATASET"

# -----------------------------------------------------------------------------
# Step 8: Auto-extraction loop (optional)
# -----------------------------------------------------------------------------
if [ "$AUTO_EXTRACT" = "true" ] && [ -n "$HA_URL" ] && [ -n "$HA_TOKEN" ]; then
    log "Starting auto-extraction loop (interval: ${AUTO_EXTRACT_INTERVAL}s)..."
    (
        while true; do
            sleep "$AUTO_EXTRACT_INTERVAL"
            
            NEW_TLV=$(fetch_tlv_from_ha)
            if [ -n "$NEW_TLV" ]; then
                if ! dataset_matches "$NEW_TLV"; then
                    log "Detected credential change in Home Assistant, updating..."
                    apply_tlv "$NEW_TLV"
                    export_current_dataset
                fi
            fi
            
            # Also periodically export current dataset
            export_current_dataset
        done
    ) &
    log "Auto-extraction background process started"
fi

# -----------------------------------------------------------------------------
# Healthcheck endpoint info
# -----------------------------------------------------------------------------
log "============================================="
log "SLZB-OTBR is running!"
log "  REST API: http://0.0.0.0:$OT_REST_LISTEN_PORT"
log "  Radio:    $SLZB_HOST:$SLZB_PORT"
log "============================================="

# Wait for OTBR process
wait $OTBR_PID
