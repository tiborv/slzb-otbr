#!/usr/bin/env python3
"""
Dynamic mDNS Publisher for OTBR
Broadcasts _meshcop._udp.local service for Thread Border Router discovery.
This workaround bypasses native OTBR mDNS issues in Docker/K8s environments.
"""

import logging
import socket
import sys
import time
import os
import signal

# Dependencies
try:
    from zeroconf import ServiceInfo, Zeroconf, NonUniqueNameException
except ImportError:
    print("Error: zeroconf module not found. Please install it: pip3 install zeroconf")
    sys.exit(1)

# Configuration
SERVICE_TYPE = "_meshcop._udp.local."
SERVER_NAME = "otbr-server.local."
PORT = 49154
DATA_DIR = os.getenv("OTBR_MDNS_DATA_DIR", "/tmp/otbr-mdns")

# Logging setup
logging.basicConfig(level=logging.INFO, format='%(asctime)s [mDNS] %(message)s')
logger = logging.getLogger("mDNS")

def get_ip():
    """Get primary IP address of the container"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # Connect to a public IP to determine primary interface
        s.connect(('1.1.1.1', 80))
        IP = s.getsockname()[0]
    except Exception:
        IP = '127.0.0.1'
    finally:
        s.close()
    return IP

def read_file(filename):
    """Read a file from the data directory"""
    path = os.path.join(DATA_DIR, filename)
    if not os.path.exists(path):
        return None
    try:
        with open(path, 'r') as f:
            content = f.read().strip()
            # Handle ot-ctl "Done" lines or errors
            if "Error" in content or not content:
                return None
            lines = content.split('\n')
            # return first line that looks like data
            return lines[0].strip()
    except Exception:
        return None

def parse_tlv(hex_str):
    """Minimal Thread TLV parser"""
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

def get_properties():
    """Read OTBR state files and parse properties for mDNS"""
    dataset_hex = read_file("dataset.hex")
    extaddr = read_file("extaddr.txt")
    baid = read_file("baid.txt")

    if not dataset_hex or not extaddr or not baid:
        return None

    tlvs = parse_tlv(dataset_hex)
    
    # Tag 3: Network Name (String)
    # Tag 2: Ext PAN ID (Bytes)
    
    if 3 not in tlvs or 2 not in tlvs:
        return None

    try:
        nn = tlvs[3].decode('utf-8')
        xp = tlvs[2]
        xa = bytes.fromhex(extaddr)
        bid = bytes.fromhex(baid)
    except Exception as e:
        logger.error(f"Error parsing values: {e}")
        return None

    return {
        "nn": nn,
        "xp": xp,
        "tv": "1.4.0", 
        "xa": xa,
        "id": bid,
        "sb": bytes.fromhex("00000030"),
    }

def main():
    logger.info("Starting Dynamic mDNS Publisher...")
    logger.info(f"Watching directory: {DATA_DIR}")
    
    zeroconf = Zeroconf()
    current_info = None
    
    def signal_handler(sig, frame):
        logger.info("Stopping mDNS Publisher...")
        if current_info:
            zeroconf.unregister_service(current_info)
        zeroconf.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    try:
        while True:
            props = get_properties()
            
            if props:
                service_name = f"{props['nn']}.{SERVICE_TYPE}"
                ip_addr = get_ip()
                
                # Check if changed
                new_info = ServiceInfo(
                    SERVICE_TYPE,
                    service_name,
                    addresses=[socket.inet_aton(ip_addr)],
                    port=PORT,
                    properties=props,
                    server=SERVER_NAME,
                )

                is_different = False
                if current_info is None:
                    is_different = True
                elif current_info.name != new_info.name:
                    is_different = True
                elif current_info.properties != new_info.properties:
                    is_different = True

                if is_different:
                    logger.info(f"Updating mDNS Service: {service_name} @ {ip_addr}")
                    if current_info:
                        zeroconf.unregister_service(current_info)
                    
                    try:
                        zeroconf.register_service(new_info)
                        current_info = new_info
                        logger.info("Service registered successfully.")
                    except NonUniqueNameException:
                        logger.warning(f"Name collision for {service_name}, waiting...")
            else:
                if current_info:
                    logger.warning("OTBR data lost or invalid, unregistering service...")
                    zeroconf.unregister_service(current_info)
                    current_info = None
                # else: waiting for data

            time.sleep(15)
            
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
    finally:
        if current_info:
            zeroconf.unregister_service(current_info)
        zeroconf.close()

if __name__ == "__main__":
    main()
