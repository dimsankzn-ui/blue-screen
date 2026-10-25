"""Own receiver only: test sleep-to-Home and trusted resume from the TV launcher."""
import argparse,json,re,socket,ssl,struct,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--host',required=True);p.add_argument('--serial',required=True);args=p.parse_args()
def adb(*v):return subprocess.check_output(['adb','-s',args.serial,*v],stderr=subprocess.DEVNULL)
def exact(s,n):
 result=b''
 while len(result)<n:
  part=s.recv(n-len(result))
  if not part:raise RuntimeError('Connection closed')
  result+=part
 return result
cert=adb('exec-out','run-as','local.bluescreen.tv','cat','files/receiver-cert.der')
ui=adb('exec-out','uiautomator','dump','/dev/tty').decode('utf-8','replace');pin=re.search(r'Код: (\d{6})',ui)
assert pin,'Open pairing screen first'
context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
context.minimum_version=context.maximum_version=ssl.TLSVersion.TLSv1_2
client=b'DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD'
def connect(mode,secret):
 s=context.wrap_socket(socket.create_connection((args.host,8845),timeout=5),server_hostname=args.host)
 assert s.getpeercert(binary_form=True)==cert
 s.sendall(b'BLUSCR05'+bytes([mode])+client+secret);assert exact(s,1)==b'\x01'
 token=exact(s,32);size=struct.unpack('>I',exact(s,4))[0];assert 0<size<=16384
 caps=json.loads(exact(s,size));chosen=next(m for m in caps['modes'] if m['width']==1920)
 s.sendall(struct.pack('>IIII',chosen['width'],chosen['height'],chosen['fpsMilli'],0));exact(s,12)
 return s,token
def foreground():
 state=adb('shell','dumpsys','activity','activities').decode('utf-8','replace')
 return next((line.strip() for line in state.splitlines() if 'mResumedActivity:' in line),'unknown')
s,token=connect(0,pin.group(1).encode());s.sendall(b'\xff\xff\xff\xff');s.close();time.sleep(1)
assert 'local.bluescreen.tv' not in foreground(),'Sleep did not release TV to Home'
with socket.create_connection((args.host,8846),timeout=3):pass
s,_=connect(1,token);time.sleep(2)
resumed=foreground();s.sendall(b'\xff\xff\xff\xff');s.close()
assert 'local.bluescreen.tv' in resumed,'BACKGROUND_START_BLOCKED: '+resumed
print('PASS: authenticated sleep command returned TV to Home; listener remained available; trusted resume foregrounded receiver')
