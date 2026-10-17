from pathlib import Path
import json,shutil,subprocess,tarfile
root=Path.cwd();fixture=root/'.artifacts/downloads/dxvk-helper-tests/build-pin-refusal'
if fixture.exists():shutil.rmtree(fixture)
(fixture/'scripts').mkdir(parents=True)
for name in ['build-dxvk-compat.sh','setup-bottle-dxvk.py']:shutil.copyfile(root/'scripts'/name,fixture/'scripts'/name)
shutil.copytree(root/'third_party/dxvk-compat',fixture/'third_party/dxvk-compat')
(fixture/'downloads').mkdir()
inputs=json.loads((fixture/'third_party/dxvk-compat/inputs.json').read_text())
for key in ['source','binaries']:
 name=inputs[key]['filename'];shutil.copyfile(root/'.build/dxvk-compat/downloads'/name,fixture/'downloads'/name)
inputs['pinnedDLLSHA256']['x32/d3d10core.dll']='0'*64
(fixture/'third_party/dxvk-compat/inputs.json').write_text(json.dumps(inputs))
staged=fixture/'.build/dxvk-compat/component';staged.mkdir(parents=True)
(staged/'sentinel').write_bytes(b'previous component')
archive=fixture/'dist/Portside-DXVK-Compat-1.10.3-portside1.tar.gz';archive.parent.mkdir();archive.write_bytes(b'previous archive')
r=subprocess.run(['bash',str(fixture/'scripts/build-dxvk-compat.sh')],capture_output=True,text=True,timeout=60)
(fixture/'build.stdout').write_text(r.stdout);(fixture/'build.stderr').write_text(r.stderr)
assert r.returncode!=0 and 'mingw-w64 14.0.0_3' in r.stderr and 'GCC 16.2.0' in r.stderr,r.stderr
assert (staged/'sentinel').read_bytes()==b'previous component' and archive.read_bytes()==b'previous archive'
print('PASS unsupported output hash refuses publication, reports exact toolchain, and preserves previous artifacts')
archive=root/'dist/Portside-DXVK-Compat-1.10.3-portside1.tar.gz'
with tarfile.open(archive) as source:
 name='Portside-DXVK-Compat-1.10.3-portside1/source/scripts/setup-bottle-dxvk.py'
 assert source.extractfile(name).read()==(root/'scripts/setup-bottle-dxvk.py').read_bytes()
print('PASS optional archive includes the current independent setup/removal helper')
