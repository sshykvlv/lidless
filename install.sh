#!/bin/bash
# Собирает, ставит в /Applications и разрешает pmset без пароля (вариант A).
# Один раз попросит пароль через системное окно (для записи sudoers).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="/Applications/Lidless.app"
rm -rf "$DEST"
cp -R Lidless.app "$DEST"
echo "✅ Установлено в $DEST"

# sudoers drop-in: разрешить БЕЗ ПАРОЛЯ ровно две команды, которые шлёт приложение,
# а не любой `pmset` (тот умеет schedule/poweroff/hibernate — это был бы лишний root-доступ).
USER_NAME="$(whoami)"
TMP="$(mktemp)"
printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n' "$USER_NAME" > "$TMP"

if visudo -cf "$TMP" >/dev/null 2>&1; then
    osascript -e "do shell script \"install -m 440 -o root -g wheel '$TMP' /etc/sudoers.d/lidless\" with administrator privileges"
    rm -f "$TMP"
    echo "✅ sudoers разрешение установлено: /etc/sudoers.d/lidless"
else
    rm -f "$TMP"
    echo "❌ Ошибка синтаксиса sudoers — прервано" >&2
    exit 1
fi

open "$DEST"
echo "✅ Готово. Звезда должна появиться в строке меню (жёлтая вкл / серая выкл)."
