#!/bin/bash
set -euo pipefail

NONROOT_USER="0dmin4eg"
SSH_PORT="2222"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}")"
SUPPORTED_UBUNTU_VERSIONS=(18.04 20.04 22.04 24.04 26.04)

log() {
    echo "[vpn-prep] $*"
}

die() {
    echo "[vpn-prep] ОШИБКА: $*" >&2
    exit 1
}

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Пожалуйста, запустите от имени root"
}

is_ubuntu_supported() {
    [[ -f /etc/os-release ]] || die "Не удалось определить ОС (/etc/os-release отсутствует)."

    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "Поддерживается только Ubuntu."

    local major minor
    IFS=. read -r major minor _ <<< "${VERSION_ID:-0.0}"
    local version="${major}.${minor}"

    local v
    for v in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
        [[ "$version" == "$v" ]] && return 0
    done

    die "Неподдерживаемая версия Ubuntu: ${VERSION_ID}. Поддерживаются LTS: ${SUPPORTED_UBUNTU_VERSIONS[*]}"
}

pkg_install_required() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || die "Установка пакетов не удалась: $*"
}

pkg_install_optional() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || log "Предупреждение: опциональный пакет не установлен: $*"
}

svc_enable_now() {
    local unit="$1"
    systemctl enable --now "$unit" || die "Не удалось запустить службу: $unit"
}

svc_stop_disable_if_exists() {
    local unit="$1"
    if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
    fi
}

add_cron_line() {
    local line="$1"
    local current
    current="$(crontab -l 2>/dev/null || true)"
    if printf '%s\n' "$current" | grep -Fq "$line"; then
        return 0
    fi
    { printf '%s\n' "$current"; printf '%s\n' "$line"; } | crontab -
}

prompt_password() {
    local password1 password2
    echo '########################################'
    while true; do
        read -rsp 'Введите пароль для пользователя: ' password1
        echo
        read -rsp 'Подтвердите пароль: ' password2
        echo
        if [[ "$password1" == "$password2" ]]; then
            break
        fi
        echo "Пароли не совпадают. Попробуйте еще раз."
    done
    echo '########################################'
    PASSWORD="$password1"
    unset password1 password2
}

install_packages() {
    log "Обновление списка пакетов..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y

    log "Установка обязательных пакетов..."
    pkg_install_required curl ufw fail2ban unattended-upgrades wget

    log "Установка опциональных пакетов..."
    pkg_install_optional mc speedtest-cli update-notifier-common
}

configure_unattended_upgrades() {
    # shellcheck source=/dev/null
    source /etc/os-release
    local distro_id="${ID:-ubuntu}"
    local distro_codename="${VERSION_CODENAME:-}"

    [[ -n "$distro_codename" ]] || die "Не удалось определить VERSION_CODENAME из /etc/os-release"

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
EOF

    svc_enable_now unattended-upgrades.service
}

configure_cron_jobs() {
    add_cron_line '0 0 * * 1 [ "$(date +\%m)" != "$(date +\%m -d '\''next monday'\'')" ] && apt-get update && apt-get upgrade -y && apt-get autoremove -y'
    add_cron_line '0 0 * * 1 [ "$(date +\%U)" == "$(date +\%U -d '\''first day of this month'\'')" ] && reboot'
    add_cron_line '0 0 * * 0 /usr/local/sbin/vpn-prep-weekly-clean.sh'
}

configure_sshd() {
    log "Настройка SSH на порт ${SSH_PORT}..."
    echo '########################################'
    echo "Настройка порта SSH на ${SSH_PORT}."
    echo '########################################'

    install -d /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-vpn-prep.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
EOF

    if [[ -f /etc/ssh/sshd_config ]]; then
        sed -i -E 's/^[#[:space:]]*Port[[:space:]]+.*/Port '"${SSH_PORT}"'/' /etc/ssh/sshd_config
        grep -q "^Port ${SSH_PORT}" /etc/ssh/sshd_config || echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
        sed -i -E 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    fi

    sshd -t || die "Конфигурация SSH недействительна (sshd -t)"
    systemctl reload ssh || die "Не удалось перезагрузить ssh"
}

configure_ufw() {
    log "Настройка UFW..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    ufw allow 443/tcp comment 'VPN'

    LANG=C ufw --force enable || die "Не удалось включить UFW"
    systemctl enable ufw 2>/dev/null || true

    if ! LANG=C ufw status | grep -q 'Status: active'; then
        die "UFW не активен после включения"
    fi
}

configure_fail2ban() {
    log "Настройка fail2ban..."
    install -d /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/99-vpn-prep.conf <<'EOF'
[DEFAULT]
bantime = 1d

[sshd]
enabled = true
EOF

    fail2ban-client -t || die "Конфигурация fail2ban недействительна"
    svc_enable_now fail2ban.service

    if fail2ban-client status sshd &>/dev/null; then
        log "fail2ban: jail sshd активен"
    else
        log "Предупреждение: jail sshd не активен (проверьте логи fail2ban)"
    fi
}

configure_admin_user() {
    log "Создание пользователя ${NONROOT_USER}..."
    if id "$NONROOT_USER" &>/dev/null; then
        echo "Пользователь ${NONROOT_USER} уже существует."
        echo "${NONROOT_USER}:${PASSWORD}" | chpasswd
    else
        useradd -m -c "$NONROOT_USER" "$NONROOT_USER" -s /bin/bash
        usermod -aG sudo "$NONROOT_USER"
        echo "${NONROOT_USER}:${PASSWORD}" | chpasswd
    fi

    echo "root:${PASSWORD}" | chpasswd

    if ! grep -q "^${NONROOT_USER} ALL=(ALL) NOPASSWD: ALL" /etc/sudoers; then
        echo "${NONROOT_USER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    fi
}

configure_icmp_masking() {
    log "Отключение ICMP echo (маскировка)..."
    sysctl -w net.ipv4.icmp_echo_ignore_all=1
    if ! grep -q '^net.ipv4.icmp_echo_ignore_all=1' /etc/sysctl.conf; then
        echo "net.ipv4.icmp_echo_ignore_all=1" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1 || true
}

configure_bbr() {
    log "Включение TCP BBR (ускорение сетевых соединений)..."

    if ! modprobe tcp_bbr 2>/dev/null; then
        log "Предупреждение: модуль tcp_bbr недоступен — BBR не включён (требуется ядро Linux 4.9+)"
        return 0
    fi

    install -d /etc/modules-load.d
    echo 'tcp_bbr' > /etc/modules-load.d/vpn-prep-bbr.conf

    cat > /etc/sysctl.d/99-vpn-prep-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-vpn-prep-bbr.conf >/dev/null 2>&1 || true

    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        log "BBR активен: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    else
        log "Предупреждение: BBR не применён — проверьте поддержку ядра"
    fi
}

disable_logging() {
    echo '########################################'
    echo 'Отключение логирования...'
    echo '########################################'

    svc_stop_disable_if_exists rsyslog.service

    mkdir -p /etc/systemd/journald.conf.d/
    cat > /etc/systemd/journald.conf.d/no-logs.conf <<'EOF'
[Journal]
Storage=none
EOF

    if systemctl list-unit-files systemd-journald.service 2>/dev/null | grep -q systemd-journald.service; then
        systemctl restart systemd-journald || log "Предупреждение: не удалось перезапустить systemd-journald"
    fi
}

install_weekly_cleanup_script() {
    cat > /usr/local/sbin/vpn-prep-weekly-clean.sh <<'EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get autoremove -y
apt-get autoclean -y
if systemctl is-active --quiet systemd-journald 2>/dev/null; then
    journalctl --vacuum-time=1s 2>/dev/null || true
fi
find /var/log -type f -name '*.log.*' -delete 2>/dev/null || true
EOF
    chmod 755 /usr/local/sbin/vpn-prep-weekly-clean.sh
}

run_inline_cleanup() {
    log "Очистка системы..."
    /usr/local/sbin/vpn-prep-weekly-clean.sh
}

clear_shell_history() {
    log "Очистка истории bash..."
    history -c 2>/dev/null || true
    unset HISTFILE 2>/dev/null || true

    local home
    for home in /root "/home/${NONROOT_USER}"; do
        [[ -d "$home" ]] || continue
        : > "${home}/.bash_history" 2>/dev/null || true
        [[ -f "${home}/.wget-hsts" ]] && : > "${home}/.wget-hsts" 2>/dev/null || true
    done
}

schedule_self_destruct() {
    log "Планирование удаления скрипта с сервера..."
    local -a paths=()
    local p

    paths+=("$SCRIPT_PATH")
    if [[ -f "./vpn-server-preparation-4-amnezia.sh" ]]; then
        p="$(readlink -f "./vpn-server-preparation-4-amnezia.sh" 2>/dev/null || realpath "./vpn-server-preparation-4-amnezia.sh" 2>/dev/null || echo "./vpn-server-preparation-4-amnezia.sh")"
        [[ "$p" != "$SCRIPT_PATH" ]] && paths+=("$p")
    fi

    local wrapper="/tmp/vpn-prep-self-destruct-$$.sh"
    {
        echo '#!/bin/bash'
        for p in "${paths[@]}"; do
            printf 'rm -f %q\n' "$p"
        done
        printf 'rm -f %q\n' "$wrapper"
    } > "$wrapper"
    chmod 700 "$wrapper"

    if systemd-run --on-active=2min /bin/bash "$wrapper" 2>/dev/null; then
        log "Скрипт будет удалён через ~2 минуты (systemd-run)."
        return 0
    fi

    if command -v at >/dev/null && systemctl is-active --quiet atd 2>/dev/null; then
        echo "/bin/bash $wrapper" | at now + 2 minutes 2>/dev/null && {
            log "Скрипт будет удалён через ~2 минуты (at)."
            return 0
        }
    fi

    log "Планировщик недоступен — удаление скрипта немедленно."
    bash "$wrapper"
    rm -f "$wrapper"
}

prompt_reboot() {
    local choice
    read -rp "Хотите перезагрузить систему? (Y/N): " choice
    if [[ "$choice" == [Yy] ]]; then
        echo "Перезагрузка системы..."
        reboot
    else
        echo "Система не будет перезагружена."
    fi
}

main() {
    require_root
    is_ubuntu_supported

    prompt_password
    set +o history

    install_packages
    configure_unattended_upgrades
    install_weekly_cleanup_script
    configure_cron_jobs

    configure_sshd
    configure_ufw
    configure_fail2ban
    configure_admin_user
    configure_icmp_masking
    configure_bbr
    disable_logging
    run_inline_cleanup
    clear_shell_history
    schedule_self_destruct

    echo '################################################################################'
    echo -e "\e[1;33mПодготовка и предварительная настройка сервера завершена!\e[0m"
    echo '################################################################################'
    log "Скрипт самоуничтожится на сервере через ~2 минуты. Сохраните локальную копию."

    prompt_reboot
}

main "$@"
