#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source_dir=$PWD
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
module_dir=$work_dir/module
example_dir=$work_dir/example
mkdir "$module_dir" "$example_dir"
cp main.tf "$module_dir/"

tofu fmt -check -recursive
tofu -chdir="$module_dir" init -backend=false -input=false
tofu -chdir="$module_dir" validate
python3 - "$source_dir" "$module_dir" "$example_dir" <<'PY'
import json
import re
import sys
from pathlib import Path

root, module, example = map(Path, sys.argv[1:])
source = re.search(r"```hcl\n(.*?)\n```", (root / "README.md").read_text(), re.S)[1]
source = source.replace(
    '"github.com/bulletxyz/bullet-hyperlane-validator?ref=v0.2.0"', json.dumps(str(module))
)
(example / "main.tf").write_text(source + "\n")
PY
tofu -chdir="$example_dir" init -backend=false -input=false
tofu -chdir="$example_dir" validate
