#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
SOURCE="${ROOT_DIR}/docs/architecture.drawio"
OUTPUT="${ROOT_DIR}/docs/architecture.svg"

find_drawio() {
  local candidate
  for candidate in drawio draw.io diagramsnet diagrams.net; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      command -v "${candidate}"
      return 0
    fi
  done

  local mac_app="/Applications/draw.io.app/Contents/MacOS/draw.io"
  if [[ -x "${mac_app}" ]]; then
    printf '%s\n' "${mac_app}"
    return 0
  fi

  return 1
}

if [[ ! -f "${SOURCE}" ]]; then
  printf 'Missing diagram source: %s\n' "${SOURCE}" >&2
  exit 1
fi

if ! DRAWIO_BIN="$(find_drawio)"; then
  cat >&2 <<'EOF'
No draw.io/diagrams.net CLI was found.

Install the diagrams.net desktop/CLI, then rerun:
  bash scripts/export-diagrams.sh

The editable source is docs/architecture.drawio and the checked-in preview is docs/architecture.svg.
EOF
  exit 127
fi

if "${DRAWIO_BIN}" --export --format svg --output "${OUTPUT}" "${SOURCE}"; then
  printf 'Exported %s\n' "${OUTPUT#${ROOT_DIR}/}"
  exit 0
fi

"${DRAWIO_BIN}" -x -f svg -o "${OUTPUT}" "${SOURCE}"
printf 'Exported %s\n' "${OUTPUT#${ROOT_DIR}/}"
