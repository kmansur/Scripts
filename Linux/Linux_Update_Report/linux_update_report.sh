#!/usr/bin/env bash
# ==============================================================================
# Nome.......: linux_update_report.sh
# Versao.....: 1.5
# Autor......: Karim Mansur / Net Tech
# Data.......: 2026-06-25
#
# Objetivo...: Gerar relatorio de atualizacao Linux com:
#
#              Hostname
#              IP
#              Distro
#              Vs Atual
#              Kernel Atual
#              Vs Atualizada
#              Kernel Atualizado
#              Data Atualizacao
#
# Suporte:
#   - Debian / Ubuntu / Kali: APT
#   - Oracle Linux: DNF/YUM, com suporte a UEK e RHCK
#   - RHEL / Rocky / AlmaLinux / CentOS / Fedora: DNF/YUM
#   - SUSE / openSUSE: Zypper
#   - Arch / Manjaro: Pacman
#   - Alpine: APK
#
# Comportamento padrao:
#   - Atualiza o cache dos repositorios antes de verificar.
#
# Exemplos:
#   chmod +x linux_update_report.sh
#   sudo ./linux_update_report.sh
#   sudo ./linux_update_report.sh --csv
#   ./linux_update_report.sh --no-refresh
# ==============================================================================

set -u
export LC_ALL=C

SCRIPT_VERSION="1.5"

OUTPUT_FORMAT="tsv"
REFRESH_CACHE=1
NO_UPDATE_TEXT="Sem atualização"
PKG_MANAGER="unknown"

APT_UPGRADABLE=""
RPM_UPGRADABLE=""
ZYPPER_UPGRADABLE=""
PACMAN_UPGRADABLE=""
APK_UPGRADABLE=""

# ==============================================================================
# Ajuda
# ==============================================================================

usage() {
  cat <<USAGE
Uso:
  linux_update_report.sh [opcoes]

Opcoes:
  --no-refresh    Nao atualiza o cache dos repositorios antes da consulta.
  --csv           Saida CSV usando ponto e virgula.
  --version       Mostra a versao da script.
  -h, --help      Mostra esta ajuda.

Saida padrao:
  TSV, ideal para colar em planilha.

Exemplos:
  sudo ./linux_update_report.sh
  sudo ./linux_update_report.sh --csv
  ./linux_update_report.sh --no-refresh
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --no-refresh)
      REFRESH_CACHE=0
      ;;
    --csv)
      OUTPUT_FORMAT="csv"
      ;;
    --version)
      echo "$SCRIPT_VERSION"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Parametro desconhecido: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# ==============================================================================
# Funcoes basicas
# ==============================================================================

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_as_root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  elif have_cmd sudo; then
    sudo "$@"
  else
    echo "Aviso: comando precisa de root/sudo e nao foi executado: $*" >&2
    return 1
  fi
}

trim() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

load_os_release() {
  OS_ID="unknown"
  OS_NAME="Linux"
  OS_VERSION_ID="-"
  OS_PRETTY_NAME="Linux"

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${NAME:-Linux}"
    OS_VERSION_ID="${VERSION_ID:-'-'}"
    OS_PRETTY_NAME="${PRETTY_NAME:-$OS_NAME}"
  fi
}

detect_pkg_manager() {
  if have_cmd apt-get && have_cmd apt && have_cmd dpkg-query; then
    PKG_MANAGER="apt"
  elif have_cmd dnf && have_cmd rpm; then
    PKG_MANAGER="dnf"
  elif have_cmd yum && have_cmd rpm; then
    PKG_MANAGER="yum"
  elif have_cmd zypper && have_cmd rpm; then
    PKG_MANAGER="zypper"
  elif have_cmd pacman; then
    PKG_MANAGER="pacman"
  elif have_cmd apk; then
    PKG_MANAGER="apk"
  elif have_cmd rpm; then
    PKG_MANAGER="rpm"
  else
    PKG_MANAGER="unknown"
  fi
}

refresh_package_cache() {
  if [ "$REFRESH_CACHE" -ne 1 ]; then
    return 0
  fi

  case "$PKG_MANAGER" in
    apt)
      echo "Atualizando cache APT..." >&2
      run_as_root apt-get update -qq >/dev/null
      ;;

    dnf)
      echo "Atualizando cache DNF..." >&2
      run_as_root dnf -q makecache --refresh >/dev/null
      ;;

    yum)
      echo "Atualizando cache YUM..." >&2
      run_as_root yum -q makecache >/dev/null
      ;;

    zypper)
      echo "Atualizando cache Zypper..." >&2
      run_as_root zypper --non-interactive refresh >/dev/null
      ;;

    pacman)
      echo "Atualizando cache Pacman..." >&2
      run_as_root pacman -Sy --noconfirm >/dev/null
      ;;

    apk)
      echo "Atualizando cache APK..." >&2
      run_as_root apk update >/dev/null
      ;;

    *)
      echo "Aviso: gerenciador de pacotes nao suportado para refresh." >&2
      ;;
  esac
}

get_hostname() {
  local h

  h="$(hostname -f 2>/dev/null || true)"

  if [ -z "$h" ]; then
    h="$(hostname 2>/dev/null || echo '-')"
  fi

  printf '%s\n' "$h"
}

get_primary_ip() {
  local ip

  if have_cmd ip; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"

    if [ -n "$ip" ]; then
      printf '%s\n' "$ip"
      return 0
    fi

    ip="$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"

    if [ -n "$ip" ]; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi

  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  if [ -n "$ip" ]; then
    printf '%s\n' "$ip"
    return 0
  fi

  printf '%s\n' "-"
}

get_distro_name() {
  load_os_release

  case "$OS_ID" in
    debian)
      printf '%s\n' "Debian"
      ;;
    ubuntu)
      printf '%s\n' "Ubuntu"
      ;;
    kali)
      printf '%s\n' "Kali Linux"
      ;;
    rhel)
      printf '%s\n' "Red Hat Enterprise Linux"
      ;;
    rocky)
      printf '%s\n' "Rocky Linux"
      ;;
    almalinux)
      printf '%s\n' "AlmaLinux"
      ;;
    centos)
      printf '%s\n' "CentOS"
      ;;
    ol|oracle)
      printf '%s\n' "Oracle Linux"
      ;;
    fedora)
      printf '%s\n' "Fedora"
      ;;
    opensuse*|sles|sled)
      printf '%s\n' "$OS_NAME"
      ;;
    arch)
      printf '%s\n' "Arch Linux"
      ;;
    manjaro)
      printf '%s\n' "Manjaro Linux"
      ;;
    alpine)
      printf '%s\n' "Alpine Linux"
      ;;
    *)
      printf '%s\n' "$OS_NAME"
      ;;
  esac
}

oracle_current_release_from_file() {
  if [ -r /etc/oracle-release ]; then
    sed -nE 's/.*release ([0-9]+(\.[0-9]+)?).*/\1/p' /etc/oracle-release | head -n 1
    return 0
  fi

  return 1
}

get_current_distro_version() {
  load_os_release

  if [ "$OS_ID" = "debian" ] && [ -r /etc/debian_version ]; then
    cat /etc/debian_version
    return 0
  fi

  if [ "$OS_ID" = "ol" ] || [ "$OS_ID" = "oracle" ]; then
    oracle_current_release_from_file && return 0
  fi

  if [ "$OS_VERSION_ID" != "-" ] && [ -n "$OS_VERSION_ID" ]; then
    printf '%s\n' "$OS_VERSION_ID"
  else
    printf '%s\n' "$OS_PRETTY_NAME"
  fi
}

current_date_br() {
  date '+%d/%m/%Y'
}

# ==============================================================================
# APT - Debian / Ubuntu / Kali
# ==============================================================================

load_apt_upgradable() {
  APT_UPGRADABLE="$(apt list --upgradable 2>/dev/null | sed '1d' || true)"
}

apt_upgradable_line() {
  local pkg="$1"

  printf '%s\n' "$APT_UPGRADABLE" | awk -F/ -v p="$pkg" '$1 == p {print; exit}'
}

apt_upgradable_candidate() {
  local pkg="$1"
  local line

  line="$(apt_upgradable_line "$pkg")"

  if [ -z "$line" ]; then
    return 1
  fi

  printf '%s\n' "$line" | awk '{print $2}'
}

apt_upgradable_installed() {
  local pkg="$1"
  local line

  line="$(apt_upgradable_line "$pkg")"

  if [ -z "$line" ]; then
    return 1
  fi

  printf '%s\n' "$line" | sed -n 's/.*\[upgradable from: \([^]]*\)\].*/\1/p'
}

debian_version_from_base_files() {
  local base_files_version="$1"

  # Exemplo Debian:
  #   12.4+deb12u13 -> 12.13
  #   12.4+deb12u14 -> 12.14
  if [[ "$base_files_version" =~ \+deb([0-9]+)u([0-9]+) ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  printf '%s\n' "$base_files_version"
}

get_updated_distro_version_apt() {
  local current_version="$1"
  local candidate target_version installed

  load_os_release

  candidate="$(apt_upgradable_candidate "base-files" || true)"
  installed="$(apt_upgradable_installed "base-files" || true)"

  if [ -z "$candidate" ]; then
    printf '%s\n' "$NO_UPDATE_TEXT"
    return 0
  fi

  if [ "$OS_ID" = "debian" ]; then
    target_version="$(debian_version_from_base_files "$candidate")"

    if [ "$target_version" = "$current_version" ]; then
      printf '%s\n' "$NO_UPDATE_TEXT"
    else
      printf '%s\n' "$target_version"
    fi

    return 0
  fi

  if [ "$OS_ID" = "kali" ]; then
    if [ -n "$installed" ]; then
      printf 'base-files %s -> %s\n' "$installed" "$candidate"
    else
      printf 'base-files -> %s\n' "$candidate"
    fi
    return 0
  fi

  printf '%s\n' "$candidate"
}

get_current_kernel_package_apt() {
  local kernel pkg by_file

  kernel="$(uname -r 2>/dev/null || echo '-')"
  pkg="linux-image-$kernel"

  if dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx "installed"; then
    printf '%s\n' "$pkg"
    return 0
  fi

  by_file="$(dpkg -S "/boot/vmlinuz-$kernel" 2>/dev/null | awk -F: 'NR==1 {print $1}')"

  if [ -n "$by_file" ]; then
    printf '%s\n' "$by_file"
    return 0
  fi

  printf '%s\n' "$pkg"
}

get_latest_installed_kernel_package_apt() {
  dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 'linux-image-*' 2>/dev/null \
    | awk '
        $2 == "installed" &&
        $1 ~ /^linux-image-[0-9]/ &&
        $1 !~ /-dbg$/ {
          print $1
        }
      ' \
    | sort -V \
    | tail -n 1
}

kernel_meta_candidates_apt() {
  local arch

  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

  cat <<EOF
linux-image-$arch
linux-image-cloud-$arch
linux-image-rt-$arch
linux-generic
linux-image-generic
linux-virtual
linux-image-virtual
linux-generic-hwe-22.04
linux-generic-hwe-24.04
linux-lowlatency
linux-aws
linux-azure
linux-gcp
linux-oracle
EOF
}

resolve_kernel_package_from_meta_version_apt() {
  local meta="$1"
  local version="$2"
  local dep

  dep="$(
    apt-cache show "${meta}=${version}" 2>/dev/null \
      | awk -F': ' '/^Depends:/ {print $2; exit}' \
      | tr ',' '\n' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
      | sed 's/[[:space:]].*$//' \
      | grep -E '^linux-image-[0-9]' \
      | head -n 1
  )"

  if [ -n "$dep" ]; then
    printf '%s\n' "$dep"
    return 0
  fi

  dep="$(
    apt-cache depends "$meta" 2>/dev/null \
      | awk '/Depends:/ {print $2}' \
      | sed 's/[<>]//g' \
      | grep -E '^linux-image-[0-9]' \
      | head -n 1
  )"

  if [ -n "$dep" ]; then
    printf '%s\n' "$dep"
    return 0
  fi

  return 1
}

get_kernel_update_from_meta_package_apt() {
  local meta candidate installed dep

  while read -r meta; do
    [ -z "$meta" ] && continue

    candidate="$(apt_upgradable_candidate "$meta" || true)"

    if [ -z "$candidate" ]; then
      continue
    fi

    installed="$(apt_upgradable_installed "$meta" || true)"
    dep="$(resolve_kernel_package_from_meta_version_apt "$meta" "$candidate" || true)"

    if [ -n "$dep" ]; then
      printf '%s\n' "$dep"
      return 0
    fi

    if [ -n "$installed" ]; then
      printf '%s %s -> %s\n' "$meta" "$installed" "$candidate"
    else
      printf '%s -> %s\n' "$meta" "$candidate"
    fi

    return 0
  done < <(kernel_meta_candidates_apt)

  return 1
}

get_kernel_update_from_direct_linux_image_apt() {
  local pkg

  pkg="$(
    printf '%s\n' "$APT_UPGRADABLE" \
      | awk -F/ '$1 ~ /^linux-image-[0-9]/ {print $1}' \
      | grep -v -- '-dbg$' \
      | sort -V \
      | tail -n 1
  )"

  if [ -n "$pkg" ]; then
    printf '%s\n' "$pkg"
    return 0
  fi

  return 1
}

get_updated_kernel_apt() {
  local current_pkg="$1"
  local latest_installed kernel_from_meta kernel_direct

  # Caso o kernel novo ja esteja instalado, mas ainda nao esteja em uso.
  latest_installed="$(get_latest_installed_kernel_package_apt || true)"

  if [ -n "$latest_installed" ] && [ "$latest_installed" != "$current_pkg" ]; then
    printf '%s\n' "$latest_installed"
    return 0
  fi

  # Caso o meta-pacote aponte para um kernel novo.
  kernel_from_meta="$(get_kernel_update_from_meta_package_apt || true)"

  if [ -n "$kernel_from_meta" ] && [ "$kernel_from_meta" != "$current_pkg" ]; then
    printf '%s\n' "$kernel_from_meta"
    return 0
  fi

  # Fallback para linux-image-* diretamente atualizavel.
  kernel_direct="$(get_kernel_update_from_direct_linux_image_apt || true)"

  if [ -n "$kernel_direct" ] && [ "$kernel_direct" != "$current_pkg" ]; then
    printf '%s\n' "$kernel_direct"
    return 0
  fi

  printf '%s\n' "$NO_UPDATE_TEXT"
}

# ==============================================================================
# RPM - DNF / YUM
# Inclui Oracle Linux com UEK e RHCK
# ==============================================================================

load_rpm_upgradable() {
  RPM_UPGRADABLE=""

  case "$PKG_MANAGER" in
    dnf)
      # dnf check-update retorna exit code 100 quando existem atualizacoes.
      RPM_UPGRADABLE="$(dnf -q check-update 2>/dev/null || true)"
      ;;
    yum)
      # yum check-update tambem pode retornar exit code 100.
      RPM_UPGRADABLE="$(yum -q check-update 2>/dev/null || true)"
      ;;
  esac
}

rpm_strip_arch_from_name() {
  printf '%s\n' "$1" \
    | sed -E 's/\.(x86_64|aarch64|noarch|i386|i586|i686|armv7hl|ppc64le|s390x)$//'
}

rpm_get_arch_from_name() {
  printf '%s\n' "$1" \
    | sed -nE 's/^.*\.(x86_64|aarch64|noarch|i386|i586|i686|armv7hl|ppc64le|s390x)$/\1/p'
}

rpm_upgradable_line() {
  local pkg="$1"

  printf '%s\n' "$RPM_UPGRADABLE" \
    | awk -v p="$pkg" '
        NF >= 3 && $1 !~ /^Obsoleting/ {
          n=$1
          sub(/\.(x86_64|aarch64|noarch|i386|i586|i686|armv7hl|ppc64le|s390x)$/, "", n)
          if (n == p) {
            print
            exit
          }
        }
      '
}

rpm_upgradable_candidate_version() {
  local line

  line="$(rpm_upgradable_line "$1")"

  if [ -z "$line" ]; then
    return 1
  fi

  printf '%s\n' "$line" | awk '{print $2}'
}

rpm_upgradable_installed_version() {
  local pkg="$1"

  rpm -q --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' "$pkg" 2>/dev/null \
    | sed -E 's/^\(none\)://; s/^0://' \
    | head -n 1
}

rpm_upgradable_candidate_package_string() {
  local pkg="$1"
  local line name_arch name arch version clean_version

  line="$(rpm_upgradable_line "$pkg")"

  if [ -z "$line" ]; then
    return 1
  fi

  name_arch="$(printf '%s\n' "$line" | awk '{print $1}')"
  version="$(printf '%s\n' "$line" | awk '{print $2}')"

  name="$(rpm_strip_arch_from_name "$name_arch")"
  arch="$(rpm_get_arch_from_name "$name_arch")"
  clean_version="$(printf '%s\n' "$version" | sed -E 's/^[0-9]+://')"

  if [ -z "$arch" ]; then
    arch="$(rpm --eval '%{_arch}' 2>/dev/null || echo unknown)"
  fi

  printf '%s-%s.%s\n' "$name" "$clean_version" "$arch"
}

oracle_linux_major_version() {
  load_os_release

  if [ -n "${OS_VERSION_ID:-}" ] && [ "$OS_VERSION_ID" != "-" ]; then
    printf '%s\n' "$OS_VERSION_ID" | awk -F. '{print $1}'
    return 0
  fi

  if [ -r /etc/oracle-release ]; then
    sed -nE 's/.*release ([0-9]+).*/\1/p' /etc/oracle-release | head -n 1
    return 0
  fi

  printf '%s\n' ""
}

rpm_system_release_packages() {
  local provider major

  load_os_release
  major="$(oracle_linux_major_version)"

  provider="$(rpm -q --whatprovides system-release --qf '%{NAME}\n' 2>/dev/null | head -n 1 || true)"

  {
    [ -n "$provider" ] && printf '%s\n' "$provider"

    # Oracle Linux
    [ -n "$major" ] && printf '%s\n' "oraclelinux-release-el${major}"
    printf '%s\n' "oraclelinux-release"
    printf '%s\n' "oraclelinux-release-el7"
    printf '%s\n' "oraclelinux-release-el8"
    printf '%s\n' "oraclelinux-release-el9"
    printf '%s\n' "oraclelinux-release-el10"

    # RHEL-like
    printf '%s\n' "redhat-release"
    printf '%s\n' "rocky-release"
    printf '%s\n' "almalinux-release"
    printf '%s\n' "centos-release"
    printf '%s\n' "centos-linux-release"
    printf '%s\n' "centos-stream-release"
    printf '%s\n' "fedora-release"
  } | awk 'NF && !seen[$0]++'
}

normalize_rpm_release_version() {
  local candidate="$1"

  candidate="$(printf '%s\n' "$candidate" | sed -E 's/^[0-9]+://')"

  if [[ "$candidate" =~ ^([0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$candidate" =~ el([0-9]+)_([0-9]+) ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  if [[ "$candidate" =~ el([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$candidate" =~ ^([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  printf '%s\n' "$candidate"
}

get_updated_distro_version_rpm() {
  local current_version="$1"
  local current_oracle_version pkg candidate installed target

  load_os_release

  if [ "$OS_ID" = "ol" ] || [ "$OS_ID" = "oracle" ]; then
    current_oracle_version="$(oracle_current_release_from_file || true)"

    if [ -n "$current_oracle_version" ]; then
      current_version="$current_oracle_version"
    fi
  fi

  while read -r pkg; do
    [ -z "$pkg" ] && continue

    candidate="$(rpm_upgradable_candidate_version "$pkg" || true)"

    if [ -z "$candidate" ]; then
      continue
    fi

    target="$(normalize_rpm_release_version "$candidate")"
    installed="$(rpm_upgradable_installed_version "$pkg" || true)"

    if [ -n "$target" ] && [ "$target" != "$current_version" ]; then
      printf '%s\n' "$target"
      return 0
    fi

    if [ -n "$installed" ] && [ "$installed" != "$candidate" ]; then
      printf '%s %s -> %s\n' "$pkg" "$installed" "$candidate"
      return 0
    fi
  done < <(rpm_system_release_packages)

  printf '%s\n' "$NO_UPDATE_TEXT"
}

get_current_kernel_package_rpm() {
  local kernel by_file

  kernel="$(uname -r 2>/dev/null || echo '-')"

  by_file="$(rpm -qf --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "/boot/vmlinuz-$kernel" 2>/dev/null || true)"

  if [ -n "$by_file" ] && ! printf '%s\n' "$by_file" | grep -qi 'not owned'; then
    printf '%s\n' "$by_file" | head -n 1
    return 0
  fi

  printf 'kernel-%s\n' "$kernel"
}

get_current_kernel_rpm_name() {
  local kernel name

  kernel="$(uname -r 2>/dev/null || echo '-')"

  name="$(rpm -qf --qf '%{NAME}\n' "/boot/vmlinuz-$kernel" 2>/dev/null || true)"

  if [ -n "$name" ] && ! printf '%s\n' "$name" | grep -qi 'not owned'; then
    printf '%s\n' "$name" | head -n 1
    return 0
  fi

  printf '%s\n' "kernel"
}

get_latest_installed_kernel_package_rpm_by_names() {
  local names="$1"

  rpm -qa --qf '%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}\n' 2>/dev/null \
    | awk -F'|' -v names="$names" '
        BEGIN {
          split(names, a, " ")
          for (i in a) wanted[a[i]] = 1
        }
        wanted[$1] {
          print $1 "-" $2 "-" $3 "." $4
        }
      ' \
    | sort -V \
    | tail -n 1
}

get_oracle_kernel_family_from_running_kernel() {
  local kernel="$1"

  if printf '%s\n' "$kernel" | grep -qi 'uek'; then
    printf '%s\n' "uek"
  else
    printf '%s\n' "rhck"
  fi
}

get_updated_kernel_rpm() {
  local current_pkg="$1"
  local running_kernel kernel_family latest_installed candidate pkg current_kernel_name names_to_check

  running_kernel="$(uname -r 2>/dev/null || echo '')"
  current_kernel_name="$(get_current_kernel_rpm_name)"

  load_os_release

  if [ "$OS_ID" = "ol" ] || [ "$OS_ID" = "oracle" ]; then
    kernel_family="$(get_oracle_kernel_family_from_running_kernel "$running_kernel")"

    if [ "$kernel_family" = "uek" ]; then
      names_to_check="kernel-uek-core kernel-uek"
    else
      names_to_check="kernel-core kernel"
    fi
  else
    case "$current_kernel_name" in
      kernel-core)
        names_to_check="kernel-core kernel"
        ;;
      kernel)
        names_to_check="kernel kernel-core"
        ;;
      kernel-default)
        names_to_check="kernel-default kernel-default-base kernel"
        ;;
      *)
        names_to_check="$current_kernel_name kernel-core kernel kernel-default"
        ;;
    esac
  fi

  # Caso o kernel novo ja esteja instalado, mas ainda nao esteja em uso.
  latest_installed="$(get_latest_installed_kernel_package_rpm_by_names "$names_to_check" || true)"

  if [ -n "$latest_installed" ] && [ "$latest_installed" != "$current_pkg" ]; then
    printf '%s\n' "$latest_installed"
    return 0
  fi

  # Caso exista kernel novo disponivel no repositorio.
  for pkg in $names_to_check; do
    candidate="$(rpm_upgradable_candidate_package_string "$pkg" || true)"

    if [ -n "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "$NO_UPDATE_TEXT"
}

# ==============================================================================
# Zypper - SUSE / openSUSE
# ==============================================================================

load_zypper_upgradable() {
  ZYPPER_UPGRADABLE="$(zypper --non-interactive list-updates -t package 2>/dev/null || true)"
}

zypper_upgradable_line() {
  local pkg="$1"

  printf '%s\n' "$ZYPPER_UPGRADABLE" \
    | awk -F'|' -v p="$pkg" '
        NF >= 5 {
          name=$3
          gsub(/^[ \t]+|[ \t]+$/, "", name)
          if (name == p) {
            print
            exit
          }
        }
      '
}

zypper_available_version() {
  local line

  line="$(zypper_upgradable_line "$1")"

  if [ -z "$line" ]; then
    return 1
  fi

  printf '%s\n' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $5); print $5}'
}

get_updated_distro_version_zypper() {
  local current_version="$1"
  local pkg candidate

  for pkg in openSUSE-release openSUSE-release-appliance-custom SLES-release sles-release sled-release; do
    candidate="$(zypper_available_version "$pkg" || true)"

    if [ -n "$candidate" ] && [ "$candidate" != "$current_version" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "$NO_UPDATE_TEXT"
}

get_current_kernel_package_zypper() {
  get_current_kernel_package_rpm
}

get_updated_kernel_zypper() {
  local current_pkg="$1"
  local base_pkg candidate arch latest_installed

  base_pkg="$(printf '%s\n' "$current_pkg" | sed -E 's/-[0-9].*$//')"

  if [ -z "$base_pkg" ]; then
    base_pkg="kernel-default"
  fi

  latest_installed="$(get_latest_installed_kernel_package_rpm_by_names "$base_pkg" || true)"

  if [ -n "$latest_installed" ] && [ "$latest_installed" != "$current_pkg" ]; then
    printf '%s\n' "$latest_installed"
    return 0
  fi

  candidate="$(zypper_available_version "$base_pkg" || true)"
  arch="$(rpm --eval '%{_arch}' 2>/dev/null || echo unknown)"

  if [ -n "$candidate" ]; then
    printf '%s-%s.%s\n' "$base_pkg" "$candidate" "$arch"
    return 0
  fi

  for pkg in kernel-default kernel-default-base kernel; do
    candidate="$(zypper_available_version "$pkg" || true)"

    if [ -n "$candidate" ]; then
      printf '%s-%s.%s\n' "$pkg" "$candidate" "$arch"
      return 0
    fi
  done

  printf '%s\n' "$NO_UPDATE_TEXT"
}

# ==============================================================================
# Pacman - Arch / Manjaro
# ==============================================================================

load_pacman_upgradable() {
  PACMAN_UPGRADABLE="$(pacman -Qu 2>/dev/null || true)"
}

pacman_upgradable_line() {
  local pkg="$1"

  printf '%s\n' "$PACMAN_UPGRADABLE" \
    | awk -v p="$pkg" '$1 == p {print; exit}'
}

get_updated_distro_version_pacman() {
  printf '%s\n' "$NO_UPDATE_TEXT"
}

get_current_kernel_package_pacman() {
  local kernel owner pkgver possible_file

  kernel="$(uname -r 2>/dev/null || echo '-')"

  for possible_file in \
    /boot/vmlinuz-linux \
    /boot/vmlinuz-linux-lts \
    /boot/vmlinuz-linux-zen \
    /boot/vmlinuz-linux-hardened
  do
    if [ -e "$possible_file" ]; then
      owner="$(pacman -Qo "$possible_file" 2>/dev/null | awk '{print $5}' || true)"

      if [ -n "$owner" ]; then
        pkgver="$(pacman -Q "$owner" 2>/dev/null | awk '{print $2}' || true)"

        if [ -n "$pkgver" ]; then
          printf '%s-%s\n' "$owner" "$pkgver"
          return 0
        fi
      fi
    fi
  done

  printf 'kernel-%s\n' "$kernel"
}

get_updated_kernel_pacman() {
  local line pkg oldver newver

  for pkg in linux linux-lts linux-zen linux-hardened; do
    line="$(pacman_upgradable_line "$pkg" || true)"

    if [ -n "$line" ]; then
      oldver="$(printf '%s\n' "$line" | awk '{print $2}')"
      newver="$(printf '%s\n' "$line" | awk '{print $4}')"
      printf '%s %s -> %s\n' "$pkg" "$oldver" "$newver"
      return 0
    fi
  done

  printf '%s\n' "$NO_UPDATE_TEXT"
}

# ==============================================================================
# APK - Alpine
# ==============================================================================

load_apk_upgradable() {
  APK_UPGRADABLE="$(apk version -l '<' 2>/dev/null || true)"
}

apk_upgradable_line() {
  local pkg="$1"

  printf '%s\n' "$APK_UPGRADABLE" \
    | awk -v p="$pkg" '
        $1 ~ "^" p "-" {
          print
          exit
        }
      '
}

get_updated_distro_version_apk() {
  local line

  line="$(apk_upgradable_line "alpine-base" || true)"

  if [ -n "$line" ]; then
    printf '%s\n' "$line"
    return 0
  fi

  printf '%s\n' "$NO_UPDATE_TEXT"
}

get_current_kernel_package_apk() {
  local kernel

  kernel="$(uname -r 2>/dev/null || echo '-')"

  printf 'linux-%s\n' "$kernel"
}

get_updated_kernel_apk() {
  local line

  for pkg in linux-lts linux-virt linux-edge linux-rpi; do
    line="$(apk_upgradable_line "$pkg" || true)"

    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done

  printf '%s\n' "$NO_UPDATE_TEXT"
}

# ==============================================================================
# Wrappers genericos
# ==============================================================================

load_upgradable() {
  case "$PKG_MANAGER" in
    apt)
      load_apt_upgradable
      ;;
    dnf|yum)
      load_rpm_upgradable
      ;;
    zypper)
      load_zypper_upgradable
      ;;
    pacman)
      load_pacman_upgradable
      ;;
    apk)
      load_apk_upgradable
      ;;
    *)
      APT_UPGRADABLE=""
      RPM_UPGRADABLE=""
      ZYPPER_UPGRADABLE=""
      PACMAN_UPGRADABLE=""
      APK_UPGRADABLE=""
      ;;
  esac
}

get_current_kernel_package() {
  case "$PKG_MANAGER" in
    apt)
      get_current_kernel_package_apt
      ;;
    dnf|yum|rpm)
      get_current_kernel_package_rpm
      ;;
    zypper)
      get_current_kernel_package_zypper
      ;;
    pacman)
      get_current_kernel_package_pacman
      ;;
    apk)
      get_current_kernel_package_apk
      ;;
    *)
      printf 'kernel-%s\n' "$(uname -r 2>/dev/null || echo '-')"
      ;;
  esac
}

get_updated_distro_version() {
  local current_version="$1"

  case "$PKG_MANAGER" in
    apt)
      get_updated_distro_version_apt "$current_version"
      ;;
    dnf|yum)
      get_updated_distro_version_rpm "$current_version"
      ;;
    zypper)
      get_updated_distro_version_zypper "$current_version"
      ;;
    pacman)
      get_updated_distro_version_pacman "$current_version"
      ;;
    apk)
      get_updated_distro_version_apk "$current_version"
      ;;
    *)
      printf '%s\n' "$NO_UPDATE_TEXT"
      ;;
  esac
}

get_updated_kernel() {
  local current_pkg="$1"

  case "$PKG_MANAGER" in
    apt)
      get_updated_kernel_apt "$current_pkg"
      ;;
    dnf|yum)
      get_updated_kernel_rpm "$current_pkg"
      ;;
    zypper)
      get_updated_kernel_zypper "$current_pkg"
      ;;
    pacman)
      get_updated_kernel_pacman
      ;;
    apk)
      get_updated_kernel_apk
      ;;
    *)
      printf '%s\n' "$NO_UPDATE_TEXT"
      ;;
  esac
}

# ==============================================================================
# Saida
# ==============================================================================

csv_escape() {
  local s="$1"

  s="${s//\"/\"\"}"

  printf '"%s"' "$s"
}

print_row() {
  local values=("$@")
  local i

  if [ "$OUTPUT_FORMAT" = "csv" ]; then
    for i in "${!values[@]}"; do
      [ "$i" -gt 0 ] && printf ';'
      csv_escape "${values[$i]}"
    done
    printf '\n'
  else
    local IFS=$'\t'
    printf '%s\n' "${values[*]}"
  fi
}

print_header() {
  print_row \
    "Hostname" \
    "IP" \
    "Distro" \
    "Vs Atual" \
    "Kernel Atual" \
    "Vs Atualizada" \
    "Kernel Atualizado" \
    "Data Atualizacao"
}

# ==============================================================================
# Main
# ==============================================================================

detect_pkg_manager
refresh_package_cache
load_upgradable

HOSTNAME_VALUE="$(get_hostname)"
IP_VALUE="$(get_primary_ip)"
DISTRO_VALUE="$(get_distro_name)"
CURRENT_VERSION_VALUE="$(get_current_distro_version | trim)"
CURRENT_KERNEL_VALUE="$(get_current_kernel_package | trim)"
UPDATED_VERSION_VALUE="$(get_updated_distro_version "$CURRENT_VERSION_VALUE" | trim)"
UPDATED_KERNEL_VALUE="$(get_updated_kernel "$CURRENT_KERNEL_VALUE" | trim)"
DATE_VALUE="$(current_date_br)"

print_header
print_row \
  "$HOSTNAME_VALUE" \
  "$IP_VALUE" \
  "$DISTRO_VALUE" \
  "$CURRENT_VERSION_VALUE" \
  "$CURRENT_KERNEL_VALUE" \
  "$UPDATED_VERSION_VALUE" \
  "$UPDATED_KERNEL_VALUE" \
  "$DATE_VALUE"