#!/usr/bin/env python3
"""Real macOS local-name, authentication, SSE and TLS checks with a disposable daemon home.

Run after building noodled: python3 tests/local-domains.py.
It starts no VM or model, changes no hosts/resolver files and never trusts a CA globally.
"""
from pathlib import Path
import subprocess,os,json,tempfile,time,socket,shutil,threading,http.server,datetime
import argparse
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bin-dir',type=Path,default=root/'.build/debug')
parser.add_argument('--output',type=Path,default=root/'build/local-domain-check')
args=parser.parse_args()
args.output.mkdir(parents=True,exist_ok=True)
work=Path(tempfile.mkdtemp(prefix='noodle-local-route.',dir='/tmp'))
home=work/'home'; home.mkdir()
env=os.environ.copy();env.update({'NOODLE_HOME':str(home),'NOODLE_NAMES_HTTP_PORT':'0','NOODLE_NAMES_HTTPS_PORT':'0','NOODLE_HTTP_PORT':'0','NOODLE_HTTPS_PORT':'0'})
record={'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'environment':'real headless daemon, isolated home, standard-library authenticated HTTP/SSE fixture; no VM/model','checks':{}}
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  if self.headers.get('Authorization')!='Bearer fixture-only-key':self.send_error(401);return
  data=json.dumps({'data':[{'id':'fixture-model'}]}).encode();self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_POST(self):
  if self.headers.get('Authorization')!='Bearer fixture-only-key':self.send_error(401);return
  self.rfile.read(int(self.headers.get('Content-Length','0')))
  data=b'data: {"choices":[{"delta":{"content":"named route works"}}]}\n\ndata: [DONE]\n\n'
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
log=(args.output/'daemon.log').open('w')
daemon=None;leases=[]
def command(args,**kwargs):
 r=subprocess.run(args,capture_output=True,text=True,timeout=15,**kwargs)
 if r.returncode:raise RuntimeError(r.stderr[-1200:])
 return r.stdout
def api(method,path,body=None):
 args=['/usr/bin/curl','--disable','--silent','--show-error','--noproxy','*','--max-time','10','--unix-socket',str(home/'run/docker.sock'),'-X',method,'http://localhost'+path]
 if body is not None:args+=['-H','Content-Type: application/json','--data-binary',json.dumps(body)]
 value=command(args)
 return json.loads(value) if value else None
def request(url,key=True,ca=None,host=None,post=False):
 args=['/usr/bin/curl','--disable','--silent','--show-error','--noproxy','*','--http1.1','--max-time','10','-w','\n%{http_code}',url]
 if key:args+=['-H','Authorization: Bearer fixture-only-key']
 if ca:args+=['--cacert',ca,'--tls-max','1.2']
 if host:args+=['-H','Host: '+host]
 if post:args+=['-H','Content-Type: application/json','--data-binary','{}']
 value=command(args);data,code=value.rsplit('\n',1);return int(code),data
try:
 daemon=subprocess.Popen([str(args.bin_dir/'noodled')],env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
 deadline=time.monotonic()+10
 while not (home/'run/docker.sock').exists():
  if daemon.poll() is not None or time.monotonic()>deadline:raise RuntimeError('Daemon failed to start')
  time.sleep(.05)
 host='route-'+str(os.getpid())+'.noodle.local'
 route=api('POST','/noodle/dev',{'host':host,'port':server.server_port,'ownerPID':os.getpid()});leases.append(route['token'])
 addresses={item[4][0] for item in socket.getaddrinfo(host,None,socket.AF_UNSPEC,socket.SOCK_STREAM)}
 assert addresses=={'127.0.0.1','::1'},addresses
 record['checks']['ordinary_dual_family_getaddrinfo_loopback']=True
 url='http://'+host+':'+str(route['port'])+'/v1/models'
 code,body=request(url);assert code==200 and 'fixture-model' in body
 record['checks']['http_auth_forwarding']=True
 assert request(url,key=False)[0]==401;record['checks']['missing_key_rejected']=True
 code,body=request(url.replace('/models','/chat/completions'),post=True);assert code==200 and 'data: [DONE]' in body and 'named route works' in body
 record['checks']['sse_forwarding']=True
 assert request(url,host='foreign.example')[0]==404;record['checks']['unknown_host_rejected']=True
 tls='https://'+host+':'+str(route['httpsPort'])+'/v1/models'
 code,body=request(tls,ca=route['ca']);assert code==200 and 'fixture-model' in body
 record['checks']['https_scoped_ca_and_hostname_verified']=True
 assert '/tls/noodle-local/' in route['ca'];record['checks']['separate_branded_ca']=True
 legacy=api('POST','/noodle/dev',{'host':'legacy-'+str(os.getpid())+'.localhost','port':server.server_port,'ownerPID':os.getpid()});leases.append(legacy['token'])
 # A Host-header request proves legacy routing independently of OS *.localhost handling.
 code,body=request('http://127.0.0.1:'+str(legacy['port'])+'/v1/models',host=legacy['host']);assert code==200 and 'fixture-model' in body
 record['checks']['legacy_localhost_route_preserved']=True
 api('DELETE','/noodle/dev/'+route['token']);leases.remove(route['token'])
 names=api('GET','/noodle/names');assert host not in [x['host'] for x in names['names']]
 assert host not in (names.get('dns') or {}).get('registered',[])
 record['checks']['lease_and_dns_record_removed']=True
 record['passed']=True
 print(json.dumps(record,indent=2),flush=True)
finally:
 for token in leases:
  try:api('DELETE','/noodle/dev/'+token)
  except Exception:pass
 if daemon is not None and daemon.poll() is None:
  daemon.terminate()
  try:daemon.wait(timeout=10)
  except subprocess.TimeoutExpired:daemon.kill();daemon.wait(timeout=5)
 server.shutdown();server.server_close();log.close();shutil.rmtree(work)
 record['owned_daemon_stopped']=daemon is None or daemon.poll() is not None
 record['temporary_home_removed']=not work.exists()
 (args.output/'check.json').write_text(json.dumps(record,indent=2)+'\n')
