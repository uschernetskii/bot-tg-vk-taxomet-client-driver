#!/usr/bin/env bash
set -euo pipefail

cd /opt/taxi

FILE="bot_tg/app/bot.py"
if [[ ! -f "$FILE" ]]; then
  echo "Не найден $FILE"
  exit 1
fi

cp -a "$FILE" "${FILE}.bak.$(date +%Y%m%d-%H%M%S)"

python3 - <<'PY'
import pathlib, re
p = pathlib.Path("bot_tg/app/bot.py")
t = p.read_text(encoding="utf-8", errors="replace")

# Ищем блок, который удаляет прошлое UI сообщение:
#   try:
#       if ...: await bot.delete_message(...)
#   except: pass
# Мы его "выключим", заменив на комментарий.
pattern = r"""
(?P<indent>^[ \t]*)try:\n
(?P=indent)[ \t]+if[^\n]*\n
(?P=indent)[ \t]+await bot\.delete_message\([^\n]*\)\n
(?P=indent)except Exception:\n
(?P=indent)[ \t]+pass
"""
# более простой и надёжный: закомментировать конкретные строки delete_message
t2 = re.sub(r'(^[ \t]*await bot\.delete_message\(.+\)\s*$)', r'# \1  # disabled: keep reply keyboard', t, flags=re.M)

if t2 == t:
    print("WARN: не нашёл await bot.delete_message(...) — возможно уже отключено.")
else:
    p.write_text(t2, encoding="utf-8")
    print("OK: отключил delete_message (клавиатура не будет пропадать)")
PY

echo "[+] rebuild bot_tg"
docker compose up -d --build bot_tg

echo "Готово. Логи:"
echo "  docker compose logs -f --tail=200 bot_tg"
