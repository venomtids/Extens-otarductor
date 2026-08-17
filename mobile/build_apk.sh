#!/usr/bin/env bash
# Gera o APK de release do Otarductor.
# Requisitos: Flutter 3.19+ no PATH (com Android SDK configurado).
set -euo pipefail

cd "$(dirname "$0")"

echo "==> flutter pub get"
flutter pub get

echo "==> Verificando ambiente"
flutter doctor -v

echo "==> Build do APK (release)"
flutter build apk --release

APK="build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$APK" ]; then
  SIZE=$(du -h "$APK" | cut -f1)
  echo ""
  echo "=================================================="
  echo " APK gerado com sucesso em:"
  echo "   $APK  ($SIZE)"
  echo "=================================================="
  echo "Transfira para o Android e instale (permita fontes"
  echo "desconhecidas quando solicitado)."
else
  echo "ERRO: APK nao encontrado apos o build." >&2
  exit 1
fi
