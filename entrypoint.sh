#!/bin/bash
set -e

# =============================================================================
# SLZB-OTBR Entrypoint
# Connects to a networked Thread radio (SLZB-MR1, etc.) and runs OpenThread
# Border Router with flexible credential provisioning.
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

# mDNS publishing (opt-in for border router discovery)
MDNS_PUBLISH="${MDNS_PUBLISH:-true}"

log "Configuration:"
log "  SLZB_HOST: $SLZB_HOST"
log "  SLZB_PORT: $SLZB_PORT"
log "  AUTO_EXTRACT: $AUTO_EXTRACT"
log "  MDNS_PUBLISH: $MDNS_PUBLISH"

# -----------------------------------------------------------------------------
# Step 2: Infrastructure Interface Auto-detection
# -----------------------------------------------------------------------------
# OTBR needs an infrastructure interface (eth0, wlan0, etc.) for TREL/mDNS.
# If OT_INFRA_IF is not set, we try to detect the one with the default route.
if [ -z "$OT_INFRA_IF" ]; then
    log "Attempting to auto-detect infrastructure interface..."
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

# -----------------------------------------------------------------------------
# Step 3: Start socat bridge to networked radio
# -----------------------------------------------------------------------------
log "Starting socat bridge to $SLZB_HOST:$SLZB_PORT..."
socat -d -d pty,raw,echo=0,link=${SERIAL_DEVICE},ignoreeof tcp:${SLZB_HOST}:${SLZB_PORT} &
SOCAT_PID=$!

# -----------------------------------------------------------------------------
# Step 4: Configure OTBR (Background Process)
# -----------------------------------------------------------------------------
# We run configuration in the background so we can exec /init as PID 1
(
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

    # Wait for OTBR agent to be ready (started by s6 init)
    log "Waiting for OTBR agent to be ready..."
    until ot-ctl -I $OT_THREAD_IF state > /dev/null 2>&1; do
        sleep 2
    done
    log "OTBR agent is ready"

    # Disable Backbone Router (often causes issues in Docker/K8s)
    ot-ctl -I $OT_THREAD_IF bbr disable || true

    # Handle mDNS
    if [ "$MDNS_PUBLISH" != "true" ]; then
        log "mDNS publishing disabled"
        pkill -9 avahi-daemon 2>/dev/null || true
        ot-ctl -I $OT_THREAD_IF srp server disable || true
    else
        log "mDNS publishing enabled"
    fi

    # --- Provisioning Functions ---
    
    fetch_tlv_from_ha_api() {
        if [ -z "$HA_URL" ] || [ -z "$HA_TOKEN" ]; then return 1; fi
        TLV=$(curl -sf -H "Authorization: Bearer $HA_TOKEN" "${HA_URL}/api/thread/dataset/tlvs" 2>/dev/null | jq -r '.[0].dataset // empty')
        if [ -z "$TLV" ]; then
            TLV=$(curl -sf -H "Authorization: Bearer $HA_TOKEN" "${HA_URL}/api/thread/datasets" 2>/dev/null | jq -r '.[0].dataset_tlv // empty')
        fi
        echo "$TLV"
    }

    extract_tlv_from_ha_storage() {
        local storage_file="${HA_STORAGE_PATH:-/config/.storage/thread.datasets}"
        if [ ! -f "$storage_file" ]; then return 1; fi
        # Extract preferred dataset TLV (or first one)
        local tlv=$(jq -r '.data.preferred_dataset as $pref | .data.datasets[] | select(.id == $pref) | .tlv // empty' "$storage_file" 2>/dev/null)
        if [ -z "$tlv" ]; then
            tlv=$(jq -r '.data.datasets[0].tlv // empty' "$storage_file" 2>/dev/null)
        fi
        echo "$tlv"
    }

    dataset_matches() {
        local target_tlv="$1"
        local current_tlv=$(ot-ctl -I $OT_THREAD_IF dataset active -x 2>/dev/null | head -n 1)
        [ "$current_tlv" = "$target_tlv" ]
    }

    apply_tlv() {
        local tlv="$1"
        [ -z "$tlv" ] && return 1
        log "Applying TLV dataset..."
        
        # Wait for wpan0 interface to be ready (max 30 seconds)
        local retries=0
        while [ $retries -lt 30 ]; do
            if ot-ctl -I $OT_THREAD_IF state >/dev/null 2>&1; then
                break
            fi
            sleep 1
            retries=$((retries + 1))
        done
        
        if [ $retries -eq 30 ]; then
            log "ERROR: wpan0 interface not ready after 30s"
            return 1
        fi
        
        ot-ctl -I $OT_THREAD_IF thread stop || true
        ot-ctl -I $OT_THREAD_IF ifconfig down || true
        ot-ctl -I $OT_THREAD_IF dataset set active "$tlv"
        ot-ctl -I $OT_THREAD_IF dataset commit active
        ot-ctl -I $OT_THREAD_IF ifconfig up
        ot-ctl -I $OT_THREAD_IF thread start
        log "TLV applied"
    }
    

    export_current_dataset() {
        local output_file="${TLV_EXPORT_PATH:-/data/dataset.hex}"
        local dataset=$(ot-ctl -I $OT_THREAD_IF dataset active -x 2>/dev/null | head -n 1)
        # Check if dataset starts with Error or is empty or "Done"
        if [ -n "$dataset" ] && [[ "$dataset" != Error* ]] && [ "$dataset" != "Done" ]; then
            echo "$dataset" > "$output_file"
            
            # Export for mDNS publisher
            local mdns_dir="${OTBR_MDNS_DATA_DIR:-/dev/shm/otbr-mdns}"
            mkdir -p "$mdns_dir"
            echo "$dataset" > "${mdns_dir}/dataset.hex"
            ot-ctl -I $OT_THREAD_IF extaddr | head -n 1 > "${mdns_dir}/extaddr.txt"
            ot-ctl -I $OT_THREAD_IF ba id | head -n 1 > "${mdns_dir}/baid.txt"
        fi
    }

    provision_network() {
        # Priority 1: Direct TLV via ENV
        if [ -n "$THREAD_DATASET_TLV" ]; then
            log "Provisioning with provided THREAD_DATASET_TLV..."
            apply_tlv "$THREAD_DATASET_TLV"
            return 0
        fi

        # Priority 2: HA API
        if [ -n "$HA_URL" ] && [ -n "$HA_TOKEN" ]; then
            log "Fetching Thread credentials from Home Assistant API..."
            TLV=$(fetch_tlv_from_ha_api)
            if [ -n "$TLV" ]; then
                log "Provisioning with credentials from Home Assistant API..."
                apply_tlv "$TLV"
                return 0
            fi
        fi

        # Priority 3: HA Storage File
        TLV=$(extract_tlv_from_ha_storage)
        if [ -n "$TLV" ]; then
            log "Provisioning with credentials from Home Assistant storage file..."
            apply_tlv "$TLV"
            return 0
        fi

        # Priority 4: External TLV File
        if [ -n "$TLV_FILE_PATH" ] && [ -f "$TLV_FILE_PATH" ]; then
            for k in $(seq 1 15); do
                 TLV=$(cat "$TLV_FILE_PATH" | tr -d '[:space:]')
                 if [ -n "$TLV" ]; then
                    log "Provisioning with TLV from external file..."
                    apply_tlv "$TLV"
                    return 0
                 fi
                 sleep 2
            done
        fi

        # Priority 5: Keep existing
        if ! ot-ctl -I $OT_THREAD_IF dataset active 2>&1 | grep -q "Error 23"; then
            log "Using existing active dataset"
            ot-ctl -I $OT_THREAD_IF ifconfig up
            ot-ctl -I $OT_THREAD_IF thread start
            return 0
        fi

        # Priority 6: Form new
        log "No credentials found, forming new Thread network..."
        ot-ctl -I $OT_THREAD_IF dataset init new
        ot-ctl -I $OT_THREAD_IF dataset commit active
        ot-ctl -I $OT_THREAD_IF ifconfig up
        ot-ctl -I $OT_THREAD_IF thread start
        return 0
    }

    provision_network
    export_current_dataset

    # Auto extraction & mDNS data update loop
    log "Starting background update loop..."
    while true; do
        # 1. Check for HA updates (Auto Extract)
        if [ "$AUTO_EXTRACT" = "true" ]; then
            NEW_TLV=""
            # Try API first
            if [ -n "$HA_URL" ] && [ -n "$HA_TOKEN" ]; then
                NEW_TLV=$(fetch_tlv_from_ha_api)
            fi
            # Fallback to storage file
            if [ -z "$NEW_TLV" ]; then
                NEW_TLV=$(extract_tlv_from_ha_storage)
            fi

            if [ -n "$NEW_TLV" ] && ! dataset_matches "$NEW_TLV"; then
                log "Detected credential change in HA, updating..."
                apply_tlv "$NEW_TLV"
            fi
        fi
        
        # 2. Always export current data for mDNS publisher
        export_current_dataset
        
        # Sleep interval (use shorter interval for mDNS responsiveness)
        sleep 15
    done
    
) &

# -----------------------------------------------------------------------------
# Step 5: Start mDNS Publisher
# -----------------------------------------------------------------------------
if [ "$MDNS_PUBLISH" != "true" ]; then
    log "mDNS publishing disabled"
    pkill -9 avahi-daemon 2>/dev/null || true
    ot-ctl -I $OT_THREAD_IF srp server disable || true
else
    log "Starting Python mDNS publisher..."
    # Disable native Avahi to avoid conflicts/issues
    pkill -9 avahi-daemon 2>/dev/null || true
    
    # Start Python publisher
    export OTBR_MDNS_DATA_DIR="${OTBR_MDNS_DATA_DIR:-/dev/shm/otbr-mdns}"
    mkdir -p "$OTBR_MDNS_DATA_DIR"
    /usr/local/bin/mdns_publisher.py &
fi

# -----------------------------------------------------------------------------
# Step 6: Start OTBR (Main Process)
# -----------------------------------------------------------------------------
log "Starting OTBR (executing /init)..."
# exec /init replaces the shell, satisfying s6-overlay's PID 1 requirement
exec /init

