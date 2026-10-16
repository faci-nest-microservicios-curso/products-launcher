#!/usr/bin/env bash
#
# git_all.sh — Corre un comando de git en cada microservicio (submódulo) y,
# al final, en el repo raíz (03-Products-Launcher).
#
# Uso:
#   ./git_all.sh add .
#   ./git_all.sh commit -am "Commit"
#   ./git_all.sh push
#
# Reglas:
#   * Los `commit` se omiten en los repos que no tengan cambios.
#   * Se ejecuta primero en los submódulos y al final en la raíz, para que la
#     raíz registre los commits nuevos de los submódulos.
#
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -eq 0 ]; then
  echo "Uso: $(basename "$0") <comando-git> [argumentos...]"
  echo "  $(basename "$0") add ."
  echo "  $(basename "$0") commit -am \"mensaje\""
  echo "  $(basename "$0") push"
  exit 1
fi

CMD="$1"
shift
GIT_ARGS=("$@")

# ¿El commit incluye -a/--all? Sirve para saber qué cambios contar (índice vs
# también archivos ya rastreados).
COMMIT_ALL=0
for arg in ${GIT_ARGS[@]+"${GIT_ARGS[@]}"}; do
  case "$arg" in
    --all) COMMIT_ALL=1 ;;
    -[a-zA-Z]*)
      [[ "$arg" == -*a* ]] && COMMIT_ALL=1
      ;;
  esac
done

# Submódulos declarados en .gitmodules, en su orden.
mapfile -t SUBMODULES < <(
  git -C "$ROOT" config -f "$ROOT/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}'
)

failures=0

has_changes_to_commit() {
  local dir="$1"
  if [ "$COMMIT_ALL" -eq 1 ]; then
    # cambios en el índice o en archivos ya rastreados
    ! git -C "$dir" diff --cached --quiet || ! git -C "$dir" diff --quiet
  else
    # sólo lo que está en el índice
    ! git -C "$dir" diff --cached --quiet
  fi
}

run_one() {
  local dir="$1" label="$2"

  printf '\n=== %s (%s) ===\n' "$label" "$dir"

  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "   (no es un repo git, se omite)"
    return 0
  fi

  if [ "$CMD" = "commit" ] && ! has_changes_to_commit "$dir"; then
    echo "   (sin cambios, se omite el commit)"
    return 0
  fi

  if ! git -C "$dir" "$CMD" ${GIT_ARGS[@]+"${GIT_ARGS[@]}"}; then
    echo "   >>> ERROR ejecutando 'git $CMD' en $label"
    failures=$((failures + 1))
  fi
}

for sub in ${SUBMODULES[@]+"${SUBMODULES[@]}"}; do
  [ -n "$sub" ] || continue
  run_one "$ROOT/$sub" "$sub"
done

run_one "$ROOT" "$(basename "$ROOT")"

printf '\n────────────────────────────────────────\n'
if [ "$failures" -eq 0 ]; then
  echo "✔ 'git $CMD' ejecutado en todos los repos."
else
  echo "✘ Terminó con $failures error(es). Revisa la salida de arriba."
  exit 1
fi
