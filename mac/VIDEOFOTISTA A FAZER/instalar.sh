#!/bin/bash
# Videofotista A Fazer: monta o app e instala em /Applications
set -e
cd "$(dirname "$0")"

NOME="Videofotista A Fazer"
APP="build/$NOME.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Falta o swiftc. Rode:  xcode-select --install   e depois rode este script de novo."
  exit 1
fi

echo "› Montando o app..."
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/AFazer" fonte/main.swift \
  -framework Cocoa -framework WebKit

cp fonte/Info.plist "$APP/Contents/"
cp fonte/index.html fonte/qrcode.min.js fonte/firebase.min.js fonte/icone.png "$APP/Contents/Resources/"

echo "› Criando o ícone..."
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s fonte/icone.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) fonte/icone.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true

echo "› Instalando em Aplicativos..."
pkill -x AFazer 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/$NOME.app"
cp -R "$APP" /Applications/

open "/Applications/$NOME.app"
echo "✓ Pronto. O ícone aparece na barra de menu, lá em cima à direita."
