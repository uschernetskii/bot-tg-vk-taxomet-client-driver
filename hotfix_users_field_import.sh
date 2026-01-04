#!/usr/bin/env bash
set -euo pipefail
TS="$(date +%Y%m%d-%H%M%S)"

F="backend/app/users.py"
cp -a "$F" "$F.bak.$TS"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("backend/app/users.py")
s = p.read_text(encoding="utf-8", errors="ignore")

# If pydantic import exists but without Field, patch it
m = re.search(r"from pydantic import ([^\n]+)", s)
if m:
    items = [x.strip() for x in m.group(1).split(",")]
    if "BaseModel" not in items:
        items.append("BaseModel")
    if "Field" not in items:
        items.append("Field")
    new_line = "from pydantic import " + ", ".join(sorted(set(items), key=lambda x: ["BaseModel","Field"].index(x) if x in ["BaseModel","Field"] else 99))
    # keep any other items after
    s = s[:m.start()] + new_line + s[m.end():]
else:
    # Insert near top after fastapi import
    ins = "from pydantic import BaseModel, Field\n"
    fm = re.search(r"from fastapi import[^\n]*\n", s)
    if fm:
        s = s[:fm.end()] + ins + s[fm.end():]
    else:
        s = ins + s

p.write_text(s, encoding="utf-8")
print("OK: patched pydantic Field import")
PY

python3 -m py_compile backend/app/users.py

git add backend/app/users.py
git commit -m "Hotfix: import Field for users schemas" || true
git push origin main

docker compose up -d --build backend
docker compose logs -f --tail=120 backend
