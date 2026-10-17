from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys,uuid,time
ROOT=Path.cwd()
BASE=ROOT/'.artifacts/downloads/dxvk-helper-tests'
COMPONENT=ROOT/'.build/dxvk-compat/component'
HELPER=ROOT/'scripts/setup-bottle-dxvk.py'
IDS=['AAAAAAAA-1111-4111-8111-111111111111','BBBBBBBB-2222-4222-8222-222222222222']
CASES=[]
FAKE_WINE='''#!/usr/bin/env python3
import sys,os,json
from pathlib import Path
p=Path(os.environ['WINEPREFIX'])
a=sys.argv[1:]
with (p/'.fake-commands.jsonl').open('a') as f:f.write(json.dumps(a)+'\\n')
db=p/'.fake-registry.json'
r=json.loads(db.read_text()) if db.exists() else {}
name=a[a.index('/v')+1]
if a[1]=='query':
 if name not in r: print('reg: Unable to find the specified registry key or value');sys.exit(1)
 sys.stdout.write('HKEY_CURRENT_USER\\\\Software\\\\Wine\\\\DllOverrides\\r\\n    '+name+'    REG_SZ    '+r[name]+'\\r\\n')
elif a[1]=='add':
 value=a[a.index('/d')+1]
 fail=p/'.fail-add'
 if fail.exists() and name=='d3d11' and value=='native,builtin':fail.unlink();print('injected registry error');sys.exit(2)
 r[name]=value;db.write_text(json.dumps(r));print('success')
elif a[1]=='delete':
 if name not in r:print('reg: Unable to find the specified registry key or value');sys.exit(1)
 del r[name];db.write_text(json.dumps(r));print('success')
else:sys.exit(9)
'''
FAKE_SERVER='''#!/usr/bin/env python3
import os,sys,json,time
from pathlib import Path
p=Path(os.environ['WINEPREFIX'])
with (p/'.fake-commands.jsonl').open('a') as f:f.write(json.dumps(['wineserver',*sys.argv[1:]])+'\\n')
if sys.argv[1:]!=['-w']:sys.exit(9)
if (p/'.busy').exists():time.sleep(60)
'''

def paths(prefix):
 return {'x32/d3d10core.dll':prefix/'drive_c/windows/syswow64/d3d10core.dll','x32/d3d11.dll':prefix/'drive_c/windows/syswow64/d3d11.dll','x64/d3d10core.dll':prefix/'drive_c/windows/system32/d3d10core.dll','x64/d3d11.dll':prefix/'drive_c/windows/system32/d3d11.dll'}

def describe(path):
 if path.is_symlink():return ('symlink',os.readlink(path))
 if not path.exists():return ('absent',)
 return ('file',path.read_bytes(),path.stat().st_mode&0o777)

def fixture(name):
 d=BASE/name
 if d.exists():shutil.rmtree(d)
 home=d/'Application Support 空間/Portside';(home/'Bottles').mkdir(parents=True)
 runtime=d/'Runtime with space';runtime.mkdir(parents=True)
 for filename,data in [('wine',FAKE_WINE),('wineserver',FAKE_SERVER)]:
  f=runtime/filename;f.write_text(data);f.chmod(0o755)
 shared=runtime/'shared-dll';shared.write_bytes(b'Shared runtime sentinel; must remain unchanged')
 catalog={'schemaVersion':1,'bottles':[],'apps':[]}
 for i,ident in enumerate(IDS):
  p=home/'Bottles'/ident
  (p/'drive_c/windows/system32').mkdir(parents=True);(p/'drive_c/windows/syswow64').mkdir()
  (p/'.portside-bottle.json').write_text(json.dumps({'owner':'app.portside.mac','bottleID':ident}))
  fs=paths(p)
  fs['x32/d3d11.dll'].symlink_to(shared)
  fs['x64/d3d10core.dll'].write_bytes(b'Original private DLL');fs['x64/d3d10core.dll'].chmod(0o640)
  fs['x64/d3d11.dll'].symlink_to('../original-dangling.dll')
  (p/'.fake-registry.json').write_text(json.dumps({'d3d10core':'builtin','dxgi':'native'}))
  catalog['bottles'].append({'id':ident,'name':'測試 '+str(i),'directoryName':ident,'initialized':True,'runtime':{'wineURL':(runtime/'wine').as_uri(),'version':'fixture-wine','source':'fake command fixture'}})
 (home/'library.json').write_text(json.dumps(catalog))
 return home,home/'Bottles'/IDS[0],home/'Bottles'/IDS[1],shared

def invoke(home,component=COMPONENT,remove=False):
 cmd=[sys.executable,str(HELPER),IDS[0],'--home',str(home),'--component-dir',str(component)]
 if remove:cmd.append('--remove')
 return subprocess.run(cmd,text=True,capture_output=True,timeout=40)

def ok(value,description):
 assert value,description
 CASES.append(description)

home,p,other,shared=fixture('round-trip')
original={n:describe(f) for n,f in paths(p).items()};registry=(p/'.fake-registry.json').read_bytes();catalog=(home/'library.json').read_bytes()
other_original={n:describe(f) for n,f in paths(other).items()};shared_original=shared.read_bytes()
r=invoke(home);ok(r.returncode==0,'Install succeeds with spaces/Unicode paths: '+r.stderr)
statepath=p/'.portside-components/dxvk-macos/state.json';s=json.loads(statepath.read_text());ok(s['status']=='installed','Installed state persists')
ok(all(hashlib.sha256(f.read_bytes()).hexdigest()==json.loads((COMPONENT/'component.json').read_text())['files'][n] for n,f in paths(p).items()),'All four installed DLLs match pinned component hashes')
ok(shared.read_bytes()==shared_original,'Replacing builtin symlink leaves shared runtime target unchanged')
ok({n:describe(f) for n,f in paths(other).items()}==other_original and (home/'library.json').read_bytes()==catalog,'Other bottle and library catalog remain unchanged')
backups={f.name:f.read_bytes() for f in (p/'.portside-components/dxvk-macos/originals').iterdir()}
r=invoke(home);ok(r.returncode==0,'Repeated install is idempotent')
ok({f.name:f.read_bytes() for f in (p/'.portside-components/dxvk-macos/originals').iterdir()}==backups,'Repeated install preserves first backups')
r=invoke(home,remove=True);ok(r.returncode==0,'Removal succeeds: '+r.stderr)
ok({n:describe(f) for n,f in paths(p).items()}==original,'Removal restores regular files, modes, absolute links, dangling links, and absent entries')
ok(json.loads((p/'.fake-registry.json').read_text())==json.loads(registry),'Removal restores original present/missing registry overrides')
r=invoke(home);ok(r.returncode==0,'Reinstall after removal succeeds using preserved first snapshot')
r=invoke(home,remove=True);ok(r.returncode==0,'Second round-trip succeeds')
ok(shared.read_bytes()==shared_original,'Shared runtime remains unchanged after both round-trips')
commands=[json.loads(l) for l in (p/'.fake-commands.jsonl').read_text().splitlines()]
ok(not any('-k' in c for c in commands),'No automatic bottle kill command is used')

home,p,other,shared=fixture('busy')
(p/'.busy').touch();start=time.monotonic();r=invoke(home)
ok(r.returncode!=0 and 'running' in r.stderr and time.monotonic()-start<5,'Active-prefix probe is bounded and explains stop/retry')
ok(not (p/'.portside-components').exists(),'Active-prefix refusal changes no component files')

home,p,other,shared=fixture('ownership')
(p/'.portside-bottle.json').write_text(json.dumps({'owner':'different.app','bottleID':IDS[0]}));r=invoke(home)
ok(r.returncode!=0 and not (p/'.fake-commands.jsonl').exists(),'Wrong ownership is refused before any runtime invocation')

home,p,other,shared=fixture('system-directory-link')
system=p/'drive_c/windows/system32';system.rename(system.with_name('original-system32'));system.symlink_to(other/'drive_c/windows/system32')
r=invoke(home);ok(r.returncode!=0 and not (p/'.fake-commands.jsonl').exists(),'System directory symlink outside selected prefix is refused')

home,p,other,shared=fixture('tampered-component')
bad=home.parent/'bad-component';bad.mkdir()
for arch in ['x32','x64']:shutil.copytree(COMPONENT/arch,bad/arch)
shutil.copyfile(COMPONENT/'component.json',bad/'component.json')
f=bad/'x32/d3d11.dll';f.write_bytes(f.read_bytes()+b'corrupt')
r=invoke(home,bad);ok(r.returncode!=0 and not (p/'.fake-commands.jsonl').exists(),'Tampered component DLL is refused before runtime invocation')

home,p,other,shared=fixture('registry-failure')
original={n:describe(f) for n,f in paths(p).items()};registry=json.loads((p/'.fake-registry.json').read_text());(p/'.fail-add').touch()
r=invoke(home);ok(r.returncode!=0,'Injected registry write failure returns an error')
ok({n:describe(f) for n,f in paths(p).items()}==original and json.loads((p/'.fake-registry.json').read_text())==registry,'Injected write failure rolls back all DLLs and registry overrides')
s=json.loads((p/'.portside-components/dxvk-macos/state.json').read_text());ok(s['status']=='rolled-back','Rollback state is recorded')

home,p,other,shared=fixture('foreign-lock')
d=p/'.portside-components/dxvk-macos';(d/'originals').mkdir(parents=True);(d/'operation.lock').mkdir()
r=invoke(home);ok(r.returncode!=0 and (d/'operation.lock').exists(),'A second operation preserves the existing operation lock')

home,p,other,shared=fixture('manual-edit')
r=invoke(home);assert r.returncode==0,r.stderr
changed=paths(p)['x32/d3d11.dll'];changed.write_bytes(b'User replacement DLL')
r=invoke(home,remove=True);ok(r.returncode!=0 and changed.read_bytes()==b'User replacement DLL','Removal refuses to overwrite a later manual DLL edit')

home,p,other,shared=fixture('interrupted-install')
original={n:describe(f) for n,f in paths(p).items()};registry=json.loads((p/'.fake-registry.json').read_text())
r=invoke(home);assert r.returncode==0,r.stderr
statepath=p/'.portside-components/dxvk-macos/state.json';state=json.loads(statepath.read_text());state['status']='installing';statepath.write_text(json.dumps(state))
paths(p)['x32/d3d10core.dll'].unlink()
r=invoke(home,remove=True);ok(r.returncode==0 and {n:describe(f) for n,f in paths(p).items()}==original and json.loads((p/'.fake-registry.json').read_text())==registry,'Removal recovers a partially completed install when entries remain original/component values')

(BASE/'results.json').write_text(json.dumps(CASES,indent=2,ensure_ascii=False)+'\n')
print(f'{len(CASES)} fixture checks passed. No real Wine executable was invoked.')
for case in CASES:print('PASS '+case)
