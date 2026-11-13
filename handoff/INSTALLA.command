#!/bin/bash
# Regista — double-click launcher of the hand-off package built by scripts/package.sh (issue #14).
# Opens in Terminal, puts the source snapshot next to this file into ~/code/regista and runs its installer.
# Equivalent in Terminal:  bash <this file>     (extra arguments go to scripts/install.sh, e.g. --claude desktop)
#   ~/code/regista missing          → the snapshot is copied there
#   ~/code/regista is a git clone   → used as is; the installer updates it with git pull
#   ~/code/regista is an older snapshot (has a SNAPSHOT file) → replaced by this one (the build cache is kept)
#   anything else there             → nothing is touched, the launcher stops
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/regista"
DEST="$HOME/code/regista"

pause() { printf '\nEntrée pour fermer cette fenêtre · Enter para fechar esta janela… '; read -r _ || true; }
fail() { printf '\n✗ %s\n' "$*"; pause; exit 1; }

printf '\n\033[1mRegista — installation\033[0m  (%s)\n' "$(cat "$SRC/SNAPSHOT" 2>/dev/null | head -1)"
[ -f "$SRC/scripts/install.sh" ] || fail "Dossier regista/ introuvable à côté de ce fichier · Pasta regista/ não encontrada ao lado deste arquivo ($SRC). Décompresse tout le zip · Descompacte o zip inteiro."

if [ -d "$DEST/.git" ]; then
  echo "→ $DEST : clone git, mis à jour par l'installateur · clone git, atualizado pelo instalador"
elif [ -f "$DEST/SNAPSHOT" ]; then
  echo "→ $DEST : mise à jour · atualização ($(head -1 "$DEST/SNAPSHOT") → $(head -1 "$SRC/SNAPSHOT"))"
  rsync -a --delete --exclude /.build --exclude /build "$SRC/" "$DEST/" || fail "Copie impossible · Cópia impossível → $DEST"
elif [ -e "$DEST" ]; then
  fail "$DEST existe déjà mais n'est pas Regista : renomme-le, puis relance · já existe mas não é o Regista: renomeie e execute de novo."
else
  echo "→ copie dans · cópia em $DEST"
  mkdir -p "$HOME/code" && cp -R "$SRC" "$DEST" || fail "Copie impossible · Cópia impossível → $DEST"
fi
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true   # files unzipped from a download carry it

"$DEST/scripts/install.sh" ${1+"$@"}
rc=$?
if [ $rc = 0 ]; then
  printf '\n\033[32m✓ Terminé · Concluído.\033[0m Vérification à tout moment · Verificação a qualquer momento :\n    %s/scripts/doctor.sh\n' "$DEST"
else
  printf '\n\033[31m✗ L'"'"'installation s'"'"'est arrêtée · A instalação parou.\033[0m\n'
  printf '  Lis le message ci-dessus (souvent : une étape à faire puis relancer INSTALLA.command).\n'
  printf '  Leia a mensagem acima (muitas vezes: um passo a fazer e depois executar INSTALLA.command de novo).\n'
  printf '  Sinon, ouvre une issue sur github.com/arkad-consulting/regista avec une capture de cette fenêtre.\n'
  printf '  Senão, abra uma issue em github.com/arkad-consulting/regista com uma captura desta janela.\n'
fi
pause
exit $rc
