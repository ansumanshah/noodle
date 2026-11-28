#!/usr/bin/env python3
"""Stop an isolated daemon with live and idle guests; pass a signed daemon as argv[1]."""
import sys
import os,signal,socket,subprocess,tempfile,time
binary = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".build/release/noodled")
docker = os.path.abspath(os.environ.get("DOCKER_BIN", "build/tools/docker"))
resources = os.path.abspath(os.environ.get("NOODLE_RESOURCES", "build/resources"))
with tempfile.TemporaryDirectory(prefix='noodle-vm-stop-') as root:
 env=dict(os.environ,NOODLE_HOME=root,NOODLE_RESOURCES=resources,DOCKER_HOST='unix://'+root+'/run/docker.sock',DOCKER_CONFIG=root+'/docker-config',DOCKER_CLI_HINTS='false')
 for k in ['DOCKER_CONTEXT','DOCKER_API_VERSION','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH']: env.pop(k,None)
 def start():
  p=subprocess.Popen([binary],env=env,stderr=subprocess.PIPE,stdout=subprocess.DEVNULL);deadline=time.monotonic()+10
  while not os.path.exists(root+'/run/docker.sock') and p.poll() is None and time.monotonic()<deadline:time.sleep(.05)
  if p.poll() is not None: raise RuntimeError('daemon failed: '+p.stderr.read().decode())
  return p
 def d(*args):
  p=subprocess.run([docker,*args],env=env,text=True,capture_output=True,timeout=150)
  if p.returncode:raise RuntimeError(f'docker {args}: {p.stderr} {p.stdout}')
  return p.stdout.strip()
 def stop(p,label):
  before=time.monotonic(); p.send_signal(signal.SIGTERM)
  try:
   _,err=p.communicate(timeout=15);elapsed=time.monotonic()-before
   print(label,'PID',p.pid,'exit',p.returncode,'elapsed',round(elapsed,2),'stderr',err.decode().strip(),flush=True)
   assert p.returncode==0 and elapsed<10 and b'Cannot schedule tasks on an EventLoop' not in err
  except subprocess.TimeoutExpired:
   print(label,'PID',p.pid,'still alive after 15s',flush=True);p.kill();_,err=p.communicate();print('stderr',err.decode(),flush=True);raise
 p=start();logs=None
 try:
  name=d('run','-d','--name','shutdown-test','alpine:3.21','sh','-c','echo ready; sleep 120'); print('container',name,flush=True)
  logs=subprocess.Popen([docker,'logs','-f','shutdown-test'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  time.sleep(1)
  assert logs.poll() is None,'followed logs did not remain open'
  stop(p,'running container + followed logs')
  logs.wait(timeout=5)
  p=start()
  d('rm','-f','shutdown-test')
  d('run','--rm','alpine:3.21','true')
  stop(p,'idle VM after completed container')
 finally:
  if logs and logs.poll() is None:logs.kill();logs.wait()
  if p.poll() is None:p.kill();p.wait()
