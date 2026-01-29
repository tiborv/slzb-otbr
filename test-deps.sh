#!/bin/bash
# =============================================================================
# Dependency Test Script for SLZB-OTBR
# Run this to verify all required dependencies are available in the image
# =============================================================================
# set -e (disabled to allow accumulation of errors)

# Ensure /usr/sbin is in path for otbr-agent/avahi-daemon
export PATH=$PATH:/usr/sbin:/sbin

PASS=0
FAIL=0

check_command() {
    local cmd=$1
    local desc=$2
    if command -v "$cmd" &> /dev/null; then
        echo "✅ $cmd: $desc"
        ((PASS+=1))
    else
        echo "❌ $cmd: NOT FOUND - $desc"
        ((FAIL+=1))
    fi
}

check_file() {
    local file=$1
    local desc=$2
    if [ -f "$file" ] || [ -e "$file" ]; then
        echo "✅ $file: $desc"
        ((PASS+=1))
    else
        echo "❌ $file: NOT FOUND - $desc"
        ((FAIL+=1))
    fi
}

echo "=========================================="
echo "SLZB-OTBR Dependency Check"
echo "=========================================="
echo ""

echo "--- Core OTBR Components ---"
check_command "ot-ctl" "OpenThread CLI"
check_command "otbr-agent" "OTBR Agent daemon"
check_file "/init" "OTBR init script"

echo ""
echo "--- Network Tools ---"
check_command "socat" "Serial-over-TCP bridge"
check_command "curl" "HTTP client for HA API"
check_command "jq" "JSON processor"
check_command "nc" "Netcat for connectivity tests"

echo ""
echo "--- mDNS / Service Discovery ---"
check_command "avahi-daemon" "mDNS daemon (Legacy/Fallback)"
check_command "avahi-browse" "mDNS browser tool"

echo ""
echo "--- Native mDNS Publisher ---"
check_command "python3" "Python runtime"
check_file "/usr/local/bin/mdns_publisher.py" "mDNS publisher script"

# Check python module
if python3 -c "import zeroconf" > /dev/null 2>&1; then
    echo "✅ python-zeroconf: Installed"
    ((PASS+=1))
else
    echo "❌ python-zeroconf: NOT INSTALLED"
    ((FAIL+=1))
fi

echo ""
echo "--- System Tools ---"
check_command "pkill" "Process killer (for avahi toggle)"
check_command "ip" "Network interface management"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ $FAIL -gt 0 ]; then
    exit 1
fi
exit 0
