#!/usr/bin/env bash
# kali-upgrade.sh — Atualiza o sistema e reinicia se necessário
set -Eeuo pipefail

LOG="/var/log/kali-upgrade.log"
REBOOT_DELAY=30   # segundos antes de reiniciar (0 = imediato)

# Requer root
if [[ $EUID -ne 0 ]]; then
  echo "Este script precisa ser executado como root." >&2
  exit 1
fi

mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"

# Não interativo e reinício automático de serviços
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Opções seguras para scripts (mantém configs existentes)
APT_OPTS=(-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y)

# Log em arquivo e na tela
exec > >(tee -a "$LOG") 2>&1

echo "=== $(date '+%F %T') Iniciando atualização… ==="
apt-get update
apt-get "${APT_OPTS[@]}" dist-upgrade
apt-get -y autoremove --purge
apt-get -y autoclean

# --------------------------------------------------------------------
# Patch opcional do unit file do Greenbone (gsad.service/gsd.service)
# Troca 127.0.0.1 por 0.0.0.0 somente se necessário
# --------------------------------------------------------------------
patch_unit_if_needed() {
  local unit_path="$1"

  if [[ ! -f "$unit_path" ]]; then
    echo "Unit não encontrado: $unit_path (ignorando)."
    return 0
  fi

  echo "Verificando necessidade de alterar $unit_path (127.0.0.1 -> 0.0.0.0)…"

  # Pré-visualização (equivalente ao seu 'sed -e ... arquivo')
  # Apenas para log; não altera o arquivo.
  sed 's/127\.0\.0\.1/0.0.0.0/g' "$unit_path" | head -n 20 | sed 's/^/[preview] /'

  # Gera uma versão candidata e compara
  local tmp
  tmp="$(mktemp)"
  sed 's/127\.0\.0\.1/0.0.0.0/g' "$unit_path" > "$tmp"

  if cmp -s "$unit_path" "$tmp"; then
    echo "Nenhuma alteração necessária em $unit_path."
    rm -f "$tmp"
    return 0
  fi

  local backup="${unit_path}.$(date +%F_%H%M%S).bak"
  cp -a "$unit_path" "$backup"
  install -m 0644 "$tmp" "$unit_path"
  rm -f "$tmp"
  echo "Arquivo alterado. Backup salvo em: $backup"

  systemctl daemon-reload
  if systemctl is-enabled --quiet "$(basename "$unit_path")"; then
    # Tenta reiniciar apenas se estiver habilitado/ativo
    systemctl restart "$(basename "$unit_path")" || {
      echo "Aviso: falha ao reiniciar $(basename "$unit_path"). Verifique o journal."
    }
  else
    systemctl try-restart "$(basename "$unit_path")" || true
  fi
  echo "$(basename "$unit_path") recarregado/reiniciado."
}

# Tenta primeiro gsad.service (Greenbone Security Assistant) e depois gsd.service (caso o nome varie)
for CANDIDATE in /lib/systemd/system/gsad.service /lib/systemd/system/gsd.service; do
  patch_unit_if_needed "$CANDIDATE"
done

# --------------------------------------------------------------------
# Decisão de reboot
# --------------------------------------------------------------------
needs_reboot=false

# Sinal padrão Debian/Ubuntu/Kali
if [[ -f /var/run/reboot-required || -f /var/run/reboot-required.pkgs ]]; then
  needs_reboot=true
fi

# Kernel instalado vs. em execução
if [[ -L /vmlinuz ]]; then
  running="$(uname -r || true)"
  installed="$(readlink -f /vmlinuz | sed 's|.*/vmlinuz-||' || true)"
  if [[ -n "$running" && -n "$installed" && "$running" != "$installed" ]]; then
    needs_reboot=true
  fi
fi

if $needs_reboot; then
  echo "Reinício necessário detectado. Reiniciando em ${REBOOT_DELAY}s… (log: ${LOG})"
  sleep "$REBOOT_DELAY"
  systemctl reboot
else
  echo "Atualização concluída sem necessidade de reinício."
fi