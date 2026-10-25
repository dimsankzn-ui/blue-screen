"""Own test receiver only: pair, restart, resume, and reject a forged token. No image."""
import argparse
import json
import ipaddress
import re
import socket
import ssl
import struct
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True)
parser.add_argument('--serial', required=True)
args = parser.parse_args()
assert ipaddress.ip_address(args.host).is_private
client_id = b'EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE'


def adb(*parts):
    return subprocess.check_output(['adb', '-s', args.serial, *parts], stderr=subprocess.DEVNULL)


def certificate():
    return adb('exec-out', 'run-as', 'local.bluescreen.tv', 'cat', 'files/receiver-cert.der')


def exact(connection, size):
    result = b''
    while len(result) < size:
        chunk = connection.recv(size - len(result))
        if not chunk:
            raise RuntimeError('Receiver closed the connection')
        result += chunk
    return result


context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_2
cert = certificate()  # Public certificate from the already authorized local ADB channel.


def authenticate(mode, secret, accepted=True):
    with socket.create_connection((args.host, 8845), timeout=5) as tcp:
        with context.wrap_socket(tcp, server_hostname=args.host) as connection:
            assert connection.getpeercert(binary_form=True) == cert, 'Certificate changed'
            connection.sendall(b'BLUSCR05' + bytes([mode]) + client_id + secret)
            status = exact(connection, 1)
            assert status == (b'\x01' if accepted else b'\x00'), 'Unexpected authentication result'
            if not accepted:
                return
            token = exact(connection, 32)
            size = struct.unpack('>I', exact(connection, 4))[0]
            assert 0 < size <= 16384
            caps = json.loads(exact(connection, size))
            assert caps['protocolVersion'] == 5 and caps['modes']
            mode = max(caps['modes'], key=lambda m: (m['width']*m['height'],m['fpsMilli']))
            connection.sendall(struct.pack('>IIII', mode['width'], mode['height'], mode['fpsMilli'], 0))
            assert exact(connection, 12) == bytes(12), 'No video heartbeat confirmation'
            return token


ui = adb('exec-out', 'uiautomator', 'dump', '/dev/tty').decode('utf-8', 'replace')
pin = re.search(r'Код: (\d{6})', ui)
assert pin, 'Pairing screen not visible'
token = authenticate(0, pin.group(1).encode('ascii'))
adb('shell', 'am', 'force-stop', 'local.bluescreen.tv')
adb('shell', 'am', 'start', '-W', '-n', 'local.bluescreen.tv/.MainActivity')
for _ in range(30):
    try:
        assert certificate() == cert, 'Identity did not persist after restart'
        resumed = authenticate(1, token)
        break
    except (OSError, RuntimeError):
        time.sleep(0.2)
else:
    raise RuntimeError('Receiver did not restart')
assert resumed == token
forged = bytes([token[0] ^ 1]) + token[1:]
authenticate(1, forged, accepted=False)
authenticate(0, b'abcdef', accepted=False)
print('PASS: first pairing; stable TV identity after process restart; reconnect without PIN; forged token and invalid PIN rejected; no image transmitted')
