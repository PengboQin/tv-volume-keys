#!/usr/bin/env python3
"""Build an isolated, local-only preview. Never installs or replaces an app."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / '.build'
DIST = ROOT / 'dist'
APP = BUILD / 'TV Volume Keys Preview.app'
VERSION = '0.1.0-preview.1'

def run(args):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True, cwd=ROOT).stdout.strip()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if args.dry_run:
        print(json.dumps({'generated_app': str(APP), 'generated_output': str(DIST),
                          'may_replace_fixed_generated_paths': [str(APP), str(BUILD / 'dmg-stage')],
                          'installs_app': False, 'touches_user_data': False}, indent=2))
        return
    executable = str(APP / 'Contents/MacOS/TVVolumeKeys')
    running = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    if any(p.strip() == executable for p in running):
        raise SystemExit('Quit this preview before replacing its generated app bundle.')
    BUILD.mkdir(exist_ok=True); DIST.mkdir(exist_ok=True)
    if APP.exists():
        # Only this fixed generated preview; no user application or data paths.
        shutil.rmtree(APP)
    macos = APP / 'Contents/MacOS'; resources = APP / 'Contents/Resources'
    macos.mkdir(parents=True); resources.mkdir()
    info = {'CFBundleIdentifier': 'com.linghe.tv-volume-keys.preview',
            'CFBundleName': 'TV Volume Keys Preview', 'CFBundleDisplayName': 'TV Volume Keys',
            'CFBundleExecutable': 'TVVolumeKeys', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
            'CFBundleIconFile': 'AppIcon', 'LSMinimumSystemVersion': '14.0',
            'LSArchitecturePriority': ['arm64'], 'LSUIElement': True,
            'LSMultipleInstancesProhibited': True,
            'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'zh-Hans'],
            'NSHumanReadableCopyright': 'Copyright 2026 TV Volume Keys contributors. MIT.'}
    (APP / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    for lang, title in [('en', 'TV Volume Keys'), ('zh-Hans', '电视音量键')]:
        p = resources / (lang + '.lproj'); p.mkdir()
        (p / 'InfoPlist.strings').write_text('"CFBundleDisplayName" = "' + title + '";\n')
    iconset = BUILD / 'AppIcon.iconset'; iconset.mkdir(exist_ok=True)
    run(['xcrun', 'swift', ROOT / 'scripts/make-icon.swift', iconset])
    # iconutil needs @2x names for the large representations.
    for size in [16, 128, 256, 512]:
        shutil.copyfile(iconset / f'icon_{size*2}x{size*2}.png', iconset / f'icon_{size}x{size}@2x.png')
    (iconset / 'icon_1024x1024.png').unlink()
    run(['iconutil', '-c', 'icns', iconset, '-o', resources / 'AppIcon.icns'])
    (resources / 'LICENSES.txt').write_text((ROOT / 'LICENSE').read_text() + '\n\n' + (ROOT / 'THIRD_PARTY_NOTICES.md').read_text())
    run(['xcrun', 'swiftc', '-swift-version', '5', '-target', 'arm64-apple-macos14.0',
         '-O', '-warnings-as-errors', '-file-prefix-map', str(ROOT) + '=.',
         '-framework', 'AppKit', '-framework', 'ApplicationServices', '-framework', 'CoreAudio',
         '-framework', 'IOKit', '-framework', 'ServiceManagement',
         ROOT / 'Sources/main.swift', '-o', macos / 'TVVolumeKeys'])
    run(['codesign', '--force', '--sign', '-', '--identifier', info['CFBundleIdentifier'], APP])
    run(['codesign', '--verify', '--strict', APP])
    checks = run([macos / 'TVVolumeKeys', '--self-test'])
    diagnostics = json.loads(run([macos / 'TVVolumeKeys', '--diagnose']))
    git_root = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=ROOT, capture_output=True, text=True)
    source_commit = run(['git', 'rev-parse', 'HEAD']) if git_root.returncode == 0 and Path(git_root.stdout.strip()).resolve() == ROOT else 'source-archive'
    source_files = [ROOT / p for p in ['Sources/main.swift', 'scripts/build.py', 'scripts/make-icon.swift']]
    source_fingerprint = hashlib.sha256('\n'.join(str(p.relative_to(ROOT)) + ':' + hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files).encode()).hexdigest()
    result = {'source_commit': source_commit, 'source_fingerprint': source_fingerprint, 'version': VERSION, 'app': str(APP), 'signing': 'local ad-hoc',
              'notarized': False, 'installed': False, 'published': False,
              'minimum_os_build_target': '14.0', 'architecture': 'arm64',
              'new_app_launch_permission_verified': False,
              'self_test': checks, 'read_only_diagnostics': diagnostics}
    if args.package:
        stage = BUILD / 'dmg-stage'
        if stage.exists(): shutil.rmtree(stage)
        stage.mkdir(); shutil.copytree(APP, stage / APP.name)
        (stage / 'Applications').symlink_to('/Applications')
        (stage / 'READ ME FIRST.txt').write_text('TV Volume Keys - local preview\n\nFree and open source. Apple silicon, macOS 14+, one external HDMI display.\nHardware compatibility varies. This preview uses local ad-hoc signing and is NOT notarized.\nIt is not a public release. Do not disable Gatekeeper or other system security settings.\n')
        dmg = DIST / f'TV-Volume-Keys-{VERSION}-arm64.dmg'
        run(['hdiutil', 'create', '-volname', 'TV Volume Keys Preview', '-srcfolder', stage,
             '-format', 'UDZO', '-ov', dmg])
        run(['hdiutil', 'verify', dmg])
        shutil.rmtree(stage)
        sourcezip = DIST / f'TV-Volume-Keys-{VERSION}-source.zip'
        include = ['Sources', 'scripts', 'Resources', 'docs/兼容与分发.md', 'README.md', 'README.zh-CN.md',
                   'LICENSE', 'THIRD_PARTY_NOTICES.md', 'CHANGELOG.md', '.gitignore']
        with zipfile.ZipFile(sourcezip, 'w', zipfile.ZIP_DEFLATED) as z:
            for item in include:
                p = ROOT / item
                for f in sorted(p.rglob('*')) if p.is_dir() else [p]:
                    if f.is_file() and '__pycache__' not in f.parts:
                        z.write(f, 'tv-volume-keys/' + str(f.relative_to(ROOT)))
        result['archives'] = {p.name: {'bytes': p.stat().st_size,
            'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in [dmg, sourcezip]}
        (DIST / 'SHA256SUMS').write_text(''.join(v['sha256'] + '  ' + k + '\n' for k, v in result['archives'].items()))
    (DIST / 'validation-local.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as exc:
        print(exc.stdout or '', file=sys.stderr)
        print(exc.stderr or str(exc), file=sys.stderr)
        raise SystemExit(exc.returncode)
