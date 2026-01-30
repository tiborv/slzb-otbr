#!/usr/bin/env python3
"""
OTBR Manager
------------
Unifies mDNS publishing and "Smart Routing" for the SLZB-OTBR container.

Features:
1. Dynamic mDNS: Broadcasts _meshcop._udp.local based on OTBR dataset.
2. Smart Routing: Periodically syncs Thread OMR prefixes to kernel routes.
   - Fixes connectivity when devices roam to other Border Routers.
   - Prevents ::/0 default route loops.
"""

import logging
import socket
import sys
import time
import os
import signal
import subprocess
import re

# Dependencies
try:
    from zeroconf import ServiceInfo, Zeroconf, NonUniqueNameException, ServiceNameAlreadyRegistered
except ImportError:
    print("Error: zeroconf module not found. Please install it: pip3 install zeroconf")
    sys.exit(1)

# Configuration
mDNS_SERVICE_TYPE = "_meshcop._udp.local."
# Allow user to set valid hostname (must end in .local.)
_env_hostname = os.getenv("OTBR_HOSTNAME", "otbr-server")
if not _env_hostname.endswith(".local"):
     _env_hostname += ".local"
if not _env_hostname.endswith("."):
     _env_hostname += "."
mDNS_SERVER_NAME = _env_hostname

DATA_DIR = os.getenv("OTBR_MDNS_DATA_DIR", "/tmp/otbr-mdns")
POLL_INTERVAL = 30  # Seconds between routing/mDNS checks

# Logging setup
logging.basicConfig(level=logging.INFO, format='%(asctime)s [OTBR-Mgr] %(message)s')
logger = logging.getLogger("OTBR-Mgr")

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------

def run_command(cmd : str) -> str:
    """Run a shell command and return its output."""
    try:
        result = subprocess.run(cmd, shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return result.stdout.decode('utf-8').strip()
    except subprocess.CalledProcessError as e:
        logger.debug(f"Command failed: {cmd} -> {e.stderr.decode('utf-8')}")
        return ""
    except Exception as e:
        logger.error(f"Error running command '{cmd}': {e}")
        return ""

def get_ipv6_addresses(interface="wpan0"):
    """Get global IPv6 addresses of the interface."""
    ips = []
    try:
        # Try to find wpan0 addresses from /proc/net/if_inet6
        if os.path.exists("/proc/net/if_inet6"):
            with open("/proc/net/if_inet6", "r") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 6 and parts[5] == interface:
                        raw_hex = parts[0]
                        # Convert hex string to IPv6 format
                        ipv6 = ":".join(raw_hex[i:i+4] for i in range(0, 32, 4))
                        # Check if it is a link-local address (starts with fe80)
                        if not ipv6.lower().startswith("fe80"):
                             ips.append(ipv6)
    except Exception as e:
        logger.error(f"Error getting IPs: {e}")
    return ips

# -------------------------------------------------------------------------
# mDNS Logic
# -------------------------------------------------------------------------


def parse_tlv(hex_str):
    """Minimal Thread TLV parser."""
    try:
        data = bytes.fromhex(hex_str)
    except Exception:
        return {}
    
    tlvs = {}
    i = 0
    while i < len(data):
        if i + 2 > len(data): break
        tag = data[i]
        length = data[i+1]
        i += 2
        if i + length > len(data): break
        val = data[i:i+length]
        tlvs[tag] = val
        i += length
    return tlvs

def get_mdns_properties():
    """Fetch OTBR state via ot-ctl and parse properties for mDNS."""
    # Fetch data directly via ot-ctl
    dataset_hex = run_command("ot-ctl dataset active -x | tr -d '\r\n'")
    extaddr = run_command("ot-ctl extaddr | tr -d '\r\n'")
    baid = run_command("ot-ctl ba id | tr -d '\r\n'")

    if not dataset_hex or "Error" in dataset_hex or not extaddr or not baid:
        return None

    tlvs = parse_tlv(dataset_hex)
    
    # Tag 3: Network Name, Tag 2: Ext PAN ID
    if 3 not in tlvs or 2 not in tlvs:
         return None

    try:
        nn = tlvs[3].decode('utf-8')
        xp = tlvs[2]
        xa = bytes.fromhex(extaddr)
        bid = bytes.fromhex(baid)
    except Exception as e:
        logger.error(f"Error parsing TLV values: {e}")
        return None


    vendor = os.getenv("OTBR_VENDOR", "OpenThread")
    model = os.getenv("OTBR_MODEL", "SLZB-OTBR")

    return {
        "nn": nn,
        "xp": xp,
        "tv": "1.4.0", 
        "xa": xa,
        "id": bid,
        "sb": bytes.fromhex("00000030"),
        "vn": vendor.encode('utf-8'),
        "mn": model.encode('utf-8'),
    }

def update_mdns(zeroconf, current_info):
    """Check state and update mDNS registration if needed."""
    props = get_mdns_properties()
    if not props:
        if current_info:
            logger.warning("OTBR data lost or invalid, unregistering mDNS service...")
            zeroconf.unregister_service(current_info)
        return None

    service_name = f"{props['nn']}.{mDNS_SERVICE_TYPE}"
    ip_addrs = get_ipv6_addresses("wpan0")
    
    # Convert IPs to bytes
    addresses_bytes = []
    for ip in ip_addrs:
        try:
            addresses_bytes.append(socket.inet_pton(socket.AF_INET6, ip))
        except Exception:
            pass

    new_info = ServiceInfo(
        mDNS_SERVICE_TYPE,
        service_name,
        addresses=addresses_bytes,
        port=mDNS_PORT,
        properties=props,
        server=mDNS_SERVER_NAME,
    )

    # Determine if update is needed
    is_different = False
    if current_info is None:
        is_different = True
    elif current_info.name != new_info.name:
        is_different = True
    elif current_info.properties != new_info.properties:
        is_different = True
    elif set(current_info.addresses) != set(new_info.addresses):
        is_different = True

    if is_different:
        logger.info(f"Registering/Updating mDNS Service: {service_name} @ {ip_addrs}")
        if current_info:
            zeroconf.unregister_service(current_info)
        
        try:
            zeroconf.register_service(new_info)
            return new_info
        except NonUniqueNameException:
            logger.warning(f"Name collision for {service_name}, skipping this cycle...")
            return current_info
    
    return current_info

# -------------------------------------------------------------------------
# Smart Routing Logic
# -------------------------------------------------------------------------

def sync_omr_routes():
    """
    Parse 'ot-ctl netdata show' and ensure kernel routes exist for all OMR prefixes.
    """
    output = run_command("ot-ctl netdata show")
    if not output:
        return

    # Regex to find prefixes in the "Prefixes:" section
    # Example line: fd01:adb5:fb49:1::/64 paros low 8c00
    # We look for lines containing "::/64" and flags
    # We ignore ::/0 to prevent default route loops
    
    prefixes = set()
    lines = output.splitlines()
    in_prefixes_section = False
    
    for line in lines:
        line = line.strip()
        if line.startswith("Prefixes"):
            in_prefixes_section = True
            continue
        if line.startswith("Routes") or line.startswith("Services"):
            in_prefixes_section = False
            continue
            
        if in_prefixes_section and line:
            parts = line.split()
            if len(parts) > 0:
                prefix = parts[0]
                # Basic validation: must be IPv6, must not be default
                if ":" in prefix and "/64" in prefix and prefix != "::/0":
                     prefixes.add(prefix)

    # Get current kernel routes
    # format: fd01:adb5:fb49:1::/64 dev wpan0 metric 1 ...
    current_routes_output = run_command("ip -6 route show dev wpan0")
    current_routes = set()
    for line in current_routes_output.splitlines():
        parts = line.split()
        if len(parts) > 0:
             current_routes.add(parts[0])

    # Sync
    for prefix in prefixes:
        if prefix not in current_routes:
            logger.info(f"Adding missing OMR route: {prefix}")
            # metric 1 to prioritize over other routes if needed
            run_command(f"ip -6 route add {prefix} dev wpan0 metric 1 2>/dev/null || ip -6 route replace {prefix} dev wpan0 metric 1")


# -------------------------------------------------------------------------
# Discovery Fixer (Injection)
# -------------------------------------------------------------------------

def get_thread_data():
    """Fetch routing and association data from Thread."""
    # Mapping of RLOC -> [IPs]
    rloc_ips = {}
    
    # 1. Parse eidcache
    output = run_command("ot-ctl eidcache")
    for line in output.splitlines():
        # format: <ip> <rloc> ...
        parts = line.split()
        if len(parts) >= 2:
            ip = parts[0]
            rloc = parts[1].replace("0x", "")
            if ":" in ip and not ip.startswith("fe80"):
                if rloc not in rloc_ips:
                    rloc_ips[rloc] = []
                rloc_ips[rloc].append(ip)

    # 1b. Parse childip (for immediate children not in eidcache)
    childip_output = run_command("ot-ctl childip")
    for line in childip_output.splitlines():
        # format: <rloc>: <ip>
        if ":" not in line:
            continue
        parts = line.split(":", 1)
        if len(parts) >= 2:
            rloc = parts[0].strip().replace("0x", "")
            ip = parts[1].strip()
            if ":" in ip and not ip.startswith("fe80"):
                if rloc not in rloc_ips:
                    rloc_ips[rloc] = []
                if ip not in rloc_ips[rloc]:
                    rloc_ips[rloc].append(ip)

    # 2. MAC to RLOC Mapping
    mac_rloc = {}
    
    # Check Child Table
    child_table = run_command("ot-ctl child table")
    for line in child_table.splitlines():
        if "|" not in line or "RLOC16" in line:
            continue
        parts = line.split("|")
        # | ID  | RLOC16 | ... (11 more) ... | Extended MAC     |
        if len(parts) >= 15:
            try:
                rval = parts[2].strip().replace("0x", "")
                mval = parts[14].strip().lower()
                if len(mval) == 16:
                    mac_rloc[mval] = rval
            except:
                pass

    # Check Neighbor Table (for Routers)
    neighbor_table = run_command("ot-ctl neighbor table")
    for line in neighbor_table.splitlines():
        if "|" not in line or "RLOC16" in line:
            continue
        parts = line.split("|")
        # | Role | RLOC16 | ... (7 more) ... | Extended MAC     | Version |
        if len(parts) >= 11:
            try:
                rval = parts[2].strip().replace("0x", "")
                mval = parts[10].strip().lower()
                if len(mval) == 16:
                    mac_rloc[mval] = rval
            except:
                pass

    return rloc_ips, mac_rloc

class DiscoveryFixer:
    def __init__(self, zeroconf):
        self.zeroconf = zeroconf
        self.known_services = {}
        self.rloc_ips = {}
        self.mac_rloc = {}

    def update_ips(self):
        self.rloc_ips, self.mac_rloc = get_thread_data()
        msg = f"Thread Data: {len(self.mac_rloc)} MACs, {len(self.rloc_ips)} RLOC-IP groups. "
        # Log all associations for visibility
        assoc_list = []
        for mac, rloc in self.mac_rloc.items():
            ips = self.rloc_ips.get(rloc, [])
            assoc_list.append(f"{mac}->{rloc}({len(ips)} IPs)")
        logger.info(msg + "Associations: " + ", ".join(assoc_list))

    def add_service(self, zeroconf, type, name):
        self.check_service(name, type)

    def remove_service(self, zeroconf, type, name):
        pass

    def update_service(self, zeroconf, type, name):
        self.check_service(name, type)

    def check_service(self, name, type):
        try:
            info = self.zeroconf.get_service_info(type, name)
            if not info:
                return
            
            # 1. Try to extract MAC address from 'server' (e.g. 2E278F1D98E1714D.local.)
            target_mac = None
            server_name = info.server.lower()
            if server_name.endswith(".local."):
                potential_mac = server_name.replace(".local.", "")
                if len(potential_mac) == 16:
                    target_mac = potential_mac
            
            # 2. Association logic
            candidate_ips = []
            if target_mac and target_mac in self.mac_rloc:
                rloc = self.mac_rloc[target_mac]
                candidate_ips = self.rloc_ips.get(rloc, [])
                if candidate_ips:
                    logger.info(f"Associated service {name} (MAC {target_mac}) to RLOC {rloc} with IPs: {candidate_ips}")
            
            # 3. Injection! (Only if we found VERIFIED candidate IPs)
            if not info.addresses and candidate_ips:
                logger.info(f"Injecting verified IPs for {name} (Server: {info.server}): {candidate_ips}")
                
                addr_bytes = []
                for ip in candidate_ips:
                    try:
                        b = socket.inet_pton(socket.AF_INET6, ip)
                        addr_bytes.append(b)
                    except:
                        pass
                
                if not addr_bytes:
                    return

                new_info = ServiceInfo(
                    type,
                    name,
                    addresses=addr_bytes,
                    port=info.port,
                    properties=info.properties,
                    server=info.server,
                )
                
                try:
                    # cooperating_responders=True allows us to publish even if 
                    # the device is already advertising (with 0 IPs).
                    self.zeroconf.register_service(new_info, cooperating_responders=True)
                    self.known_services[name] = new_info
                except Exception as e:
                    logger.warning(f"Failed to inject {name}: {e}")
                    
        except Exception as e:
            logger.error(f"Error checking service {name}: {e}")

# -------------------------------------------------------------------------
# Main Loop
# -------------------------------------------------------------------------

def main():
    logger.info("Starting OTBR Manager (Smart Routing + mDNS + Discovery Fixer)...")
    logger.info(f"Watching directory: {DATA_DIR}")
    
    zeroconf = Zeroconf()
    current_mdns_info = None
    
    # Start Discovery Fixer
    from zeroconf import ServiceBrowser
    fixer = DiscoveryFixer(zeroconf)
    
    # Pre-populate data
    logger.info("Pre-populating Thread data for Discovery Fixer...")
    fixer.update_ips()
    
    browser_c = ServiceBrowser(zeroconf, "_matterc._udp.local.", fixer)
    browser_o = ServiceBrowser(zeroconf, "_matter._tcp.local.", fixer)
    
    def cleanup(sig, frame):
        logger.info("Shutting down...")
        if current_mdns_info:
            zeroconf.unregister_service(current_mdns_info)
        zeroconf.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    
    try:
        while True:
            # 1. Update mDNS (Border Router)
            current_mdns_info = update_mdns(zeroconf, current_mdns_info)
            
            # 2. Sync Routing
            sync_omr_routes()
            
            # 3. Update Thread IPs for Fixer
            fixer.update_ips()
            
            time.sleep(POLL_INTERVAL)
            
    except Exception as e:
        logger.error(f"Critical error: {e}")
        cleanup(None, None)

if __name__ == "__main__":
    main()
