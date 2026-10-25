"""Run only against the explicitly selected development receiver; no screen data."""
import argparse
import ipaddress
import socket
import ssl
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--host", required=True)
parser.add_argument("--serial", required=True)
args = parser.parse_args()
host = ipaddress.IPv4Address(args.host)
if not any(host in ipaddress.ip_network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
    parser.error("Expected a local private IPv4 address")
certificate = subprocess.check_output([
    "adb", "-s", args.serial, "exec-out", "run-as", "local.bluescreen.tv", "cat", "files/receiver-cert.der"])
if not certificate or certificate[0] != 0x30:
    raise RuntimeError("Cannot read the development receiver's public certificate")
context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.maximum_version = ssl.TLSVersion.TLSv1_2
with socket.create_connection((str(host), 8845), timeout=5) as tcp:
    with context.wrap_socket(tcp, server_hostname=str(host)) as connection:
        # The exact certificate came from the already authorised ADB channel.
        # Verify it before transmitting any authentication bytes; trust is not disabled.
        if connection.getpeercert(binary_form=True) != certificate:
            raise RuntimeError("Receiver certificate mismatch")
        connection.sendall(b"BLUSCR02abcdef")  # Cannot equal the receiver's six numeric digits.
        if connection.recv(1) != b"\x00":
            raise AssertionError("Receiver did not reject invalid authentication")
print("PASS: real Android receiver used TLS 1.2, exact certificate verified, invalid code rejected; no image transmitted")
