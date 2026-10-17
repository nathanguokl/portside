from pathlib import Path
import importlib.util,json,sys,tempfile,time
spec=importlib.util.spec_from_file_location('setup_bottle_dxvk',Path('scripts/setup-bottle-dxvk.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='output-fixture-',dir='.artifacts/downloads/dxvk-helper-tests') as directory:
 installer=module.Installer(Path(directory),{'id':'fixture'},Path(sys.executable),Path(sys.executable))
 start=time.monotonic()
 _,output=installer.command(Path(sys.executable),['-c',"import subprocess,sys;subprocess.Popen([sys.executable,'-c','import time;time.sleep(3)']);print('direct command completed')"],timeout=5)
 elapsed=time.monotonic()-start
 assert elapsed<1.5 and output=='direct command completed',(elapsed,output)
 print(f'PASS inherited stdout child does not delay direct command completion ({elapsed:.3f}s)')
 _,output=installer.command(Path(sys.executable),['-c',"print('x'*100000);print('registry output at end')"],timeout=5)
 assert len(output.encode())<=65536 and output.endswith('registry output at end')
 print('PASS diagnostics are bounded to the last64KiB and retain final command output')
 try:
  installer.command(Path(sys.executable),['-c','import time;time.sleep(3)'],timeout=.1)
 except module.SetupError as error:
  assert 'timed out' in str(error)
 else:raise AssertionError('Expected timeout')
 print('PASS direct command timeout is bounded and actionable')
 assert installer.environment['MVK_CONFIG_LOG_LEVEL']=='0'
 print('PASS MoltenVK informational logging is explicitly disabled')
import os,subprocess
before=dict(os.environ)
try:
 os.environ.update(LC_MESSAGES='zh_CN.UTF-8',LC_CTYPE='zh_CN.UTF-8',LANG='zh_CN.UTF-8',LANGUAGE='zh_CN')
 installer=module.Installer(Path('.artifacts/downloads/dxvk-helper-tests'),{'id':'fixture'},Path(sys.executable),Path(sys.executable))
 assert installer.environment['LANG']==installer.environment['LC_ALL']=='en_US.UTF-8'
 assert 'LC_MESSAGES' not in installer.environment and 'LC_CTYPE' not in installer.environment and 'LANGUAGE' not in installer.environment
 assert os.environ['LC_MESSAGES']=='zh_CN.UTF-8'
 print('PASS command locale is normalized without changing the caller environment')
finally:
 os.environ.clear();os.environ.update(before)
root=Path.cwd();home=root/'.artifacts/downloads/dxvk-helper-tests/round-trip/Application Support 空間/Portside'
base=[sys.executable,str(root/'scripts/setup-bottle-dxvk.py'),'AAAAAAAA-1111-4111-8111-111111111111','--home',str(home)]
r=subprocess.run(base+['--component-dir',str(root/'.build/dxvk-compat/component')],capture_output=True,text=True,timeout=30)
assert r.returncode==0,r.stderr
r=subprocess.run(base+['--remove'],capture_output=True,text=True,timeout=30)
assert r.returncode==0,r.stderr
print('PASS removal succeeds without --component-dir')
r=subprocess.run(base+['--remove','--component-dir','/missing/component/path'],capture_output=True,text=True,timeout=30)
assert r.returncode==0,r.stderr
print('PASS removal ignores an unavailable optional component directory')
r=subprocess.run(base,capture_output=True,text=True,timeout=30)
assert r.returncode!=0 and '--component-dir is required' in r.stderr,r.stderr
print('PASS installation still requires an explicit component directory')
