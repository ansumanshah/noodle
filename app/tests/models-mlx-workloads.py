#!/usr/bin/env python3
"""Real packaged MLX/private-bridge acceptance. Run `just test-models-mlx-workloads`
with nothing else heavy running. Only a repository-built scratch image receives the
fresh disposable session key; the weights are prepared by the recipe and the MLX
runtime downloads into the isolated home on the first serve.
"""
from pathlib import Path
import hashlib,json,os,shutil,socket,subprocess,tarfile,tempfile,time
root=Path(__file__).resolve().parent.parent.parent
base=root/'build/models-mlx'
app=root/'build/Noodle.app/Contents'
cli=app/'Helpers/noodle'
daemon_exe=app/'MacOS/noodled'
required=[cli,daemon_exe,root/'build/tools/docker',
          base/'inference-home/models/weights/qwen3-0.6b-mlx.mlx']
if any(not path.exists() for path in required):
 raise SystemExit('Run just test-models-mlx-workloads to prepare the app, Docker and weights.')
subprocess.run(['/bin/bash',str(root/'scripts/zig.sh'),'cc','-target','aarch64-linux-musl','-static','-Os','-s',
                '-Wall','-Wextra','-Werror',str(root/'tests/probe/model-http.c'),'-o',str(base/'model-http-probe')],check=True)
work=Path(tempfile.mkdtemp(prefix='noodle-models-bridge.',dir='/tmp'))
env={**os.environ,'NOODLE_HOME':str(work),'NOODLE_RESOURCES':str(app/'Resources'),
 'NOODLE_NO_ACTIVATE':'1',
 'DOCKER_HOST':'unix://'+str(work/'run/docker.sock'),'DOCKER_CONFIG':str(work/'docker-config')}
env.pop('DOCKER_CONTEXT',None)
for key in ('DOCKER_TLS_VERIFY','DOCKER_CERT_PATH'):env.pop(key,None)
docker=root/'build/tools/docker'
log=(base/'workload-bridge-daemon.log').open('w')
daemon=None
result={}

def command(args,**kwargs):
 process=subprocess.run([str(x) for x in args],env=env,capture_output=True,timeout=240,**kwargs)
 if process.returncode:
  message=process.stderr.decode(errors='replace')
  key=work/'models/key'
  if key.exists():message=message.replace(key.read_text().strip(),'[redacted]')
  (base/'workload-bridge-command-error.log').write_text(message)
  raise RuntimeError('Bridge command failed: '+message)
 return process

def model(args):return command([cli,'model',*args])

def request(gateway,port,key=None):
 body=json.dumps({'model':'qwen3-0.6b-mlx','messages':[{'role':'user','content':'Say hello in one short sentence.'}],
 'max_tokens':32,'temperature':0,'chat_template_kwargs':{'enable_thinking':False}})
 headers=f'POST /v1/chat/completions HTTP/1.1\r\nHost: host.docker.internal\r\nContent-Type: application/json\r\nContent-Length: {len(body.encode())}\r\nConnection: close\r\n'
 if key:headers+='Authorization: Bearer '+key+'\r\n'
 # Credentials and prompt travel through stdin, never Docker or guest process arguments.
 data=(headers+'\r\n'+body).encode()
 response=command([docker,'run','--rm','-i','noodle-model-probe:owned','/probe',gateway,str(port)],input=data).stdout
 (base/('workload-bridge-authenticated.http' if key else 'workload-bridge-unauthenticated.http')).write_bytes(response.replace((key or 'not-a-key').encode(),b'[redacted]'))
 return response

try:
 (work/'vm.json').write_text(json.dumps({'cpus':2,'memory_mib':2048}))
 weights=work/'models/weights';weights.mkdir(parents=True)
 command(['/bin/cp','-cR',base/'inference-home/models/weights/qwen3-0.6b-mlx.mlx',weights])
 daemon=subprocess.Popen([str(daemon_exe)],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 for _ in range(300):
  if daemon.poll() is not None:raise RuntimeError('isolated daemon exited; inspect workload-bridge-daemon.log')
  check=subprocess.run(['/usr/bin/curl','--silent','--fail','--max-time','1','--unix-socket',str(work/'run/docker.sock'),'http://localhost/_ping'],capture_output=True)
  if check.returncode==0:break
  time.sleep(.1)
 else:raise RuntimeError('isolated daemon did not become ready')
 with tarfile.open(work/'probe-rootfs.tar','w') as archive:
  info=archive.gettarinfo(str(base/'model-http-probe'),arcname='probe')
  info.uid=info.gid=0;info.uname=info.gname='';info.mode=0o755
  with (base/'model-http-probe').open('rb') as binary:archive.addfile(info,binary)
 command([docker,'import',work/'probe-rootfs.tar','noodle-model-probe:owned'])
 command([docker,'run','-d','--name','bridge-hold','noodle-model-probe:owned','/probe','hold'])
 gateway=command([docker,'exec','bridge-hold','/probe','gateway']).stdout.decode().strip()
 assert gateway and gateway!='127.0.0.1'
 print('VM bridge ready at '+gateway,flush=True)
 with socket.socket() as probe:probe.bind(('127.0.0.1',0));port=probe.getsockname()[1]
 serve_log=(base/'workload-bridge-serve.log').open('w')
 serving=subprocess.Popen([str(cli),'model','serve','qwen3-0.6b-mlx','--workloads',gateway,'--port',str(port)],env=env,stdout=serve_log,stderr=subprocess.STDOUT)
 diagnosed=False
 for _ in range(400):
  if serving.poll() is not None:break
  runner=work/'models/runner.log'
  if not diagnosed and runner.exists() and 'Server listening on' in runner.read_text(errors='replace'):
   key=(work/'models/key').read_text().strip()
   url=f'http://{gateway}:{port}/v1/models'
   diagnostic=subprocess.run(['/usr/bin/curl','--disable','--noproxy','*','-sS','--max-time','3','--header','@'+str(work/'models/auth.header'),'-w','\nstatus=%{http_code}\n',url],capture_output=True,text=True)
   (base/'workload-bridge-health.log').write_text((diagnostic.stdout+'\n'+diagnostic.stderr).replace(key,'[redacted]'))
   print('Mac bridge health exit',diagnostic.returncode,flush=True)
   session=json.loads((work/'models/session.json').read_text())
   listeners=subprocess.run(['/usr/sbin/lsof','-a','-p',str(session['process']['pid']),'-iTCP','-sTCP:LISTEN','-F','n'],capture_output=True,text=True)
   (base/'workload-bridge-listeners.log').write_text(listeners.stdout)
   diagnosed=True
  time.sleep(.5)
 serving.wait(timeout=10);serve_log.close()
 assert serving.returncode==0,'model serve failed; inspect workload-bridge-serve.log and health.log'
 endpoint=json.loads(model(['endpoint','--json']).stdout)
 expected=f'http://{gateway}:{port}/v1'
 assert endpoint['baseURL']==endpoint['workloadBaseURL']==expected
 assert endpoint['backend']=='mlx'
 unauth=request(gateway,port)
 assert b' 401 ' in unauth.split(b'\r\n',1)[0]
 authenticated=request(gateway,port,endpoint['apiKey'])
 assert b' 200 ' in authenticated.split(b'\r\n',1)[0]
 payload=json.loads(authenticated.split(b'\r\n\r\n',1)[1])
 assert payload['choices'][0]['message']['content'].strip()
 with socket.socket() as probe:assert probe.connect_ex(('127.0.0.1',port))!=0
 result={'passed':True,'backend':'mlx','image':'noodle-model-probe:owned','base_image':'scratch','vm_cpus':2,'vm_memory_mib':2048,
 'probe_source_sha256':hashlib.sha256((root/'tests/probe/model-http.c').read_bytes()).hexdigest(),
 'probe_binary_sha256':hashlib.sha256((base/'model-http-probe').read_bytes()).hexdigest(),
 'workload_base_url':expected,'unauthenticated_status':401,'authenticated_status':200,
 'response':payload,'loopback_not_bound':True,'boundary':'real docker CLI container, native MLX server, private VM bridge; not a Compose or k3s pod test'}
 print('Real Docker container: MLX bridge inference 200; missing key 401; no loopback/wildcard listener',flush=True)
finally:
 runner=work/'models/runner.log'
 if runner.exists():shutil.copyfile(runner,base/'workload-bridge-runner.log')
 stopped=subprocess.run([str(cli),'model','stop'],env=env,capture_output=True,timeout=35)
 result['model_stop_returncode']=stopped.returncode
 if stopped.returncode:result['passed']=False
 if daemon is not None and daemon.poll() is None:
  daemon.terminate()
  try:daemon.wait(timeout=40)
  except subprocess.TimeoutExpired:daemon.kill();daemon.wait(timeout=10)
 result['daemon_returncode']=daemon.returncode if daemon else None
 log.close()
 (base/'workload-bridge.json').write_text(json.dumps(result,indent=2)+'\n')
 shutil.rmtree(work)

if not result.get('passed') or result.get('model_stop_returncode') != 0 or result.get('daemon_returncode') != 0:
 raise SystemExit('MLX workload or cleanup failed; inspect build/models-mlx/workload-bridge*.log')
