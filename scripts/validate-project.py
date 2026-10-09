#!/usr/bin/env python3
"""Check Xcode source membership against the physical Swift package layout."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(root/'FrankLuma.xcodeproj/project.pbxproj')]))
objects = project['objects']
paths = {}
def walk(identifier, parent):
    obj = objects[identifier]
    base = parent/obj.get('path', '')
    if obj['isa'] == 'PBXGroup':
        for child in obj['children']:
            walk(child, base)
    elif obj['isa'] == 'PBXFileReference' and obj.get('sourceTree') == '<group>':
        paths[identifier] = base
walk(objects[project['rootObject']]['mainGroup'], root)
for target in (o for o in objects.values() if o['isa'] == 'PBXNativeTarget'):
    folder = root/('Tests/FrankLumaTests' if target['name'] == 'FrankLumaTests' else 'Sources/FrankLuma')
    actual = sorted(paths[objects[b]['fileRef']] for phase in target['buildPhases'] if objects[phase]['isa'] == 'PBXSourcesBuildPhase' for b in objects[phase]['files'])
    expected = sorted(folder.rglob('*.swift'))
    if actual != expected:
        raise SystemExit(f"{target['name']}: source membership differs: missing={set(expected)-set(actual)}, extra={set(actual)-set(expected)}, duplicates={len(actual)-len(set(actual))}")
    print(f"{target['name']}: {len(actual)} source files, membership matches disk")
for path in paths.values():
    if not path.exists():
        raise SystemExit(f'Missing group-relative file: {path}')
print('All group-relative file references exist')
