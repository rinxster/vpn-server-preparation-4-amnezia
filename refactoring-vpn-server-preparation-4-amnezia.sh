#!/usr/bin/env bash
set -Eeuo pipefail

readonly SSH_PORT="222"
readonly SSH_FALLBACK_PORT="22"
readonly ENABLE_SSH_PASSWORD_AUTH="true"
readonly ADMIN_USER="0dmin4eg"
readonly UPDATE_SCHEDULE="Sun *-*-* 23:00:00"
readonly FAIL2BAN_BANTIME="1h"
readonly FAIL2BAN_FINDTIME="10m"
readonly FAIL2BAN_MAX_RETRY="10"

# SSH is migrated in two safe runs. A run from any other connection stages
# SSH_PORT plus the current/fallback port. Only a run invoked with sudo by
# ADMIN_USER from SSH_PORT finalizes the change and disables root SSH login.

# Firewall ports managed by this script. Add or remove one quoted entry per
# line. Ranges use UFW's "start:end" format, for example "8000:8010".
# Keep SSH_PORT in ALLOWED_TCP_PORTS to avoid locking yourself out.
readonly -a ALLOWED_TCP_PORTS=(
    "${SSH_PORT}" # SSH
    #"443"         # HTTPS / VPN
)
readonly -a ALLOWED_UDP_PORTS=(
    # "51820"     # Example: WireGuard
)
readonly LEGACY_UFW_APPLICATION="VPN Server Preparation"

readonly GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[1;33m' RESET='\033[0m'
declare -a SUCCEEDED=() FAILED=()
SSH_CLIENT_IP=""
SSH_CONNECTED_PORT=""
SSH_SERVER_IP=""
SSH_LOGIN_USER="root"
UBUNTU_MAJOR=""

log() { printf '%b\n' "$*"; }

run_step() {
    local description="$1"
    shift
    log "${YELLOW}==> ${description}${RESET}"
    if "$@"; then
        SUCCEEDED+=("${description}")
        return 0
    fi
    FAILED+=("${description}")
    log "${RED}FAILED: ${description}${RESET}"
    return 1
}

require_root() {
    if (( EUID != 0 )); then
        log "${RED}Run this script as root.${RESET}"
        exit 1
    fi
}

find_ancestor_ssh_connection() {
    local current_pid="${PPID}" parent_pid key value environment_entry
    local depth

    for ((depth = 0; depth < 16 && current_pid > 1; depth++)); do
        if [[ -r "/proc/${current_pid}/environ" ]]; then
            while IFS= read -r -d '' environment_entry; do
                if [[ "${environment_entry}" == SSH_CONNECTION=* ]]; then
                    printf '%s\n' "${environment_entry#SSH_CONNECTION=}"
                    return 0
                fi
            done < "/proc/${current_pid}/environ"
        fi

        parent_pid=""
        if [[ -r "/proc/${current_pid}/status" ]]; then
            while read -r key value _; do
                if [[ "${key}" == "PPid:" ]]; then
                    parent_pid="${value}"
                    break
                fi
            done < "/proc/${current_pid}/status"
        fi
        [[ "${parent_pid}" =~ ^[0-9]+$ ]] || return 1
        current_pid="${parent_pid}"
    done
    return 1
}

detect_ssh_session() {
    local client_port ssh_connection="${SSH_CONNECTION:-}"

    if [[ -z "${ssh_connection}" ]]; then
        ssh_connection="$(find_ancestor_ssh_connection)" || true
    fi

    if [[ -n "${ssh_connection}" ]]; then
        read -r SSH_CLIENT_IP client_port SSH_SERVER_IP SSH_CONNECTED_PORT <<<"${ssh_connection}"
        if [[ ! "${SSH_CLIENT_IP}" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            SSH_CLIENT_IP=""
        fi
        if [[ "${SSH_CONNECTED_PORT}" =~ ^[0-9]+$ ]]; then
            SSH_CONNECTED_PORT=$((10#${SSH_CONNECTED_PORT}))
        fi
        if [[ ! "${SSH_CONNECTED_PORT}" =~ ^[0-9]+$ ]] ||
            ((SSH_CONNECTED_PORT < 1 || SSH_CONNECTED_PORT > 65535)); then
            SSH_CONNECTED_PORT=""
        fi
        if [[ ! "${SSH_SERVER_IP}" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            SSH_SERVER_IP=""
        fi
    fi

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        SSH_LOGIN_USER="${SUDO_USER}"
    else
        SSH_LOGIN_USER="$(id -un)"
    fi
}

check_ubuntu_version() {
    local version_id
    [[ -r /etc/os-release ]] || { log "Unable to read /etc/os-release."; return 1; }
    # shellcheck source=/dev/null
    source /etc/os-release
    version_id="${VERSION_ID:-}"
    UBUNTU_MAJOR="${version_id%%.*}"
    [[ "${ID:-}" == "ubuntu" ]] || {
        log "This script supports Ubuntu only (detected: ${PRETTY_NAME:-unknown})."
        return 1
    }
    case "${UBUNTU_MAJOR}" in
        18|20|22|24|26) log "Detected ${PRETTY_NAME}." ;;
        *)
            log "Unsupported Ubuntu release: ${version_id:-unknown}. Supported: 18.04, 20.04, 22.04, 24.04, 26.04."
            return 1
            ;;
    esac
}

read_password() {
    local password_confirmation
    while true; do
        read -r -s -p "Enter a password for ${ADMIN_USER} and root: " ADMIN_PASSWORD
        printf '\n'
        if [[ -z "${ADMIN_PASSWORD}" ]]; then
            log "${RED}The password cannot be empty. Please try again.${RESET}"
            continue
        fi
        read -r -s -p "Confirm the password: " password_confirmation
        printf '\n'
        if [[ "${ADMIN_PASSWORD}" != "${password_confirmation}" ]]; then
            log "${RED}Passwords do not match. Please try again.${RESET}"
            continue
        fi
        break
    done
}

copy_existing_authorized_keys() {
    local account_entry admin_home admin_group key source_home source_keys
    local admin_keys
    local copied_source=false
    local -a source_key_files=("/root/.ssh/authorized_keys")

    account_entry="$(getent passwd "${ADMIN_USER}")" || return 1
    IFS=: read -r _ _ _ _ _ admin_home _ <<<"${account_entry}"
    admin_group="$(id -gn "${ADMIN_USER}")" || return 1
    admin_keys="${admin_home}/.ssh/authorized_keys"

    if [[ "${SSH_LOGIN_USER}" != "root" ]] && account_entry="$(getent passwd "${SSH_LOGIN_USER}")"; then
        IFS=: read -r _ _ _ _ _ source_home _ <<<"${account_entry}"
        source_key_files+=("${source_home}/.ssh/authorized_keys")
    fi

    install -d -m 0700 -o "${ADMIN_USER}" -g "${admin_group}" "${admin_home}/.ssh" || return 1
    if [[ ! -e "${admin_keys}" ]]; then
        install -m 0600 -o "${ADMIN_USER}" -g "${admin_group}" /dev/null "${admin_keys}" || return 1
    fi

    for source_keys in "${source_key_files[@]}"; do
        [[ -s "${source_keys}" ]] || continue
        copied_source=true
        [[ "${source_keys}" == "${admin_keys}" ]] && continue
        while IFS= read -r key || [[ -n "${key}" ]]; do
            [[ -n "${key}" ]] || continue
            if ! grep -Fx -- "${key}" "${admin_keys}" >/dev/null; then
                printf '%s\n' "${key}" >> "${admin_keys}" || return 1
            fi
        done < "${source_keys}"
    done
    chown "${ADMIN_USER}:${admin_group}" "${admin_keys}" || return 1
    chmod 0600 "${admin_keys}" || return 1

    if [[ "${copied_source}" == false ]]; then
        log "${YELLOW}No existing authorized_keys file was found; ${ADMIN_USER} will use password authentication.${RESET}"
    fi
}

configure_users() {
    local account_name password_status

    if ! id "${ADMIN_USER}" &>/dev/null; then
        useradd --create-home --comment "${ADMIN_USER}" --shell /bin/bash "${ADMIN_USER}" || return 1
    fi
    usermod --append --groups sudo "${ADMIN_USER}" || return 1
    printf '%s:%s\n' "${ADMIN_USER}" "${ADMIN_PASSWORD}" | chpasswd || return 1
    usermod --unlock "${ADMIN_USER}" || return 1
    chage --expiredate -1 "${ADMIN_USER}" || return 1
    printf 'root:%s\n' "${ADMIN_PASSWORD}" | chpasswd || return 1
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "${ADMIN_USER}" > "/etc/sudoers.d/${ADMIN_USER}"
    chmod 0440 "/etc/sudoers.d/${ADMIN_USER}" || return 1
    visudo --check --file "/etc/sudoers.d/${ADMIN_USER}" >/dev/null || return 1
    copy_existing_authorized_keys || return 1

    read -r account_name password_status _ < <(passwd -S "${ADMIN_USER}")
    if [[ "${account_name}" != "${ADMIN_USER}" || "${password_status}" != "P" ]]; then
        log "${RED}The administrator account does not have a usable password.${RESET}"
        return 1
    fi
    [[ "$(getent passwd "${ADMIN_USER}" | cut -d: -f7)" == "/bin/bash" ]]
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || return 1
    apt-get upgrade -y || return 1
    apt-get install -y --no-install-recommends fail2ban python3-systemd ufw \
        unattended-upgrades update-notifier-common || return 1

    # Convenience packages are not security-critical and may be renamed or
    # unavailable on a future Ubuntu release.
    if ! apt-get install -y --no-install-recommends curl mc speedtest-cli; then
        log "${YELLOW}Warning: one or more optional convenience packages were unavailable.${RESET}"
    fi
}

configure_automatic_updates() {
    # Disable APT's daily installation trigger. Package indexes and security
    # updates are handled together by the weekly systemd job below.
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

    cat > /usr/local/sbin/weekly-unattended-upgrades <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Prevent overlapping manual or timer-triggered runs of this job.
exec 9>/run/lock/weekly-unattended-upgrades.lock
flock --nonblock 9 || exit 0

export DEBIAN_FRONTEND=noninteractive
/usr/bin/apt-get -o Acquire::Retries=3 update
/usr/bin/unattended-upgrade --verbose

# Ubuntu creates this marker only when installed updates require a reboot.
if [[ -f /run/reboot-required ]]; then
    /usr/bin/logger --tag weekly-unattended-upgrades \
        "Updates installed; reboot required. Rebooting in one minute."
    /usr/sbin/shutdown --reboot +1 \
        "Rebooting after weekly unattended security updates"
fi
EOF
    chmod 0750 /usr/local/sbin/weekly-unattended-upgrades || return 1

    cat > /etc/systemd/system/weekly-unattended-upgrades.service <<'EOF'
[Unit]
Description=Install weekly unattended Ubuntu updates
Wants=network-online.target
After=network-online.target apt-daily.service apt-daily-upgrade.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/weekly-unattended-upgrades
Nice=19
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/weekly-unattended-upgrades.timer <<EOF
[Unit]
Description=Run unattended Ubuntu updates every Sunday at 23:00

[Timer]
OnCalendar=${UPDATE_SCHEDULE}
Persistent=true
AccuracySec=1min
RandomizedDelaySec=0
Unit=weekly-unattended-upgrades.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload || return 1
    systemctl disable --now apt-daily-upgrade.timer &>/dev/null || true
    systemctl enable unattended-upgrades.service || return 1
    systemctl enable --now weekly-unattended-upgrades.timer || return 1
    systemctl is-enabled --quiet weekly-unattended-upgrades.timer || return 1
    systemctl is-active --quiet weekly-unattended-upgrades.timer
}

append_unique() {
    local array_name="$1" value="$2" existing
    local -n array_reference="${array_name}"

    for existing in "${array_reference[@]}"; do
        [[ "${existing}" == "${value}" ]] && return 0
    done
    array_reference+=("${value}")
}

get_ssh_ports() {
    local mode="$1" output_array_name="$2"
    local -n output_array="${output_array_name}"

    output_array=("${SSH_PORT}")
    if [[ "${mode}" == "migration" ]]; then
        append_unique "${output_array_name}" "${SSH_FALLBACK_PORT}"
        if [[ -n "${SSH_CONNECTED_PORT}" ]]; then
            append_unique "${output_array_name}" "${SSH_CONNECTED_PORT}"
        fi
    fi
}

restore_ssh_configuration() {
    local backup_dir="$1" managed_config_existed="$2"
    local socket_override_existed="$3" use_socket_activation="$4"
    local managed_config="/etc/ssh/sshd_config.d/00-vpn-server-preparation.conf"
    local socket_override="/etc/systemd/system/ssh.socket.d/listen.conf"

    cp -a "${backup_dir}/sshd_config" /etc/ssh/sshd_config || true
    if [[ "${managed_config_existed}" == true ]]; then
        cp -a "${backup_dir}/00-vpn-server-preparation.conf" "${managed_config}" || true
    else
        rm -f -- "${managed_config}"
    fi
    if [[ "${socket_override_existed}" == true ]]; then
        install -d -m 0755 /etc/systemd/system/ssh.socket.d
        cp -a "${backup_dir}/ssh-socket-listen.conf" "${socket_override}" || true
    else
        rm -f -- "${socket_override}"
    fi

    systemctl daemon-reload || true
    if [[ "${use_socket_activation}" == true ]]; then
        systemctl restart ssh.socket || true
    else
        systemctl restart ssh.service || true
    fi
}

validate_admin_ssh_policy() {
    local effective_config="$1"

    if [[ "${ENABLE_SSH_PASSWORD_AUTH}" == true ]] &&
        ! grep -Ex 'passwordauthentication yes' <<<"${effective_config}" >/dev/null; then
        log "${RED}Password authentication is not effective for ${ADMIN_USER}.${RESET}"
        return 1
    fi
    if ! grep -Ex 'pubkeyauthentication yes' <<<"${effective_config}" >/dev/null; then
        log "${RED}Public-key authentication is not effective for ${ADMIN_USER}.${RESET}"
        return 1
    fi
    if ! grep -Ex 'authenticationmethods any' <<<"${effective_config}" >/dev/null; then
        log "${RED}An AuthenticationMethods rule would prevent password-or-key fallback.${RESET}"
        grep -E '^authenticationmethods ' <<<"${effective_config}" || true
        return 1
    fi
}

verify_ssh_endpoint() {
    local port="$1" keyscan_output address
    local -a addresses=("127.0.0.1")

    if [[ -n "${SSH_SERVER_IP}" ]]; then
        append_unique addresses "${SSH_SERVER_IP}"
    fi
    for address in "${addresses[@]}"; do
        keyscan_output="$(ssh-keyscan -T 5 -p "${port}" "${address}" 2>/dev/null)" || true
        [[ "${keyscan_output}" == *" ssh-"* ]] && return 0
    done

    log "${RED}SSH on port ${port} accepted TCP but did not complete an SSH handshake.${RESET}"
    return 1
}

prepare_sshd_runtime() {
    local tmpfiles_config="/etc/tmpfiles.d/vpn-server-sshd.conf"
    local directory_state

    # sshd -t checks its privilege-separation directory even before the daemon
    # starts. It may be absent immediately after a fresh install/upgrade.
    cat > "${tmpfiles_config}" <<'EOF'
d /run/sshd 0755 root root -
EOF
    if command -v systemd-tmpfiles &>/dev/null; then
        systemd-tmpfiles --create "${tmpfiles_config}" || return 1
    fi
    install -d -m 0755 -o root -g root /run/sshd || return 1

    directory_state="$(stat -c '%U:%G:%a' /run/sshd)" || return 1
    if [[ "${directory_state}" != "root:root:755" ]]; then
        log "${RED}Unexpected /run/sshd ownership or mode: ${directory_state}.${RESET}"
        return 1
    fi
}

configure_ssh() {
    local mode="$1"
    local ssh_config="/etc/ssh/sshd_config"
    local managed_config="/etc/ssh/sshd_config.d/00-vpn-server-preparation.conf"
    local socket_override="/etc/systemd/system/ssh.socket.d/listen.conf"
    local backup_dir effective_sshd_config effective_admin_config expected_root_policy password_policy port temp_config
    local managed_config_existed=false socket_override_existed=false use_socket_activation=false
    local -a ssh_ports=() effective_ports=()

    [[ "${mode}" == "migration" || "${mode}" == "final" ]] || return 1
    [[ -f "${ssh_config}" ]] || { log "${RED}${ssh_config} does not exist.${RESET}"; return 1; }
    prepare_sshd_runtime || return 1
    get_ssh_ports "${mode}" ssh_ports
    if [[ "${mode}" == "migration" ]]; then
        # Temporary recovery path. It is removed only after an authenticated
        # administrator session on SSH_PORT reruns the script.
        expected_root_policy="yes"
    else
        expected_root_policy="no"
    fi

    # Ubuntu 24.04+ normally uses the config-driven Accept=no socket. Older
    # releases may ship a dormant, conflicting Accept=yes socket; normalize
    # those releases to their standard ssh.service mode.
    if ((10#${UBUNTU_MAJOR} >= 24)) && systemctl is-active --quiet ssh.socket; then
        use_socket_activation=true
    elif ((10#${UBUNTU_MAJOR} >= 24)) && ! systemctl is-active --quiet ssh.service &&
        systemctl is-enabled --quiet ssh.socket; then
        use_socket_activation=true
    fi

    backup_dir="$(mktemp -d /run/vpn-server-ssh.XXXXXX)" || return 1
    cp -a "${ssh_config}" "${backup_dir}/sshd_config" || return 1
    if [[ -f "${managed_config}" ]]; then
        managed_config_existed=true
        cp -a "${managed_config}" "${backup_dir}/00-vpn-server-preparation.conf" || return 1
    fi
    if [[ -f "${socket_override}" ]]; then
        socket_override_existed=true
        cp -a "${socket_override}" "${backup_dir}/ssh-socket-listen.conf" || return 1
    fi

    if [[ "${ENABLE_SSH_PASSWORD_AUTH}" == true ]]; then
        password_policy="yes"
    else
        password_policy="no"
    fi
    temp_config="$(mktemp /etc/ssh/.sshd_config.XXXXXX)" || return 1
    {
        printf '# BEGIN vpn-server-preparation managed SSH settings\n'
        for port in "${ssh_ports[@]}"; do
            printf 'Port %s\n' "${port}"
        done
        printf 'PermitRootLogin %s\n' "${expected_root_policy}"
        printf 'PubkeyAuthentication yes\n'
        printf 'PasswordAuthentication %s\n' "${password_policy}"
        printf 'AuthenticationMethods any\n'
        printf 'UsePAM yes\n'
        printf '# END vpn-server-preparation managed SSH settings\n\n'
        sed -E \
            -e '/^# BEGIN vpn-server-preparation managed SSH settings$/,/^# END vpn-server-preparation managed SSH settings$/d' \
            -e '/^# Managed by vpn-server-preparation$/d' \
            -e '/^[[:space:]]*Port[[:space:]]+[0-9]+[[:space:]]*$/d' \
            -e '/^[[:space:]]*PermitRootLogin[[:space:]]+[^[:space:]]+[[:space:]]*$/d' \
            "${ssh_config}"
    } > "${temp_config}"
    chown --reference="${ssh_config}" "${temp_config}" || return 1
    chmod --reference="${ssh_config}" "${temp_config}" || return 1
    mv -f -- "${temp_config}" "${ssh_config}" || return 1

    # A beginning-of-main-file block works on Ubuntu 18.04 as well as newer
    # releases. Remove the drop-in used by an intermediate script revision.
    rm -f -- "${managed_config}"

    # Remove the override created by older revisions. Ubuntu 24.04+ generates
    # ssh.socket listeners from sshd_config during daemon-reload.
    rm -f -- "${socket_override}"

    if ! sshd -t; then
        log "${RED}The generated SSH configuration is invalid; restoring the previous configuration.${RESET}"
        restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
            "${socket_override_existed}" "${use_socket_activation}"
        return 1
    fi

    if ! effective_sshd_config="$(sshd -T)"; then
        restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
            "${socket_override_existed}" "${use_socket_activation}"
        return 1
    fi
    while read -r _ port _; do
        append_unique effective_ports "${port}"
    done < <(grep -E '^port [0-9]+$' <<<"${effective_sshd_config}")
    for port in "${ssh_ports[@]}"; do
        if [[ ! " ${effective_ports[*]} " == *" ${port} "* ]]; then
            log "${RED}Effective SSH configuration is missing required port ${port}.${RESET}"
            restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
                "${socket_override_existed}" "${use_socket_activation}"
            return 1
        fi
    done
    if [[ "${mode}" == "final" && "${#effective_ports[@]}" -ne 1 ]]; then
        log "${RED}Conflicting Port directives remain in SSH include files: ${effective_ports[*]}.${RESET}"
        grep -RnsE '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config.d /etc/ssh/sshd_config || true
        restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
            "${socket_override_existed}" "${use_socket_activation}"
        return 1
    fi

    if ! effective_admin_config="$(sshd -T -C \
        "user=${ADMIN_USER},host=localhost,addr=${SSH_CLIENT_IP:-127.0.0.1},laddr=127.0.0.1,lport=${SSH_PORT}")"; then
        restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
            "${socket_override_existed}" "${use_socket_activation}"
        return 1
    fi
    if ! validate_admin_ssh_policy "${effective_admin_config}"; then
        restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
            "${socket_override_existed}" "${use_socket_activation}"
        return 1
    fi
    if ! grep -Ex "permitrootlogin ${expected_root_policy}" <<<"${effective_sshd_config}" >/dev/null; then
        log "${RED}Unexpected effective PermitRootLogin policy.${RESET}"
        restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
            "${socket_override_existed}" "${use_socket_activation}"
        return 1
    fi

    if ! systemctl daemon-reload; then
        restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
            "${socket_override_existed}" "${use_socket_activation}"
        return 1
    fi
    if [[ "${use_socket_activation}" == true ]]; then
        systemctl disable ssh.service &>/dev/null || true
        if ! systemctl enable ssh.socket; then
            restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
                "${socket_override_existed}" "${use_socket_activation}"
            return 1
        fi
        if ! systemctl restart ssh.socket || ! systemctl is-active --quiet ssh.socket; then
            show_service_diagnostics ssh.socket
            restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
                "${socket_override_existed}" "${use_socket_activation}"
            return 1
        fi
        # Reload the socket-activated master without enabling it as a
        # standalone boot service. The socket queues new connections.
        if ! systemctl restart ssh.service; then
            show_service_diagnostics ssh.service
            restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
                "${socket_override_existed}" "${use_socket_activation}"
            return 1
        fi
    else
        systemctl disable --now ssh.socket &>/dev/null || true
        if ! systemctl enable ssh.service; then
            restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
                "${socket_override_existed}" "${use_socket_activation}"
            return 1
        fi
        if ! systemctl restart ssh.service || ! systemctl is-active --quiet ssh.service; then
            show_service_diagnostics ssh.service
            restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
                "${socket_override_existed}" "${use_socket_activation}"
            return 1
        fi
    fi

    for port in "${ssh_ports[@]}"; do
        if ! verify_ssh_endpoint "${port}"; then
            if [[ "${use_socket_activation}" == true ]]; then
                show_service_diagnostics ssh.socket
                show_service_diagnostics ssh.service
            else
                show_service_diagnostics ssh.service
            fi
            restore_ssh_configuration "${backup_dir}" "${managed_config_existed}" \
                "${socket_override_existed}" "${use_socket_activation}"
            return 1
        fi
    done
}

validate_port_spec() {
    local port_spec="$1"
    local first_port last_port

    if [[ ! "${port_spec}" =~ ^([0-9]{1,5})(:([0-9]{1,5}))?$ ]]; then
        log "Invalid firewall port '${port_spec}'. Use a port or start:end range."
        return 1
    fi

    first_port=$((10#${BASH_REMATCH[1]}))
    last_port="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
    last_port=$((10#${last_port}))
    if ((first_port < 1 || first_port > 65535 || last_port < first_port || last_port > 65535)); then
        log "Firewall port '${port_spec}' is outside the valid 1-65535 range."
        return 1
    fi
}

build_ufw_rules() {
    local mode="$1" output_array_name="$2"
    local port_spec
    local -a tcp_ports=("${ALLOWED_TCP_PORTS[@]}") ssh_ports=()
    local -n output_rules="${output_array_name}"

    output_rules=()

    get_ssh_ports "${mode}" ssh_ports
    for port_spec in "${ssh_ports[@]}"; do
        append_unique tcp_ports "${port_spec}"
    done

    for port_spec in "${tcp_ports[@]}"; do
        validate_port_spec "${port_spec}" || return 1
        append_unique "${output_array_name}" "${port_spec}/tcp"
    done
    for port_spec in "${ALLOWED_UDP_PORTS[@]}"; do
        validate_port_spec "${port_spec}" || return 1
        append_unique "${output_array_name}" "${port_spec}/udp"
    done

    ((${#output_rules[@]} > 0)) || {
        log "At least one TCP or UDP firewall port must be configured."
        return 1
    }
}

configure_ufw() {
    local mode="$1" port_spec rule previous_rule
    local ufw_status legacy_status
    local ssh_port_is_allowed=false
    local profile_path="/etc/ufw/applications.d/vpn-server-preparation"
    local state_dir="/var/lib/vpn-server-preparation"
    local state_file="${state_dir}/ufw-rules"
    local previous_rule_is_desired
    local -a desired_rules=() previous_rules=()

    for port_spec in "${ALLOWED_TCP_PORTS[@]}"; do
        if [[ "${port_spec}" == "${SSH_PORT}" ]]; then
            ssh_port_is_allowed=true
            break
        fi
    done
    if [[ "${ssh_port_is_allowed}" != true ]]; then
        log "ALLOWED_TCP_PORTS must contain SSH_PORT (${SSH_PORT}) to prevent SSH lockout."
        return 1
    fi

    build_ufw_rules "${mode}" desired_rules || return 1
    if [[ -f "${state_file}" ]]; then
        while IFS= read -r previous_rule || [[ -n "${previous_rule}" ]]; do
            [[ "${previous_rule}" =~ ^[0-9]+(:[0-9]+)?/(tcp|udp)$ ]] || continue
            append_unique previous_rules "${previous_rule}"
        done < "${state_file}"
    fi

    ufw default deny incoming || return 1
    ufw default allow outgoing || return 1

    # Add numeric rules before removing any old rule, preserving SSH access.
    # An empty UFW comment explicitly clears comments from existing rules.
    for rule in "${desired_rules[@]}"; do
        ufw allow "${rule}" comment '' || return 1
    done

    # Remove numeric rules previously owned by this script but no longer
    # present in the arrays/current SSH migration phase.
    for previous_rule in "${previous_rules[@]}"; do
        previous_rule_is_desired=false
        for rule in "${desired_rules[@]}"; do
            if [[ "${previous_rule}" == "${rule}" ]]; then
                previous_rule_is_desired=true
                break
            fi
        done
        if [[ "${previous_rule_is_desired}" == false ]]; then
            ufw --force delete allow "${previous_rule}" &>/dev/null || true
        fi
    done

    # Migrate the named application rule produced by older script revisions.
    legacy_status="$(ufw status; ufw show added)" || return 1
    if grep -F "${LEGACY_UFW_APPLICATION}" <<<"${legacy_status}" >/dev/null; then
        ufw --force delete allow "${LEGACY_UFW_APPLICATION}" || return 1
    fi
    rm -f -- "${profile_path}"

    ufw --force enable || return 1
    systemctl enable --now ufw.service || return 1
    ufw_status="$(ufw status)" || return 1
    grep -Ex 'Status: active' <<<"${ufw_status}" >/dev/null || return 1
    if grep -F "${LEGACY_UFW_APPLICATION}" <<<"${ufw_status}" >/dev/null; then
        log "${RED}The legacy named UFW rule is still present.${RESET}"
        return 1
    fi
    for rule in "${desired_rules[@]}"; do
        if ! grep -F "${rule}" <<<"${ufw_status}" >/dev/null; then
            log "${RED}UFW rule ${rule} is missing after configuration.${RESET}"
            return 1
        fi
    done

    install -d -m 0755 "${state_dir}" || return 1
    printf '%s\n' "${desired_rules[@]}" > "${state_file}" || return 1
    chmod 0600 "${state_file}"
}

show_service_diagnostics() {
    local service_name="$1"

    log "${RED}Diagnostics for ${service_name}:${RESET}"
    systemctl --no-pager --full status "${service_name}" || true
    journalctl --no-pager --unit "${service_name}" --lines 30 || true
}

restore_security_logging() {
    local legacy_override="/etc/systemd/journald.conf.d/no-logs.conf"

    # Remove only the exact override created by the original script. fail2ban's
    # systemd backend requires SSH events to remain available in the journal.
    rm -f -- "${legacy_override}"
    systemctl restart systemd-journald.service || return 1
    systemctl is-active --quiet systemd-journald.service || return 1

    if systemctl cat rsyslog.service &>/dev/null; then
        systemctl enable --now rsyslog.service || return 1
    fi
}

wait_for_fail2ban() {
    local attempt response

    for ((attempt = 1; attempt <= 20; attempt++)); do
        if response="$(fail2ban-client ping 2>/dev/null)" && [[ "${response}" == *pong* ]]; then
            return 0
        fi
        if ! systemctl is-active --quiet fail2ban.service; then
            log "${RED}fail2ban.service stopped while waiting for its control socket.${RESET}"
            show_service_diagnostics fail2ban.service
            return 1
        fi
        sleep 1
    done

    log "${RED}fail2ban did not create its control socket within 20 seconds.${RESET}"
    show_service_diagnostics fail2ban.service
    return 1
}

protect_migration_session_from_fail2ban() {
    local response

    [[ -n "${SSH_CLIENT_IP}" ]] || return 0
    if response="$(fail2ban-client ping 2>/dev/null)" && [[ "${response}" == *pong* ]]; then
        fail2ban-client set sshd unbanip "${SSH_CLIENT_IP}" &>/dev/null || true
        fail2ban-client set sshd addignoreip "${SSH_CLIENT_IP}" &>/dev/null || true
    fi
}

configure_fail2ban() {
    local mode="$1" ports_csv ignore_ips effective_bantime="${FAIL2BAN_BANTIME}"
    local effective_maxretry="${FAIL2BAN_MAX_RETRY}"
    local -a ssh_ports=() ignore_ip_list=("127.0.0.1/8" "::1")

    get_ssh_ports "${mode}" ssh_ports
    ports_csv="$(IFS=,; printf '%s' "${ssh_ports[*]}")"
    if [[ "${mode}" == "migration" && -n "${SSH_CLIENT_IP}" ]]; then
        append_unique ignore_ip_list "${SSH_CLIENT_IP}"
    fi
    if [[ "${mode}" == "migration" ]]; then
        # Avoid locking out an administrator who is testing the new login from
        # a different IP than the console/provisioning connection.
        effective_bantime="5m"
        effective_maxretry="20"
    fi
    ignore_ips="${ignore_ip_list[*]}"

    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[DEFAULT]
bantime = ${effective_bantime}
findtime = ${FAIL2BAN_FINDTIME}
maxretry = ${effective_maxretry}
ignoreip = ${ignore_ips}

[sshd]
enabled = true
port = ${ports_csv}
backend = systemd
EOF
    fail2ban-client -t || return 1
    systemctl enable fail2ban.service || return 1
    if ! systemctl restart fail2ban.service; then
        show_service_diagnostics fail2ban.service
        return 1
    fi
    wait_for_fail2ban || return 1
    if [[ -n "${SSH_CLIENT_IP}" ]]; then
        # Clear a ban persisted from an earlier failed migration. During the
        # staging run this address is also temporarily ignored.
        fail2ban-client set sshd unbanip "${SSH_CLIENT_IP}" &>/dev/null || true
    fi
    if ! fail2ban-client status sshd >/dev/null; then
        log "${RED}The fail2ban sshd jail is not running.${RESET}"
        fail2ban-client status || true
        show_service_diagnostics fail2ban.service
        return 1
    fi

}

configure_sysctl() {
    cat > /etc/sysctl.d/99-vpn-server-hardening.conf <<'EOF'
# Managed by vpn-server-preparation
net.ipv4.icmp_echo_ignore_all = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    modprobe tcp_bbr || return 1
    sysctl --system >/dev/null || return 1
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]]
}

print_summary() {
    local item
    printf '\n################################################################################\n'
    log "${GREEN}COMPLETED (${#SUCCEEDED[@]}):${RESET}"
    for item in "${SUCCEEDED[@]}"; do log "${GREEN}  [OK] ${item}${RESET}"; done
    log "${RED}FAILED (${#FAILED[@]}):${RESET}"
    if ((${#FAILED[@]} == 0)); then
        log "${GREEN}  None${RESET}"
    else
        for item in "${FAILED[@]}"; do log "${RED}  [FAILED] ${item}${RESET}"; done
    fi
    printf '################################################################################\n'
}

main() {
    local ssh_mode="migration"
    local firewall_ready=false ssh_ready=false

    require_root
    check_ubuntu_version || exit 1
    detect_ssh_session
    if [[ "${SSH_CONNECTED_PORT}" == "${SSH_PORT}" && "${SSH_LOGIN_USER}" == "${ADMIN_USER}" ]]; then
        ssh_mode="final"
        log "${GREEN}Verified ${ADMIN_USER} session on port ${SSH_PORT}; SSH migration will be finalized.${RESET}"
    else
        log "${YELLOW}SSH migration mode: ports ${SSH_FALLBACK_PORT} and ${SSH_PORT} remain available until login is proven.${RESET}"
        protect_migration_session_from_fail2ban
    fi
    read_password

    if ! run_step "Create/update administrator and passwords" configure_users; then
        print_summary
        exit 1
    fi
    unset ADMIN_PASSWORD

    run_step "Install and update packages" install_packages || true
    run_step "Schedule weekly updates (Sunday 23:00) and required reboot" configure_automatic_updates || true

    # Open both ports in migration mode before changing SSH. Dependent steps
    # do not continue after a firewall or SSH failure.
    if run_step "Configure and enable UFW (${ssh_mode})" configure_ufw "${ssh_mode}"; then
        firewall_ready=true
    fi
    if [[ "${firewall_ready}" == true ]]; then
        if run_step "Configure SSH (${ssh_mode})" configure_ssh "${ssh_mode}"; then
            ssh_ready=true
        fi
    else
        FAILED+=("Configure SSH (${ssh_mode}) - skipped because UFW failed")
        log "${RED}SKIPPED: SSH was not changed because UFW failed.${RESET}"
    fi
    if [[ "${ssh_ready}" == true ]]; then
        if run_step "Restore security logging" restore_security_logging; then
            run_step "Configure and enable fail2ban (${ssh_mode})" configure_fail2ban "${ssh_mode}" || true
        else
            FAILED+=("Configure and enable fail2ban (${ssh_mode}) - skipped because logging failed")
            log "${RED}SKIPPED: fail2ban was not changed because security logging is unavailable.${RESET}"
        fi
    else
        FAILED+=("Configure and enable fail2ban (${ssh_mode}) - skipped")
        log "${RED}SKIPPED: fail2ban was not changed because SSH was not safely configured.${RESET}"
    fi
    run_step "Enable BBR and network sysctl settings" configure_sysctl || true

    print_summary
    ((${#FAILED[@]} == 0)) || exit 1

    if [[ "${ssh_mode}" == "migration" ]]; then
        printf '\n'
        log "${YELLOW}SSH MIGRATION IS STAGED, NOT FINALIZED.${RESET}"
        log "Keep this session open. From a second terminal, connect as:"
        log "${GREEN}  ssh -p ${SSH_PORT} ${ADMIN_USER}@${SSH_SERVER_IP:-SERVER_IP}${RESET}"
        log "After that login succeeds, rerun this script with sudo from the new session."
        log "That proven second run will close port ${SSH_FALLBACK_PORT}, disable root SSH login, and remove the temporary fail2ban exception."
        log "The script will not reboot while SSH migration is pending."
        return 0
    fi

    read -r -p "Reboot now to ensure all kernel settings are active? [y/N]: " choice
    if [[ "${choice:-}" =~ ^[Yy]$ ]]; then reboot; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
