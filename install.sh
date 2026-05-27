#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-cloudpanel-terminal-helper}"
INSTALL_DIR="${INSTALL_DIR:-/opt/cloudpanel-terminal-helper}"
GITHUB_REPO="RaulML20/cloudpanel-terminal-helper"
REPO_BRANCH="${REPO_BRANCH:-main}"
ARCHIVE_URL="https://github.com/$GITHUB_REPO/archive/refs/heads/$REPO_BRANCH.tar.gz"
NODE_VERSION="${NODE_VERSION:-24}"
TERMINAL_PORT="${TERMINAL_PORT:-7867}"
TERMINAL_HOST="${TERMINAL_HOST:-0.0.0.0}"
TERMINAL_PUBLIC_HOST="${TERMINAL_PUBLIC_HOST:-}"
TERMINAL_SSL_DIR="${TERMINAL_SSL_DIR:-$INSTALL_DIR/ssl}"
TERMINAL_ALLOWED_ORIGIN="${TERMINAL_ALLOWED_ORIGIN:-}"
TERMINAL_ALLOWED_CLIENT_IPS="${TERMINAL_ALLOWED_CLIENT_IPS:-}"
TERMINAL_CERT_CN="${TERMINAL_CERT_CN:-}"
TERMINAL_CERT_SAN="${TERMINAL_CERT_SAN:-}"
TERMINAL_MAX_CONCURRENT_SESSIONS="${TERMINAL_MAX_CONCURRENT_SESSIONS:-3}"
CLOUDPANEL_ROOT="${CLOUDPANEL_ROOT:-/home/clp/htdocs/app/files}"
CLOUDPANEL_TEMPLATE_DIR="${CLOUDPANEL_TEMPLATE_DIR:-$CLOUDPANEL_ROOT/templates/Frontend/Site}"
CLOUDPANEL_USERS_TEMPLATE="${CLOUDPANEL_USERS_TEMPLATE:-$CLOUDPANEL_TEMPLATE_DIR/users.html.twig}"
CLOUDPANEL_USERS_TEMPLATE_BACKUP="${CLOUDPANEL_USERS_TEMPLATE_BACKUP:-$CLOUDPANEL_USERS_TEMPLATE.cloudpanel-terminal-helper.bak}"
CLOUDPANEL_CACHE_DIR="${CLOUDPANEL_CACHE_DIR:-$CLOUDPANEL_ROOT/var/cache}"
CLOUDPANEL_FILE_OWNER="${CLOUDPANEL_FILE_OWNER:-clp:clp}"
CLOUDPANEL_FILE_MODE="${CLOUDPANEL_FILE_MODE:-770}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this installer as root." >&2
    exit 1
fi

if ! echo "$TERMINAL_PORT" | grep -Eq '^[0-9]+$'; then
    echo "TERMINAL_PORT must be a number." >&2
    exit 1
fi

if [ "$TERMINAL_PORT" -lt 1 ] || [ "$TERMINAL_PORT" -gt 65535 ]; then
    echo "TERMINAL_PORT must be between 1 and 65535 (got: $TERMINAL_PORT)." >&2
    exit 1
fi

if ! echo "$TERMINAL_MAX_CONCURRENT_SESSIONS" | grep -Eq '^[0-9]+$'; then
    echo "TERMINAL_MAX_CONCURRENT_SESSIONS must be a number." >&2
    exit 1
fi

is_valid_ip() {
    local value="$1"
    local addr="${value%%/*}"
    local mask=""
    if [ "$value" != "$addr" ]; then
        mask="${value#*/}"
        [ -n "$mask" ] || return 1
    fi

    if echo "$addr" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
        local IFS=.
        local -a octets=($addr)
        local o
        for o in "${octets[@]}"; do
            if [ -z "$o" ] || [ "${#o}" -gt 3 ]; then
                return 1
            fi
            if [ "${#o}" -gt 1 ] && [ "${o:0:1}" = "0" ]; then
                return 1
            fi
            if [ "$o" -gt 255 ]; then
                return 1
            fi
        done
        if [ -n "$mask" ]; then
            echo "$mask" | grep -Eq '^[0-9]+$' || return 1
            [ "$mask" -ge 0 ] && [ "$mask" -le 32 ] || return 1
        fi
        return 0
    fi

    if echo "$addr" | grep -q ':' && echo "$addr" | grep -Eq '^[0-9a-fA-F:]+$'; then
        is_valid_ipv6_address "$addr" || return 1
        if [ -n "$mask" ]; then
            echo "$mask" | grep -Eq '^[0-9]+$' || return 1
            [ "$mask" -ge 0 ] && [ "$mask" -le 128 ] || return 1
        fi
        return 0
    fi

    return 1
}

is_valid_ipv6_part() {
    local part="$1"
    local -a groups
    local group

    if [ -z "$part" ]; then
        echo 0
        return 0
    fi

    if [[ "$part" == :* || "$part" == *: ]]; then
        return 1
    fi

    IFS=':' read -ra groups <<< "$part"
    for group in "${groups[@]}"; do
        if ! [[ "$group" =~ ^[0-9a-fA-F]{1,4}$ ]]; then
            return 1
        fi
    done

    echo "${#groups[@]}"
}

is_valid_ipv6_address() {
    local addr="$1"
    local left right left_count right_count total_count

    [[ "$addr" == *:* ]] || return 1
    [[ "$addr" != *:::* ]] || return 1

    if [[ "$addr" == *::* ]]; then
        right="${addr#*::}"
        [[ "$right" != *::* ]] || return 1
        left="${addr%%::*}"

        left_count="$(is_valid_ipv6_part "$left")" || return 1
        right_count="$(is_valid_ipv6_part "$right")" || return 1
        total_count=$((left_count + right_count))
        [ "$total_count" -le 7 ] || return 1
        return 0
    fi

    total_count="$(is_valid_ipv6_part "$addr")" || return 1
    [ "$total_count" -eq 8 ]
}

normalize_allowed_client_ips() {
    local -a ips
    local ip normalized count
    normalized=""
    count=0

    IFS=',' read -ra ips <<< "$TERMINAL_ALLOWED_CLIENT_IPS"
    for ip in "${ips[@]}"; do
        ip="${ip#"${ip%%[![:space:]]*}"}"
        ip="${ip%"${ip##*[![:space:]]}"}"
        [ -z "$ip" ] && continue

        if ! is_valid_ip "$ip"; then
            echo "TERMINAL_ALLOWED_CLIENT_IPS contains an invalid value: '$ip'" >&2
            echo "Use real IPv4/IPv6 addresses or CIDR ranges, comma separated. Example:" >&2
            echo "TERMINAL_ALLOWED_CLIENT_IPS=\"203.0.113.45\" bash install.sh" >&2
            exit 1
        fi

        if [ -n "$normalized" ]; then
            normalized="${normalized},${ip}"
        else
            normalized="$ip"
        fi
        count=$((count + 1))
    done

    if [ "$count" -eq 0 ]; then
        echo "TERMINAL_ALLOWED_CLIENT_IPS is required." >&2
        echo "Use the public IP address that will access the browser terminal, for example:" >&2
        echo "TERMINAL_ALLOWED_CLIENT_IPS=\"YOUR_PUBLIC_IP\" bash install.sh" >&2
        exit 1
    fi

    TERMINAL_ALLOWED_CLIENT_IPS="$normalized"
}

normalize_allowed_client_ips

log() {
    printf '\n[%s] %s\n' "$APP_NAME" "$*"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

require_native_build_tools() {
    local -a missing_tools
    local tool
    missing_tools=()

    for tool in python3 make g++; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ "${#missing_tools[@]}" -gt 0 ]; then
        echo "Missing native build tools required by node-pty: ${missing_tools[*]}" >&2
        echo "Install them first, for example:" >&2
        echo "apt -y install python3 make g++" >&2
        exit 1
    fi
}

quote_env_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    printf '"%s"' "$value"
}

write_env_var() {
    local name="$1"
    local value="$2"
    printf '%s=%s\n' "$name" "$(quote_env_value "$value")"
}

check_cloudpanel() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "systemctl is required to verify CloudPanel services." >&2
        exit 1
    fi

    for unit in clp-php-fpm.service clp-nginx.service; do
        if [ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null)" != "loaded" ]; then
            echo "CloudPanel service not found: $unit" >&2
            echo "Install CloudPanel before running this installer." >&2
            exit 1
        fi
    done

    if [ ! -d "$CLOUDPANEL_ROOT" ]; then
        echo "CloudPanel files directory not found: $CLOUDPANEL_ROOT" >&2
        echo "Install CloudPanel before running this installer." >&2
        exit 1
    fi
}

detect_public_host() {
    if [ -n "$TERMINAL_PUBLIC_HOST" ]; then
        echo "$TERMINAL_PUBLIC_HOST"
        return
    fi

    curl -fsS https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'
}

make_subject_alt_name() {
    local host="$1"

    if echo "$host" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
        echo "IP:$host"
    elif [[ "$host" == *:* ]] && is_valid_ipv6_address "$host"; then
        echo "IP:$host"
    else
        echo "DNS:$host"
    fi
}

format_url_host() {
    local host="$1"

    if [[ "$host" == \[*\] ]]; then
        echo "$host"
    elif [[ "$host" == *:* ]]; then
        echo "[$host]"
    else
        echo "$host"
    fi
}

install_node() {
    log "Installing Node.js $NODE_VERSION with nvm"
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    fi

    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    nvm install "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    nvm use "$NODE_VERSION"

    npm install pm2@latest -g
}

expose_node_commands() {
    log "Exposing Node.js and PM2 commands in /usr/local/bin"
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    nvm use "$NODE_VERSION"

    ln -sf "$(command -v node)" /usr/local/bin/node
    ln -sf "$(command -v npm)" /usr/local/bin/npm
    ln -sf "$(command -v npx)" /usr/local/bin/npx
    ln -sf "$(command -v pm2)" /usr/local/bin/pm2
    ln -sf "$(command -v pm2-runtime)" /usr/local/bin/pm2-runtime
}

fetch_app() {
    log "Installing application in $INSTALL_DIR"

    local tmp_dir archive extracted_dir backup_dir
    tmp_dir="$(mktemp -d)"
    archive="$tmp_dir/app.tar.gz"

    curl -fsSL "$ARCHIVE_URL" -o "$archive"
    tar -xzf "$archive" -C "$tmp_dir"
    extracted_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

    if [ -z "$extracted_dir" ]; then
        echo "Unable to extract application archive." >&2
        exit 1
    fi

    if [ -d "$INSTALL_DIR" ] && [ "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 | head -n 1)" ]; then
        backup_dir="${INSTALL_DIR}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$INSTALL_DIR" "$backup_dir"
        log "Existing install directory moved to $backup_dir"
    fi

    mkdir -p "$INSTALL_DIR"
    cp -a "$extracted_dir"/. "$INSTALL_DIR"
    rm -rf "$tmp_dir"
}

install_node_dependencies() {
    log "Installing npm dependencies"
    cd "$INSTALL_DIR"

    if [ -f package-lock.json ]; then
        npm ci --omit=dev
    else
        npm install --omit=dev
    fi
}

write_env_file() {
    local detected_host
    detected_host="$(detect_public_host)"

    if [ -z "$detected_host" ]; then
        echo "Unable to detect the VPS public IP or hostname." >&2
        echo "Set TERMINAL_PUBLIC_HOST manually, for example:" >&2
        echo "TERMINAL_PUBLIC_HOST=\"YOUR_VPS_IP_OR_DOMAIN\" TERMINAL_ALLOWED_CLIENT_IPS=\"YOUR_PUBLIC_IP\" bash install.sh" >&2
        exit 1
    fi

    if [ -z "$TERMINAL_ALLOWED_ORIGIN" ]; then
        TERMINAL_ALLOWED_ORIGIN="https://$(format_url_host "$detected_host"):8443"
    fi

    if [ -z "$TERMINAL_CERT_CN" ]; then
        TERMINAL_CERT_CN="$detected_host"
    fi

    if [ -z "$TERMINAL_CERT_SAN" ]; then
        TERMINAL_CERT_SAN="$(make_subject_alt_name "$detected_host")"
    fi

    log "Writing runtime configuration"
    {
        write_env_var "TERMINAL_PORT" "$TERMINAL_PORT"
        write_env_var "TERMINAL_HOST" "$TERMINAL_HOST"
        write_env_var "TERMINAL_SSL_DIR" "$TERMINAL_SSL_DIR"
        write_env_var "TERMINAL_ALLOWED_ORIGIN" "$TERMINAL_ALLOWED_ORIGIN"
        write_env_var "TERMINAL_ALLOWED_CLIENT_IPS" "$TERMINAL_ALLOWED_CLIENT_IPS"
        write_env_var "TERMINAL_CERT_CN" "$TERMINAL_CERT_CN"
        write_env_var "TERMINAL_CERT_SAN" "$TERMINAL_CERT_SAN"
        write_env_var "TERMINAL_MAX_CONCURRENT_SESSIONS" "$TERMINAL_MAX_CONCURRENT_SESSIONS"
    } > "$INSTALL_DIR/.env"
}

create_certificate() {
    log "Creating self-signed certificate"
    mkdir -p "$TERMINAL_SSL_DIR"

    if [ ! -f "$TERMINAL_SSL_DIR/terminal.key" ] || [ ! -f "$TERMINAL_SSL_DIR/terminal.crt" ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$TERMINAL_SSL_DIR/terminal.key" \
            -out "$TERMINAL_SSL_DIR/terminal.crt" \
            -days 1825 \
            -subj "/CN=$TERMINAL_CERT_CN" \
            -addext "subjectAltName=$TERMINAL_CERT_SAN"
    fi
}

install_template() {
    log "Installing CloudPanel Twig template"
    mkdir -p "$CLOUDPANEL_TEMPLATE_DIR"
    install -m 0644 "$INSTALL_DIR/terminal.html.twig" "$CLOUDPANEL_TEMPLATE_DIR/terminal.html.twig"
    chown "$CLOUDPANEL_FILE_OWNER" "$CLOUDPANEL_TEMPLATE_DIR/terminal.html.twig"
    chmod "$CLOUDPANEL_FILE_MODE" "$CLOUDPANEL_TEMPLATE_DIR/terminal.html.twig"

    if [ ! -f "$CLOUDPANEL_USERS_TEMPLATE" ]; then
        echo "CloudPanel users template not found: $CLOUDPANEL_USERS_TEMPLATE" >&2
        exit 1
    fi

    cp "$CLOUDPANEL_USERS_TEMPLATE" "$CLOUDPANEL_USERS_TEMPLATE_BACKUP"

    node - "$CLOUDPANEL_USERS_TEMPLATE_BACKUP" <<'JS'
const fs = require('fs');

const path = process.argv[2];
let text = fs.readFileSync(path, 'utf8');
const includeLinePattern = /^[ \t]*\{\{\s*include\('Frontend\/Site\/terminal\.html\.twig'.*\}\}[ \t]*(?:\r?\n)?/gm;

text = text.replace(includeLinePattern, '');
fs.writeFileSync(path, text);
JS

    chown "$CLOUDPANEL_FILE_OWNER" "$CLOUDPANEL_USERS_TEMPLATE_BACKUP"
    chmod "$CLOUDPANEL_FILE_MODE" "$CLOUDPANEL_USERS_TEMPLATE_BACKUP"

    node - "$CLOUDPANEL_USERS_TEMPLATE" "$TERMINAL_PORT" <<'JS'
const fs = require('fs');

const path = process.argv[2];
const port = process.argv[3];
let text = fs.readFileSync(path, 'utf8');
const include = "{{ include('Frontend/Site/terminal.html.twig', {'site': site, 'terminalPort': " + port + "}) }}";
const includeLinePattern = /^[ \t]*\{\{\s*include\('Frontend\/Site\/terminal\.html\.twig'.*\}\}[ \t]*(?:\r?\n)?/gm;

text = text.replace(includeLinePattern, '');

const siteContentMatch = /<div\s+class=["'][^"']*\bsite-content\b[^"']*["'][^>]*>/i.exec(text);

if (!siteContentMatch) {
    console.error('Could not find insertion point: <div class="site-content">');
    process.exit(1);
}

const siteContentStart = siteContentMatch.index + siteContentMatch[0].length;
const cardPattern = /<div\s+class=["'][^"']*\bcard\b[^"']*\bcard-table\b[^"']*["'][^>]*>/ig;

function findCardEnd(cardStart, openingTag) {
    const divPattern = /<\/?div\b[^>]*>/ig;
    divPattern.lastIndex = cardStart + openingTag.length;

    let match;
    let depth = 1;

    while ((match = divPattern.exec(text)) !== null) {
        if (match[0].startsWith('</')) {
            depth -= 1;

            if (depth === 0) return divPattern.lastIndex;
        } else {
            depth += 1;
        }
    }

    return -1;
}

function findSecondCardEnd() {
    cardPattern.lastIndex = 0;

    let match;
    let count = 0;

    while ((match = cardPattern.exec(text)) !== null) {
        if (match.index < siteContentStart) continue;

        count += 1;

        if (count === 2) return findCardEnd(match.index, match[0]);
    }

    return -1;
}

function findFtpCardEnd() {
    const ftpMarker = '{% trans %}FTP Users{% endtrans %}';
    const markerIndex = text.indexOf(ftpMarker, siteContentStart);

    if (markerIndex === -1) return -1;

    cardPattern.lastIndex = 0;

    let match;
    let selected = null;

    while ((match = cardPattern.exec(text)) !== null) {
        if (match.index < siteContentStart) continue;
        if (match.index > markerIndex) break;

        selected = match;
    }

    if (!selected) return -1;

    return findCardEnd(selected.index, selected[0]);
}

let closeEnd = findFtpCardEnd();

if (closeEnd === -1) {
    closeEnd = findSecondCardEnd();
}

if (closeEnd === -1) {
    console.error('Could not find insertion point after the FTP card or second card-table block inside site-content');
    process.exit(1);
}

let lineEnd = text.indexOf('\n', closeEnd);
if (lineEnd === -1) lineEnd = closeEnd;

text = text.slice(0, lineEnd + 1) + include + "\n" + text.slice(lineEnd + 1);
fs.writeFileSync(path, text);
JS

    chown "$CLOUDPANEL_FILE_OWNER" "$CLOUDPANEL_USERS_TEMPLATE"
    chmod "$CLOUDPANEL_FILE_MODE" "$CLOUDPANEL_USERS_TEMPLATE"

    log "Restorable backup updated: $CLOUDPANEL_USERS_TEMPLATE_BACKUP"
}

is_ipv6_value() {
    local addr="${1%%/*}"
    [[ "$addr" == *:* ]]
}

install_ufw_rules_block() {
    local rules_file="$1"
    local block_file="$2"
    local new_rules

    cp -a "$rules_file" "${rules_file}.cloudpanel-terminal-helper.bak"

    new_rules="$(mktemp)"
    awk -v block_file="$block_file" '
        BEGIN {
            in_block = 0
            inserted = 0
            while ((getline line < block_file) > 0) {
                block[++block_count] = line
            }
            close(block_file)
        }
        /^# BEGIN cloudpanel-terminal-helper/ { in_block = 1; next }
        /^# END cloudpanel-terminal-helper/ { in_block = 0; next }
        in_block { next }
        /^\*filter/ { in_filter = 1 }
        /^COMMIT$/ && in_filter && !inserted {
            for (i = 1; i <= block_count; i++) print block[i]
            inserted = 1
            in_filter = 0
        }
        { print }
        END {
            if (!inserted) {
                for (i = 1; i <= block_count; i++) print block[i]
            }
        }
    ' "$rules_file" > "$new_rules"

    install -m 0640 -o root -g root "$new_rules" "$rules_file"
    rm -f "$new_rules"
}

configure_firewall() {
    if [ -z "$TERMINAL_ALLOWED_CLIENT_IPS" ]; then
        log "Skipping UFW allow rule because TERMINAL_ALLOWED_CLIENT_IPS is empty"
        return
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        log "Skipping UFW allow rule because ufw is not installed"
        return
    fi

    log "Configuring UFW persistent allow rules"

    local before_rules="/etc/ufw/before.rules"
    local before6_rules="/etc/ufw/before6.rules"
    local ipv4_rules_block ipv6_rules_block ip ipv4_count ipv6_count
    local -a ips changed_rule_files
    ipv4_rules_block="$(mktemp)"
    ipv6_rules_block="$(mktemp)"
    ipv4_count=0
    ipv6_count=0
    changed_rule_files=()

    {
        echo "# BEGIN cloudpanel-terminal-helper"
        echo "# END cloudpanel-terminal-helper"
    } > "$ipv4_rules_block"

    {
        echo "# BEGIN cloudpanel-terminal-helper"
        echo "# END cloudpanel-terminal-helper"
    } > "$ipv6_rules_block"

    IFS=',' read -ra ips <<< "$TERMINAL_ALLOWED_CLIENT_IPS"
    for ip in "${ips[@]}"; do
        ip="${ip#"${ip%%[![:space:]]*}"}"
        ip="${ip%"${ip##*[![:space:]]}"}"
        [ -z "$ip" ] && continue

        if is_ipv6_value "$ip"; then
            awk -v rule="-A ufw6-before-input -p tcp -s $ip --dport $TERMINAL_PORT -j ACCEPT" '
                /^# END cloudpanel-terminal-helper$/ { print rule }
                { print }
            ' "$ipv6_rules_block" > "${ipv6_rules_block}.new"
            mv "${ipv6_rules_block}.new" "$ipv6_rules_block"
            ipv6_count=$((ipv6_count + 1))
        else
            awk -v rule="-A ufw-before-input -p tcp -s $ip --dport $TERMINAL_PORT -j ACCEPT" '
                /^# END cloudpanel-terminal-helper$/ { print rule }
                { print }
            ' "$ipv4_rules_block" > "${ipv4_rules_block}.new"
            mv "${ipv4_rules_block}.new" "$ipv4_rules_block"
            ipv4_count=$((ipv4_count + 1))
        fi
    done

    if [ "$ipv4_count" -gt 0 ]; then
        if [ -f "$before_rules" ]; then
            install_ufw_rules_block "$before_rules" "$ipv4_rules_block"
            changed_rule_files+=("$before_rules")
        else
            log "Skipping IPv4 UFW allow rules because $before_rules was not found"
        fi
    fi

    if [ "$ipv6_count" -gt 0 ]; then
        if [ -f "$before6_rules" ]; then
            install_ufw_rules_block "$before6_rules" "$ipv6_rules_block"
            changed_rule_files+=("$before6_rules")
        else
            log "Skipping IPv6 UFW allow rules because $before6_rules was not found"
        fi
    fi

    rm -f "$ipv4_rules_block" "$ipv6_rules_block"

    if [ "${#changed_rule_files[@]}" -eq 0 ]; then
        log "Skipping UFW reload because no persistent rule file was changed"
        return
    fi

    if ! ufw reload >/dev/null 2>&1; then
        log "ufw reload failed, restoring UFW rule files from backup"
        local changed_rule_file
        for changed_rule_file in "${changed_rule_files[@]}"; do
            install -m 0640 -o root -g root "${changed_rule_file}.cloudpanel-terminal-helper.bak" "$changed_rule_file"
        done
        if ! ufw reload; then
            echo "UFW reload still failing after restoring rule file backups." >&2
            echo "Inspect 'ufw status', /etc/ufw/before.rules, and /etc/ufw/before6.rules before retrying the installer." >&2
            exit 1
        fi
        echo "UFW rule files were restored; the persistent UFW rule was NOT applied." >&2
        echo "Re-run the installer once the conflict in UFW rule files is resolved." >&2
        exit 1
    fi
}

start_pm2() {
    log "Starting PM2 service"
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    nvm use "$NODE_VERSION"

    cd "$INSTALL_DIR"
    set -a
    # shellcheck disable=SC1091
    . "$INSTALL_DIR/.env"
    set +a

    pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
    pm2 start npm --name "$APP_NAME" -- start
    pm2 save
}

configure_pm2_cron() {
    log "Configuring PM2 resurrection on reboot"

    if ! command -v crontab >/dev/null 2>&1; then
        log "Skipping PM2 cron configuration because crontab is not installed"
        return
    fi

    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    nvm use "$NODE_VERSION"

    local pm2_path node_path cron_file
    pm2_path="$(command -v pm2)"
    node_path="$(dirname "$(command -v node)")"
    cron_file="$(mktemp)"

    crontab -l 2>/dev/null | awk '
        /# cloudpanel-terminal-helper pm2 start/ { skip=1; next }
        /# cloudpanel-terminal-helper pm2 end/ { skip=0; next }
        /pm2 resurrect/ { next }
        skip != 1 { print }
    ' > "$cron_file" || true
    {
        echo "# cloudpanel-terminal-helper pm2 start"
        echo "PATH=$node_path:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        echo "@reboot $pm2_path resurrect &> /dev/null"
        echo "# cloudpanel-terminal-helper pm2 end"
    } >> "$cron_file"
    crontab "$cron_file"
    rm -f "$cron_file"
}

restart_cloudpanel() {
    log "Clearing CloudPanel cache and restarting services"
    if [ -d "$CLOUDPANEL_CACHE_DIR" ]; then
        find "$CLOUDPANEL_CACHE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi

    systemctl restart clp-php-fpm
    systemctl restart clp-nginx
}

require_command curl
require_command tar
require_command openssl
check_cloudpanel
require_native_build_tools

install_node
expose_node_commands
fetch_app
install_node_dependencies
write_env_file
create_certificate
install_template
configure_firewall
start_pm2
configure_pm2_cron
restart_cloudpanel

log "Installation completed"
final_public_host="$(detect_public_host)"
echo "Gateway: https://$(format_url_host "$final_public_host"):$TERMINAL_PORT"
echo "Allowed origin: $TERMINAL_ALLOWED_ORIGIN"
echo "Allowed client IPs: $TERMINAL_ALLOWED_CLIENT_IPS"