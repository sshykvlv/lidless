#!/bin/bash
# Подписывает Developer ID + нотаризует + staple + пакует zip для передачи.
# Требует: сертификат "Developer ID Application" в keychain и notary-профиль.
#   xcrun notarytool store-credentials keepawake-notary \
#       --apple-id YOU@APPLEID --team-id NDQ958367W --password xxxx-xxxx-xxxx-xxxx
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${1:-keepawake-notary}"
APP="Lidless.app"
OUT="$HOME/Downloads/Lidless.zip"

# 1) свежая сборка
./build.sh

# 2) найти Developer ID Application identity
IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(Developer ID Application[^"]*)".*/\1/')"
if [ -z "${IDENTITY:-}" ]; then
    echo "❌ Нет сертификата 'Developer ID Application' в keychain." >&2
    echo "   Создай: Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application" >&2
    exit 1
fi
echo "🔏 Подписываю как: $IDENTITY"

# 3) подпись с hardened runtime + timestamp (обязательно для нотаризации)
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 4) нотаризация (zip → submit → wait)
ZIP_TMP="$(mktemp -d)/Lidless.zip"
ditto -c -k --keepParent "$APP" "$ZIP_TMP"
echo "📤 Отправляю на нотаризацию (профиль: $PROFILE)…"
xcrun notarytool submit "$ZIP_TMP" --keychain-profile "$PROFILE" --wait

# 5) staple — чтобы открывалось офлайн без проверки у Apple
xcrun stapler staple "$APP"

# 6) проверка как увидит Gatekeeper у друга
echo "🔎 Проверка Gatekeeper:"
spctl -a -vvv "$APP" 2>&1 || true

# 7) финальный zip для отправки
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "✅ Готово: $OUT — этот файл можно отправлять другу."
