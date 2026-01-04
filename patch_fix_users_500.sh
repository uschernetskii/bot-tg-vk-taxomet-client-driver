#!/usr/bin/env bash
set -euo pipefail

cd /opt/taxi

FILE="backend/app/users.py"
if [[ ! -f "$FILE" ]]; then
  echo "Не найден $FILE"
  exit 1
fi

cp -a "$FILE" "${FILE}.bak.$(date +%Y%m%d-%H%M%S)"

# Меняем только SELECT-часть: FROM user -> FROM users
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("backend/app/users.py")
t = p.read_text(encoding="utf-8", errors="replace")

# аккуратно: меняем ' FROM user ' / ' FROM user\n' / ' FROM user\t'
t2 = re.sub(r'(\bFROM\s+)user(\b)', r'\1users\2', t, flags=re.IGNORECASE)

if t2 == t:
    print("WARN: не нашёл FROM user (возможно уже исправлено).")
else:
    p.write_text(t2, encoding="utf-8")
    print("OK: заменил FROM user -> FROM users")
PY

echo "[+] rebuild backend + bot_tg"
docker compose up -d --build backend bot_tg

echo "[+] healthcheck"
curl -s http://127.0.0.1:8000/api/health || true

echo "Готово. Проверь логи:"
echo "  docker compose logs --tail=200 backend"
echo "  docker compose logs --tail=200 bot_tg"
