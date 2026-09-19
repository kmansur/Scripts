#!/usr/bin/env bash
# Portuguese (Brazil) launcher for docker-check-updates.sh.
# Keeps one codebase while providing a PT-BR user interface.

set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export DCU_LANG=pt_BR
exec "${SCRIPT_DIR}/docker-check-updates.sh" "$@"
