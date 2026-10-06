#!/bin/zsh
set -euo pipefail
companion_workspace="${0:A:h:h}"
python3 - "$companion_workspace/companions/orange-kitten" "$companion_workspace/companions/orange-kitten.zip" <<'PY'
import json, sys, zipfile
from pathlib import Path
folder, output = map(Path, sys.argv[1:])
manifest = json.loads((folder / 'companion.json').read_text())
files = ['companion.json', manifest['personality'], manifest['poses'], *manifest['models'], 'README.txt']
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for name in sorted(set(files)):
        path = (folder / name).resolve()
        if not path.is_relative_to(folder.resolve()):
            raise ValueError('Package paths must stay inside the companion folder')
        archive.write(path, str(Path(folder.name) / name))
print(f'Created {output}')
PY
