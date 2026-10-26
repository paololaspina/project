#!/usr/bin/env bash

# Bricht beim ersten Fehler ab
set -e

echo "Prüfe, ob index.html existiert ..."
test -f index.html

echo "Prüfe, ob es einen <title> gibt ..."
grep -q "<title>" index.html

echo "Prüfe, ob es eine <h1>-Überschrift gibt ..."
grep -q "<h1>" index.html

echo "✅ Alle Tests bestanden"
