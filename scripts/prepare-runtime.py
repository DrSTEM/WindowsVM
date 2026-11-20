#!/usr/bin/env python3
"""Prepare the dependency closure for the ARM VM engine and Metal console.

Input must be the verified official UTM bundle. No UTM UI or assets are copied.
This creates local build inputs, not a public distribution licence clearance.
"""
from pathlib import Path
import argparse, json, plistlib, re, shutil, subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('utm_app', type=Path, help='Official, signed UTM.app from the pinned release')
parser.add_argument('--output', type=Path, default=root/'Runtime', help='New output directory (must not exist)')
options = parser.parse_args()
app = options.utm_app.resolve()
lock = json.loads((root/'scripts/runtime-lock.json').read_text())
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
identity = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(app)], check=True, capture_output=True, text=True)
if f"TeamIdentifier={lock['utm_team_id']}" not in identity.stderr.splitlines():
    raise RuntimeError('UTM has an unexpected signing identity')
subprocess.run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)], check=True)
source = app/'Contents'
with (source/'Info.plist').open('rb') as stream:
    version = plistlib.load(stream)['CFBundleShortVersionString']
if version != lock['utm_version']:
    raise RuntimeError(f"Expected UTM {lock['utm_version']}, found {version}")
out = options.output.resolve()
if out.exists():
    raise RuntimeError('Output already exists. Use scripts/setup.sh --refresh for a staged replacement.')
out.mkdir(parents=True)
frameworks = out/'Frameworks'
frameworks.mkdir(parents=True, exist_ok=True)
needed = [
    'qemu-aarch64-softmmu.framework',
    'spice-client-glib-2.0.8.framework',
    'EGL.framework',
    'GLESv2.framework',
    'dxmt-native.framework',
]
seen = set()
manifest = []
while needed:
    name = needed.pop()
    if name in seen: continue
    if 'd3dmetal' in name.lower():
        raise RuntimeError(f'Unexpected proprietary graphics dependency {name}')
    seen.add(name)
    src = source/'Frameworks'/name
    binary = src/name.removesuffix('.framework')
    text = subprocess.check_output(['/usr/bin/otool','-arch','arm64','-L',str(binary)],text=True)
    dependencies = re.findall(r'\s+(@rpath/[^\s]+)',text)
    for dep in dependencies:
        needed.append(dep.split('/')[1])
    destination = frameworks/name
    if not destination.exists(): shutil.copytree(src,destination,symlinks=True)
    manifest.append({'framework':name, 'sha256':subprocess.check_output(['/usr/bin/shasum','-a','256',str(binary)],text=True).split()[0], 'dependencies':dependencies})
qemu = out/'qemu'
qemu.mkdir(exist_ok=True)
for name in ['edk2-aarch64-secure-code.fd','edk2-arm-secure-vars.fd','edk2-licenses.txt','vgabios-ramfb.bin','efi-virtio.rom']:
    shutil.copy2(source/'Resources/qemu'/name, qemu/name)
if not (qemu/'keymaps').exists(): shutil.copytree(source/'Resources/qemu/keymaps',qemu/'keymaps')
# Bundle brew tools and their actual dylib closure. Rewrite all Homebrew paths.
bin_dir, lib_dir = out/'bin',out/'lib'
bin_dir.mkdir(exist_ok=True);lib_dir.mkdir(exist_ok=True)
render_source = (source/'XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMURenderServer.app'
                 /'Contents/MacOS/QEMURenderServer')
render_server = bin_dir/'VMRenderServer'
shutil.copy2(render_source, render_server)
render_server.chmod(render_server.stat().st_mode | 0o200)
subprocess.run(['/usr/bin/install_name_tool', '-rpath',
                '@executable_path/../../../../../../../Frameworks',
                '@executable_path/../Frameworks', str(render_server)], check=True)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(render_server)],
               check=True, stdout=subprocess.DEVNULL)
brew_prefix = Path(subprocess.check_output(['brew', '--prefix'], text=True).strip())
pending = [brew_prefix/'bin/qemu-img', brew_prefix/'bin/swtpm']
locations = {}; originals = {}
while pending:
    original = pending.pop(); real = original.resolve()
    if real in locations: continue
    target = bin_dir/original.name if original.name in ['qemu-img','swtpm'] else lib_dir/real.name
    locations[real] = target; originals[real] = original
    shutil.copy2(real,target)
    target.chmod(target.stat().st_mode | 0o200)
    output = subprocess.check_output(['/usr/bin/otool','-L',str(real)],text=True)
    for line in output.splitlines()[1:]:
        dep = line.strip().split(' (')[0]
        if dep.startswith(str(brew_prefix)+'/') and Path(dep).resolve() != real: pending.append(Path(dep))
for real,target in locations.items():
    output = subprocess.check_output(['/usr/bin/otool','-L',str(real)],text=True)
    changes = []
    for line in output.splitlines()[1:]:
        dep = line.strip().split(' (')[0]
        if dep.startswith(str(brew_prefix)+'/'):
            dest = locations.get(Path(dep).resolve())
            if dest:
                relative = '@loader_path/'+('../lib/' if target.parent==bin_dir else '')+dest.name
                changes += ['-change',dep,relative]
    if target.parent==lib_dir: changes += ['-id','@loader_path/'+target.name]
    if changes: subprocess.run(['/usr/bin/install_name_tool',*changes,str(target)],check=True)
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(target)],check=True,stdout=subprocess.DEVNULL)
(out/'manifest.json').write_text(json.dumps({'utm_release':lock['utm_release'],'utm_dmg_sha256':lock['utm_dmg_sha256'],'frameworks':manifest,
    'render_server': {'file':str(render_server.relative_to(out)), 'upstream_sha256':subprocess.check_output(['/usr/bin/shasum','-a','256',str(render_source)],text=True).split()[0]},
    'brew_tools':[{ 'source':str(k),'file':str(v.relative_to(out))} for k,v in locations.items()]},indent=2))
print(f'Prepared {len(seen)} UTM frameworks and {len(locations)} brew executables/libraries at {out}')
