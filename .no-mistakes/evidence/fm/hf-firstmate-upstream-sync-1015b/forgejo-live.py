import os,json,pathlib,subprocess,urllib.request,urllib.error,base64,time,threading,http.server,re,signal
root=pathlib.Path.cwd(); temp=root/'.validation-tmp'; ev=pathlib.Path('/Users/jarad/.no-mistakes/evidence/01M4YFDQR9GTFBYVCE7QQNKRPE'); base='http://127.0.0.1:3987'; auth='Basic '+base64.b64encode(b'fixture:disposable-validation-password').decode()
log=open(ev/'forgejo-live.log','w');
def note(s):print(s,flush=True);log.write(s+'\n');log.flush()
def api(path,data=None,method=None,token=None):
 headers={'Authorization':('token '+token) if token else auth,'Content-Type':'application/json'}
 req=urllib.request.Request(base+'/api/v1'+path,data=None if data is None else json.dumps(data).encode(),headers=headers,method=method)
 with urllib.request.urlopen(req,timeout=20) as r:return json.loads(r.read() or 'null')
env=os.environ.copy();env.update(PATH=str(temp/'tools')+':'+env['PATH'],HOME=str(temp/'fjhome/home'),XDG_CONFIG_HOME=str(temp/'fjhome/xdg'))
for k in ['FM_ROOT_OVERRIDE','FM_DATA_OVERRIDE','FM_STATE_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_CONFIG_OVERRIDE','FM_GATE_REFUSE_BYPASS','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:env.pop(k,None)
# A transparent forwarding proxy records real Forgejo responses. In the auth-failure case it revokes the disposable token using Forgejo's own API after page 1.
mode='normal';token_record=None
class Proxy(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):self.forward()
 def do_POST(self):self.forward()
 def forward(self):
  global mode
  data=self.rfile.read(int(self.headers.get('Content-Length','0'))) or None
  headers={k:v for k,v in self.headers.items() if k.lower() not in ['host','connection','content-length']}
  req=urllib.request.Request(base+self.path,data=data,headers=headers,method=self.command)
  try:r=urllib.request.urlopen(req,timeout=30)
  except urllib.error.HTTPError as e:r=e
  body=r.read();code=r.code
  if '/status?' in self.path:
   note(f'UPSTREAM {self.command} {self.path} HTTP {code}: '+body.decode())
  if mode=='revoke' and '/status?' in self.path and 'page=1' in self.path:
   api('/users/fixture/tokens/'+str(token_record['id']),method='DELETE');mode='revoked';note('Revoked disposable token through actual Forgejo API after successful first status page')
  self.send_response(code);self.send_header('Content-Type',r.headers.get('Content-Type','application/json'));self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
proxy=http.server.ThreadingHTTPServer(('127.0.0.1',3988),Proxy);threading.Thread(target=proxy.serve_forever,daemon=True).start()
def cli(args,**kwargs):
 p=subprocess.run(args,env=env,text=True,capture_output=True,**kwargs);note('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode));return p
def login(name):
 global token_record
 token_record=api('/users/fixture/tokens',{'name':name,'scopes':['all']})
 p=subprocess.run([str(temp/'tools/tea'),'login','add','--name','fm-live','--url','http://localhost:3988','--token',token_record['sha1'],'--no-version-check'],env=env,text=True,capture_output=True)
 assert p.returncode==0,p.stderr
# forge and CLI credentials are entirely disposable and kept within this worktree.
try:
 repo=api('/user/repos',{'name':'fixture-repo','auto_init':True,'default_branch':'main','private':False})
 def make_pr(branch,contexts):
  api('/repos/fixture/fixture-repo/branches',{'new_branch_name':branch,'old_branch_name':'main'})
  api('/repos/fixture/fixture-repo/contents/'+branch+'.txt',{'branch':branch,'message':'Add validation change','content':base64.b64encode((branch+'\n').encode()).decode()})
  pr=api('/repos/fixture/fixture-repo/pulls',{'head':branch,'base':'main','title':'Disposable '+branch,'body':'Disposable validation change. No execution evidence claimed.'})
  for i in range(contexts):api('/repos/fixture/fixture-repo/statuses/'+pr['head']['sha'],{'state':'success','context':f'validation/{i:02}','description':'Disposable success status'})
  for i in range(30):
   pr=api('/repos/fixture/fixture-repo/pulls/'+str(pr['number']))
   if pr['mergeable']:return pr
   time.sleep(.2)
  raise RuntimeError('Forgejo did not find the disposable PR mergeable')
 login('firstmate-live-valid')
 prs=[make_pr('valid-null-terminal',51),make_pr('authentication-fails-after-page1',51),make_pr('no-ci',0)]
 home=temp/'merge-home';subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,capture_output=True);(home/'config/backlog-backend').write_text('manual\n');env['FM_HOME']=str(home)
 for idx,pr in enumerate(prs):
  task='live-'+str(idx);wt=temp/task
  p=cli(['git','clone','-q','--branch',pr['head']['ref'],'http://localhost:3987/fixture/fixture-repo.git',str(wt)]);assert p.returncode==0
  (home/'state'/f'{task}.meta').write_text(f'window=isolated\nworktree={wt}\nproject={wt}\nkind=ship\nmode=no-mistakes\n')
  url=f'https://localhost/fixture/fixture-repo/pulls/{pr["number"]}'
  if idx==0:
   body=cli(['bin/fm-pr-body-preflight.sh','--forgejo-url',url,str(wt/'body.md'),str(wt),str(wt)]);assert body.returncode==0
   assert (wt/'body.md').read_text()==pr['body'];note('Complete Forgejo published body passed real tea readback preflight')
   (ev/'forgejo-body-readback.md').write_text((wt/'body.md').read_text())
  if idx==1:mode='revoke'
  if idx==2:
   # Replace the revoked disposable login in its isolated XDG config.
   subprocess.run([str(temp/'tools/tea'),'logout','fm-live'],env=env,capture_output=True,check=True);login('firstmate-live-empty')
  result=cli(['bin/fm-pr-merge.sh',task,url,'--','--merge'])
  actual=api('/repos/fixture/fixture-repo/pulls/'+str(pr['number']))
  (ev/f'forgejo-pr-{idx}-after.json').write_text(json.dumps(actual,indent=2))
  if idx==0:
   assert result.returncode==0 and actual['merged'] is True
   note('PASS: 51 real successful status contexts and real null terminal page merged at verified head')
  else:
   assert result.returncode!=0 and actual['merged'] is False
   expected='unreadable' if idx==1 else 'none'
   assert 'combined commit status is "'+expected+'"' in result.stderr,result.stderr
   note('PASS: '+('real upstream authentication error after page 1' if idx==1 else 'real missing CI')+' refused without merging')
finally:
 proxy.shutdown();proxy.server_close();log.close()
 server=(ev/'forgejo-server.log').read_text();m=re.search(r'Starting Forgejo on PID: (\d+)',server)
 if m:os.kill(int(m.group(1)),signal.SIGTERM)
