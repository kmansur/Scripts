#!/bin/sh
# wanguard_backup.sh - Backup do Wanguard com cfg local, e-mail e rotate de logs
# v2.3 (2025-09-15) - Religa o serviço após dump; log em /var/log; e-mail flexível (modo/limite e anexo)

set -eu
umask 027

# --- Descobre diretório real do script ---
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
CFG="${BASE_DIR}/wanguard_backup.cfg"
[ -r "$CFG" ] || { echo "ERRO: arquivo de configuração não encontrado: $CFG"; exit 2; }
# shellcheck disable=SC1090
. "$CFG"

# ===== Defaults (fallback se faltarem no cfg) =====
: "${SERVICE_NAME:=WANsupervisor}"
: "${ANDRISOFT_DIR:=/opt/andrisoft}"
: "${BACKUP_ROOT:=/opt/Backup}"
: "${RETAIN_DAYS:=14}"
: "${MIN_FREE_MB:=1024}"
: "${USE_PIGZ:=1}"
: "${LOCK_DIR:=/var/lock/wanguard_backup.lock}"

# Logs (padrão em /var/log/wanguard)
: "${LOG_DIR:=/var/log/wanguard}"
: "${LOG_RETAIN:=30}"
: "${LOG_COMPRESS_WITH_PIGZ:=1}"

# E-mail
: "${EMAIL_ENABLED:=1}"
: "${EMAIL_TO:=root@localhost}"
: "${EMAIL_FROM:=wanguard-backup@$(hostname 2>/dev/null || echo localhost)}"
: "${EMAIL_SUBJECT_PREFIX:=[Wanguard Backup]}"
: "${EMAIL_ON_SUCCESS:=1}"
: "${EMAIL_ON_FAILURE:=1}"

# Novo esquema (substitui EMAIL_LOG_LINES)
: "${EMAIL_LOG_BODY_MODE:=auto}"        # none|summary|errors|tail|full|auto
: "${EMAIL_LOG_BODY_MAX_KB:=64}"        # máximo de KB do log embutido no corpo
: "${EMAIL_ATTACH_LOG:=0}"              # 1 = anexa .log.gz
: "${EMAIL_ATTACH_ON_FAILURE_ONLY:=1}"  # 1 = só anexa em falha

HOSTNAME="$(hostname -f 2>/dev/null || hostname || echo localhost)"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST_DIR="${BACKUP_ROOT}/${STAMP}"

# Estrutura
mkdir -p "$BACKUP_ROOT" "$DEST_DIR" "$LOG_DIR"
chmod 750 "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/wanguard_backup-${STAMP}.log"

echo_ts() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

compress_with() {
  # $1: "data" ou "log" | $2: arquivo
  if [ "$1" = "log" ] && [ "$LOG_COMPRESS_WITH_PIGZ" -eq 1 ] && have_cmd pigz; then
    pigz -9 "$2"
  elif [ "$1" = "data" ] && [ "$USE_PIGZ" -eq 1 ] && have_cmd pigz; then
    pigz -9 "$2"
  else
    gzip -9 "$2"
  fi
}

sha256_gen() {
  if have_cmd sha256sum; then
    sha256sum "$@" > SHA256SUMS.txt
  elif have_cmd sha256; then
    : > SHA256SUMS.txt
    for f in "$@"; do sha256 -q "$f" | awk -v F="$f" '{print $0"  "F}' >> SHA256SUMS.txt; done
  else
    echo_ts "Aviso: sha256/sha256sum não encontrado; pulando integridade."
  fi
}

stop_service() {
  echo_ts "Parando serviço ${SERVICE_NAME}…"
  if have_cmd systemctl; then systemctl stop "$SERVICE_NAME"; else service "$SERVICE_NAME" stop; fi
}

start_service() {
  echo_ts "Iniciando serviço ${SERVICE_NAME}…"
  if have_cmd systemctl; then systemctl start "$SERVICE_NAME"; else service "$SERVICE_NAME" start; fi
}

_log_snippet_for_body() {
  # imprime trecho de log conforme modo/limite
  MODE="$1"   # none|summary|errors|tail|full|auto
  STATUS="$2" # SUCESSO|FALHA
  KB_MAX=$(( EMAIL_LOG_BODY_MAX_KB * 1024 ))

  case "$MODE" in
    auto)
      if [ "$STATUS" = "SUCESSO" ]; then MODE="summary"; else MODE="errors"; fi
    ;;
  esac

  case "$MODE" in
    none) return 0 ;;
    summary)
      awk '
        /Início do backup/ || /Destino:/ || /Espaço livre:/ || /religado/ || /Backup concluído/ {
          print
        }' "$LOG_FILE" | tail -n 50
    ;;
    errors)
      # erros/avisos mais recentes (limitado por bytes)
      if grep -Ei 'erro|error|fail|fatal|crit|warn|aviso|falha' "$LOG_FILE" >/dev/null 2>&1; then
        printf 'Erros/Avisos recentes:\n'
        grep -Ei 'erro|error|fail|fatal|crit|warn|aviso|falha' "$LOG_FILE" | tail -c "$KB_MAX"
      else
        echo "(sem ocorrências de erro/aviso no log)"
      fi
    ;;
    tail)
      printf 'Trecho final do log:\n'
      tail -c "$KB_MAX" "$LOG_FILE"
    ;;
    full)
      # corpo limitado por bytes mesmo em full
      printf 'Log (recorte até %sKB):\n' "$EMAIL_LOG_BODY_MAX_KB"
      tail -c "$KB_MAX" "$LOG_FILE"
    ;;
    *) echo "(modo de log desconhecido: $MODE)";;
  esac
}

_sendmail_like() {
  # envia conteúdo STDIN com sendmail/msmtp/mail; prefere sendmail -> msmtp -> mail
  if have_cmd sendmail; then
    /usr/sbin/sendmail -t
  elif have_cmd msmtp; then
    msmtp -t
  elif have_cmd mail; then
    # mail não aceita cabeçalhos completos via -t; fallback: extrai Subject e To
    awk '
      BEGIN{to=""; subj=""}
      /^To: /{to=$0; sub(/^To: /,"",to)}
      /^Subject: /{subj=$0; sub(/^Subject: /,"",subj)}
      /^$/{exit}
    ' | {
      read to; read subj || true
      # reconstitui corpo sem cabeçalhos
      # shellcheck disable=SC2002
      BODY="$(cat)"
      printf "%s" "$BODY" | mail -s "$subj" "$to"
    }
  else
    return 127
  fi
}

_base64_cmd() {
  if have_cmd base64; then echo base64; elif have_cmd openssl; then echo "openssl base64"; else echo ""; fi
}

send_email() {
  STATUS="$1"  # "SUCESSO" ou "FALHA"
  [ "$EMAIL_ENABLED" -eq 1 ] || return 0

  SUBJECT="${EMAIL_SUBJECT_PREFIX} ${STATUS} em ${HOSTNAME} - ${STAMP}"
  BOUNDARY="=====WGBOUNDARY_${STAMP}_$$====="
  WANT_ATTACH=0
  if [ "$EMAIL_ATTACH_LOG" -eq 1 ]; then
    if [ "$EMAIL_ATTACH_ON_FAILURE_ONLY" -eq 1 ] && [ "$STATUS" = "SUCESSO" ]; then
      WANT_ATTACH=0
    else
      WANT_ATTACH=1
    fi
  fi

  B64=$(_base64_cmd)

  if [ "$WANT_ATTACH" -eq 1 ] && [ -n "$B64" ] && (have_cmd sendmail || have_cmd msmtp); then
    # prepara anexo gzip do log
    ATTACH="/tmp/wanguard_backup-${STAMP}.log.gz"
    gzip -c "$LOG_FILE" > "$ATTACH" 2>/dev/null || ATTACH=""
  else
    ATTACH=""
  fi

  # Monta mensagem
  if [ -n "$ATTACH" ]; then
    {
      printf 'From: %s\n' "$EMAIL_FROM"
      printf 'To: %s\n' "$EMAIL_TO"
      printf 'Subject: %s\n' "$SUBJECT"
      printf 'MIME-Version: 1.0\n'
      printf 'Content-Type: multipart/mixed; boundary="%s"\n\n' "$BOUNDARY"

      printf '--%s\n' "$BOUNDARY"
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf 'Content-Transfer-Encoding: 8bit\n\n'

      echo "Status : ${STATUS}"
      echo "Host   : ${HOSTNAME}"
      echo "Quando : ${STAMP}"
      echo "Destino: ${DEST_DIR}"
      echo "Log    : ${LOG_FILE}"
      echo
      _log_snippet_for_body "$EMAIL_LOG_BODY_MODE" "$STATUS"
      echo
      printf '--%s\n' "$BOUNDARY"
      printf 'Content-Type: application/gzip; name="wanguard_backup-%s.log.gz"\n' "$STAMP"
      printf 'Content-Transfer-Encoding: base64\n'
      printf 'Content-Disposition: attachment; filename="wanguard_backup-%s.log.gz"\n\n' "$STAMP"
      $B64 "$ATTACH"
      printf '\n--%s--\n' "$BOUNDARY"
    } | _sendmail_like || echo_ts "Aviso: falha ao enviar e-mail (com anexo)."
    [ -n "$ATTACH" ] && rm -f "$ATTACH" 2>/dev/null || true
  else
    {
      printf 'From: %s\n' "$EMAIL_FROM"
      printf 'To: %s\n' "$EMAIL_TO"
      printf 'Subject: %s\n' "$SUBJECT"
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf 'Content-Transfer-Encoding: 8bit\n\n'

      echo "Status : ${STATUS}"
      echo "Host   : ${HOSTNAME}"
      echo "Quando : ${STAMP}"
      echo "Destino: ${DEST_DIR}"
      echo "Log    : ${LOG_FILE}"
      echo
      _log_snippet_for_body "$EMAIL_LOG_BODY_MODE" "$STATUS"
    } | _sendmail_like || echo_ts "Aviso: falha ao enviar e-mail."
  fi
}

die() {
  echo_ts "ERRO: $*"
  if [ "${SERVICE_STOPPED:-0}" -eq 1 ]; then start_service || true; fi
  [ "$EMAIL_ON_FAILURE" -eq 1 ] && send_email "FALHA" || true
  [ -d "$LOCK_DIR" ] && rmdir "$LOCK_DIR" 2>/dev/null || true
  exit 1
}

# ===== Lock =====
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  die "Já existe execução em andamento (lock em ${LOCK_DIR})."
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# ===== Pré-voo =====
have_cmd "${ANDRISOFT_DIR}/bin/WANmaintenance" || die "WANmaintenance não encontrado em ${ANDRISOFT_DIR}/bin/."
AVAIL_MB=$(df -m "$BACKUP_ROOT" | awk 'NR==2 {print $4}')
[ "${AVAIL_MB:-0}" -ge "$MIN_FREE_MB" ] || die "Espaço livre insuficiente em ${BACKUP_ROOT}: ${AVAIL_MB} MB (mínimo ${MIN_FREE_MB} MB)."

echo_ts "==== Início do backup do Wanguard (${STAMP}) ===="
echo_ts "Host: ${HOSTNAME}"
echo_ts "Destino: ${DEST_DIR}"
echo_ts "Espaço livre: ${AVAIL_MB} MB | Retenção de backups: ${RETAIN_DAYS} dias"

# ===== Janela de parada mínima =====
SERVICE_STOPPED=0
DOWNTIME_START=0
DOWNTIME_END=0

stop_service && { SERVICE_STOPPED=1; DOWNTIME_START=$(date +%s); }

# ---- Dump do banco (serviço parado) ----
(
  cd "$DEST_DIR"
  echo_ts "Executando: ${ANDRISOFT_DIR}/bin/WANmaintenance backup_db"
  "${ANDRISOFT_DIR}/bin/WANmaintenance" backup_db
) || die "Falha durante WANmaintenance backup_db."

# ---- RELIGA imediatamente após o dump ----
start_service || die "Falha ao iniciar serviço ${SERVICE_NAME}."
SERVICE_STOPPED=0
DOWNTIME_END=$(date +%s)
echo_ts "Serviço ${SERVICE_NAME} religado. Tempo de indisponibilidade: $((DOWNTIME_END - DOWNTIME_START))s"

# ===== Pós-processamento (serviço no ar) =====
# Compressão dos .sql
SQL_COUNT=0
for f in "$DEST_DIR"/*.sql; do
  [ -e "$f" ] || break
  SQL_COUNT=$((SQL_COUNT+1))
  echo_ts "Comprimindo: $(basename "$f")"
  compress_with "data" "$f" || die "Falha ao comprimir $f."
done
[ "$SQL_COUNT" -gt 0 ] || die "Nenhum arquivo .sql foi gerado em ${DEST_DIR}."

# Integridade (SHA256) dos .gz
(
  cd "$DEST_DIR"
  echo_ts "Gerando SHA256SUMS.txt…"
  sha256_gen *.sql.gz 2>/dev/null || true
)

# Rotaciona backups antigos
echo_ts "Rotacionando backups com mais de ${RETAIN_DAYS} dias…"
find "$BACKUP_ROOT" -maxdepth 1 -type d -name '20*' -mtime +"$RETAIN_DAYS" -print -exec rm -rf {} \; 2>/dev/null | tee -a "$LOG_FILE" || true

# E-mail de sucesso (antes de compactar o log)
[ "$EMAIL_ON_SUCCESS" -eq 1 ] && send_email "SUCESSO" || true

# Rotação/compactação de logs
echo_ts "Compactando log atual…"
compress_with "log" "$LOG_FILE" || true
# compacta eventuais .log antigos que ficaram sem compressão
find "$LOG_DIR" -maxdepth 1 -type f -name 'wanguard_backup-*.log' -print -exec gzip -9 {} \; 2>/dev/null || true

# mantém apenas os LOG_RETAIN logs mais recentes
CNT=0
# shellcheck disable=SC2012
for lf in $(ls -1t "${LOG_DIR}"/wanguard_backup-*.log.gz 2>/dev/null || true); do
  CNT=$((CNT+1))
  if [ "$CNT" -gt "$LOG_RETAIN" ]; then
    echo_ts "Removendo log antigo: $lf"
    rm -f "$lf" 2>/dev/null || true
  fi
done

echo_ts "Backup concluído com sucesso."
exit 0