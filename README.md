# SLZB-OTBR

A Docker image for running OpenThread Border Router with networked Thread radios like [SLZB-MR1](https://smlight.tech/global/slzbmr1).

## Supported Hardware

This image is designed for **SLZB MR-series** devices from [SMLight](https://smlight.tech/global/slzbmr1) with the **Thread coordinator enabled**:

| Device | Description |
|--------|-------------|
| **SLZB-MR1** | Multi-protocol radio with Zigbee + Thread over PoE/Ethernet |
| **SLZB-MR2** | Next-gen multi-radio with improved range |

> **Setup Requirement**: In the SLZB web interface, ensure the **Thread coordinator** is enabled and note the TCP port (default: `6638`).

## Features

- 🔌 **Networked Radio Support**: Connects to TCP-based Thread radios via socat (no USB passthrough)
- 🔐 **Flexible Credentials**: TLV injection, Home Assistant API fetch, file-based, or new network
- 🔄 **Auto-Extraction**: Automatically syncs credentials from Home Assistant
- 🏠 **HA Ready**: Exposes REST API for Home Assistant Thread integration
- 📦 **Single Container**: All-in-one solution with socat bridge built-in

---

## Understanding Thread TLV (The Dataset)

### What is TLV?

**TLV** stands for "Type-Length-Value" and refers to the **Thread Active Operational Dataset** – the configuration that defines a Thread network. Think of it as the "WiFi password and settings" for Thread.

The TLV is a hex-encoded blob that contains:

| Field | Description |
|-------|-------------|
| **Network Name** | Human-readable name (e.g., "My Home") |
| **Network Key** | 128-bit encryption key (the secret!) |
| **Extended PAN ID** | 8-byte network identifier |
| **PAN ID** | 2-byte identifier |
| **Channel** | Radio channel (11-26 for 2.4GHz) |
| **Mesh-Local Prefix** | IPv6 prefix for mesh communication |
| **PSKc** | Pre-Shared Key for Commissioner |
| **Security Policy** | Key rotation time, flags |
| **Active Timestamp** | Version/epoch of the dataset |

Example TLV for a network named **"DECO-F1A3"** on channel 15:
```
0e080000000000010000000300000f35060004001fffe00208c5a2fb63d3e8b1a40708fdb4ce71e2c95d0d051000112233445566778899aabbccddeeff030944
```

Decoded, this contains:
- Network Name: `DECO-F1A3` (typical Google/Apple auto-generated name)
- Channel: `15`
- Extended PAN ID: `c5a2fb63d3e8b1a4`
- Network Key: `00112233445566778899aabbccddeeff` (example - yours will differ!)

### Why TLV Matters for This Tool

**All devices on a Thread network must share the same dataset.**

If you have existing Thread devices connected to:
- 🏠 **Google Home** (Nest Hub, etc.)
- 🍎 **Apple HomePod** / **Apple TV**
- 🔷 **Amazon Echo** (4th gen+)
- 🏡 **Existing Home Assistant OTBR**

...then this new OTBR **must use the same TLV** to join that network. Otherwise, it forms a separate network and your devices can't communicate across border routers.

### How to Get Your TLV

| Source | How to Export |
|--------|---------------|
| **Home Assistant** | Settings → Devices → Thread → ⋮ → Export credentials |
| **Google Home** | Use the Thread Credentials API or Android debug tools |
| **Apple Home** | Share via "Add Thread Network" in Home app |
| **Existing OTBR** | `ot-ctl dataset active -x` |

---

## Networking & Security Requirements

### Why `privileged: true`?

OTBR needs to create and manage a virtual network interface (`wpan0`) for the Thread mesh. This requires:

| Requirement | Why |
|-------------|-----|
| `NET_ADMIN` capability | Create/configure `wpan0` interface, manage routing tables |
| `/dev/net/tun` access | Create TUN device for Thread interface |

**Options (in order of preference):**

```yaml
# Option 1: Minimal (try this first)
securityContext:
  capabilities:
    add: ["NET_ADMIN"]
volumeMounts:
  - name: dev-net-tun
    mountPath: /dev/net/tun

# Option 2: Full privileged (if Option 1 fails)
securityContext:
  privileged: true
```

> **Note:** The official `openthread/border-router` image expects privileged mode. We recommend trying `NET_ADMIN` first; fall back to `privileged: true` if needed.

### Is `network_mode: host` / `hostNetwork` required?

**No**, not for the sidecar pattern. Here's why:

| Scenario | Host Network Needed? |
|----------|---------------------|
| OTBR as sidecar to HA | ❌ No – communicate via `localhost` |
| Direct IPv6 to Thread devices | ✅ Yes – needs mesh routing |
| Standalone OTBR (separate pod) | ⚠️ Maybe – depends on routing needs |

In the sidecar model:
- HA accesses OTBR via `localhost:8081` (REST API)
- The Thread mesh IPv6 is contained within OTBR
- External communication to SLZB radio is via TCP/IPv4
- No host network routing required

### Network Architecture (IPv4-only networks work!)

```
Your Network (IPv4)          Thread Mesh (IPv6, isolated)
       │                              │
       │ TCP:6638                     │ 802.15.4 radio
       ▼                              ▼
┌─────────────┐              ┌─────────────────┐
│  SLZB-MR1   │◄────────────►│  Thread Devices │
│ 192.168.1.x │   (radio)    │    fd00::/64    │
└─────────────┘              └─────────────────┘
       │                              ▲
       │ IPv4                         │ IPv6 (internal)
       ▼                              │
┌─────────────────────────────────────┴──┐
│           OTBR Container               │
│  ┌─────────────────────────────────┐   │
│  │ socat: TCP → /dev/ttyACM0       │   │
│  │ wpan0: Thread mesh interface    │   │
│  │ REST API: localhost:8081        │   │
│  └─────────────────────────────────┘   │
└────────────────────────────────────────┘
```

---

## Quick Start

### Docker Run

```bash
docker run -d \
  --name otbr \
  --privileged \
  --network host \
  -e SLZB_HOST=192.168.1.235 \
  -v otbr-data:/data \
  ghcr.io/tiborv/slzb-otbr:latest
```

### Join Existing Network (e.g., "DECO-F1A3")

```bash
docker run -d \
  --name otbr \
  --privileged \
  --network host \
  -e SLZB_HOST=192.168.1.235 \
  -e THREAD_DATASET_TLV="0e080000000000010000000300000f35060004001fffe..." \
  -v otbr-data:/data \
  ghcr.io/tiborv/slzb-otbr:latest
```

### With Auto-Extraction from Home Assistant

```bash
docker run -d \
  --name otbr \
  --privileged \
  --network host \
  -e SLZB_HOST=192.168.1.235 \
  -e HA_URL=http://192.168.1.100:8123 \
  -e HA_TOKEN=eyJ0eXAiOi... \
  -e AUTO_EXTRACT=true \
  -v otbr-data:/data \
  ghcr.io/tiborv/slzb-otbr:latest
```

This will:
1. On startup, fetch credentials from HA
2. Every 5 minutes, check if HA credentials changed
3. Automatically update OTBR if they did

---

## Docker Compose

```yaml
services:
  otbr:
    image: ghcr.io/tiborv/slzb-otbr:latest
    container_name: slzb-otbr
    privileged: true
    network_mode: host
    environment:
      SLZB_HOST: "192.168.1.235"
      
      # Option A: Direct TLV (join existing "DECO-F1A3" network)
      # THREAD_DATASET_TLV: "0e080000000000010000000300000f35..."
      
      # Option B: Auto-extract from HA
      HA_URL: "http://192.168.1.100:8123"
      HA_TOKEN: "${HA_TOKEN}"  # Use .env file
      AUTO_EXTRACT: "true"
      AUTO_EXTRACT_INTERVAL: "300"  # seconds
    volumes:
      - otbr-data:/data
    restart: unless-stopped

volumes:
  otbr-data:
```

---

## Kubernetes (Sidecar Pattern)

OTBR runs as a sidecar to Home Assistant, communicating via `localhost`. See [`examples/kubernetes.yaml`](examples/kubernetes.yaml) for a complete deployment.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: home-assistant
spec:
  template:
    spec:
      containers:
      # Home Assistant
      - name: home-assistant
        image: homeassistant/home-assistant:2025.1
        ports:
        - containerPort: 8123

      # OTBR Sidecar - accessible at localhost:8081
      - name: otbr
        image: ghcr.io/tiborv/slzb-otbr:latest
        securityContext:
          privileged: true
        env:
        - name: SLZB_HOST
          value: "192.168.1.235"
        # Auto-extract from HA (same pod = localhost)
        - name: HA_URL
          value: "http://localhost:8123"
        - name: HA_TOKEN
          valueFrom:
            secretKeyRef:
              name: ha-credentials
              key: token
        - name: AUTO_EXTRACT
          value: "true"
        ports:
        - containerPort: 8081

      # Matter Server Sidecar (optional) - accessible at localhost:5580
      - name: matter-server
        image: ghcr.io/home-assistant-libs/python-matter-server:stable
        ports:
        - containerPort: 5580
```

**Sidecar benefits:**
- HA accesses OTBR at `localhost:8081` (no Service needed)
- HA accesses Matter Server at `localhost:5580`
- Auto-extraction uses `localhost:8123` to reach HA API
- All containers share the same network namespace

---

## Configuration Reference

### Required

| Variable | Description | Example |
|----------|-------------|---------|
| `SLZB_HOST` | IP/hostname of the SLZB device | `192.168.1.235` |

### Thread Credentials (Priority Order)

| Variable | Description |
|----------|-------------|
| `THREAD_DATASET_TLV` | Direct hex TLV (highest priority) |
| `HA_URL` + `HA_TOKEN` | Fetch from Home Assistant API |
| `TLV_FILE_PATH` | Read TLV from a file |
| *(none)* | Use existing or form new network |

### Auto-Extraction from Home Assistant

When `AUTO_EXTRACT=true`, OTBR fetches Thread credentials from Home Assistant's API.

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTO_EXTRACT` | `false` | Enable periodic HA credential sync |
| `AUTO_EXTRACT_INTERVAL` | `300` | Seconds between checks |
| `TLV_EXPORT_PATH` | `/data/dataset.hex` | Where to write current TLV |

**How it works:**

1. On startup, fetches TLV from HA (if no `THREAD_DATASET_TLV` provided)
2. Every `AUTO_EXTRACT_INTERVAL` seconds, checks if HA credentials changed
3. If changed, updates OTBR and restarts the Thread network

**Which network does it pick?**

The script calls Home Assistant's Thread API:
```bash
# Primary endpoint (HA 2024.x+)
GET /api/thread/dataset/tlvs
# Returns list of datasets, picks the FIRST one: .[0].dataset

# Fallback endpoint (older HA)
GET /api/thread/datasets
# Returns list, picks: .[0].dataset_tlv
```

> **Note:** Currently picks the **first dataset** returned by the API. HA returns preferred/default network first. If you have multiple Thread networks, ensure your preferred one is set as default in HA's Thread settings.

**Example API response:**
```json
[
  {
    "dataset": "0e080000000000010000...",
    "preferred_border_agent_id": "abc123",
    "network_name": "DECO-F1A3"
  }
]
```

### Radio Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `SLZB_PORT` | `6638` | TCP port of the radio |
| `BAUD_RATE` | `460800` | RCP baud rate |

### OTBR Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `OT_THREAD_IF` | `wpan0` | Thread interface name |
| `OT_LOG_LEVEL` | `5` | Log verbosity (1-7) |
| `OT_REST_LISTEN_PORT` | `8081` | REST API port |

---

## Home Assistant Integration

### Adding OTBR to Home Assistant

1. Go to **Settings → Devices & Services → Add Integration**
2. Search for **OpenThread Border Router**
3. Enter URL: `http://<docker-host>:8081`

### Getting a Long-Lived Access Token

For auto-extraction, you need an HA token:

1. Go to your HA profile (bottom-left user icon)
2. Scroll to **Long-Lived Access Tokens**
3. Click **Create Token**
4. Copy and use as `HA_TOKEN`

---

## Credential Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Startup                                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │  THREAD_DATASET_TLV set?      │
              └───────────────────────────────┘
                     │ Yes              │ No
                     ▼                  ▼
              ┌──────────┐    ┌───────────────────────┐
              │ Use TLV  │    │  HA_URL + HA_TOKEN?   │
              └──────────┘    └───────────────────────┘
                                   │ Yes        │ No
                                   ▼            ▼
                            ┌──────────┐  ┌─────────────────┐
                            │ Fetch    │  │ TLV_FILE_PATH?  │
                            │ from HA  │  └─────────────────┘
                            └──────────┘       │ Yes    │ No
                                               ▼        ▼
                                        ┌──────────┐ ┌──────────────┐
                                        │ Read     │ │ Existing     │
                                        │ from     │ │ dataset in   │
                                        │ file     │ │ /data?       │
                                        └──────────┘ └──────────────┘
                                                          │ Yes  │ No
                                                          ▼      ▼
                                                   ┌──────────┐ ┌──────────┐
                                                   │ Use      │ │ Form New │
                                                   │ existing │ │ Network  │
                                                   └──────────┘ └──────────┘
```

---

## Troubleshooting

### Check current dataset
```bash
docker exec slzb-otbr ot-ctl dataset active -x
```

### View Thread state
```bash
docker exec slzb-otbr ot-ctl state
# Should show: leader, router, child, or disabled
```

### Check connectivity to radio
```bash
docker exec slzb-otbr nc -zv $SLZB_HOST 6638
```

### View logs
```bash
docker logs -f slzb-otbr
```

---

## Building

```bash
docker build -t slzb-otbr .

# Multi-arch build
docker buildx build --platform linux/amd64,linux/arm64 -t slzb-otbr .
```

## License

MIT
