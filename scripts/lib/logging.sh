#!/bin/bash
# Biblioteca de logging para todos os scripts SolidaryTech
# Uso: source "$(dirname "$0")/lib/logging.sh"
# Cria automaticamente um arquivo de log em logs/ com timestamp

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"
LOGS_DIR="${PROJECT_ROOT}/logs"

mkdir -p "${LOGS_DIR}"

SCRIPT_NAME="$(basename "${BASH_SOURCE[1]}" .sh)"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
LOG_FILE="${LOGS_DIR}/${SCRIPT_NAME}_${TIMESTAMP}.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "════════════════════════════════════════════════════════"
echo "  Script: ${SCRIPT_NAME}.sh"
echo "  Inicio: $(date +'%Y-%m-%d %H:%M:%S %Z')"
echo "  Log:    ${LOG_FILE}"
echo "  User:   $(whoami)"
echo "  PWD:    $(pwd)"
echo "════════════════════════════════════════════════════════"
echo ""

_log_cleanup() {
    local exit_code=$?
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  Fim: $(date +'%Y-%m-%d %H:%M:%S %Z')"
    if [ $exit_code -eq 0 ]; then
        echo "  Status: SUCESSO (exit code 0)"
    else
        echo "  Status: ERRO (exit code ${exit_code})"
    fi
    echo "  Log salvo em: ${LOG_FILE}"
    echo "════════════════════════════════════════════════════════"
}

trap _log_cleanup EXIT
