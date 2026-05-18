#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-cloudpanel-terminal-helper}"
INSTALL_DIR="${INSTALL_DIR:-/opt/cloudpanel-terminal-helper}"
GITHUB_REPO="${GITHUB_REPO:-RaulML20/cloudpanel-terminal-helper}"
REPO_BRANCH="${REPO_BRANCH:-main}"
ARCHIVE_URL="${ARCHIVE_URL:-https://github.com/$GITHUB_REPO/archive/refs/heads/$REPO_BRANCH.tar.gz}"
NODE_VERSION="${NODE_VERSION:-24}"
TERMINAL_PORT="${TERMINAL_PORT:-7867}"
TERMINAL_HOST="${TERMINAL_HOST:-0.0.0.0}"
TERMINAL_PUBLIC_HOST="${TERMINAL_PUBLIC_HOST:-}"
TERMINAL_SSL_DIR="${TERMINAL_SSL_DIR:-$INSTALL_DIR/ssl}"
TERMINAL_ALLOWED_ORIGIN="${TERMINAL_ALLOWED_ORIGIN:-}"
TERMINAL_ALLOWED_CLIENT_IPS="${TERMINAL_ALLOWED_CLIENT_IPS:-}"
TERMINAL_CERT_CN="${TERMINAL_CERT_CN:-}"
TERMINAL_CERT_SAN="${TERMINAL_CERT_SAN:-}"
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

if [ -z "$TERMINAL_ALLOWED_CLIENT_IPS" ]; then
    echo "TERMINAL_ALLOWED_CLIENT_IPS is required." >&2
    echo "Use the public IP address that will access the browser terminal, for example:" >&2
    echo "TERMINAL_ALLOWED_CLIENT_IPS=\"YOUR_PUBLIC_IP\" bash install.sh" >&2
    exit 1
fi

log() {
    printf '\n[%s] %s\n' "$APP_NAME" "$*"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
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
    else
        echo "DNS:$host"
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
    npm install
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
        TERMINAL_ALLOWED_ORIGIN="https://${detected_host}:8443"
    fi

    if [ -z "$TERMINAL_CERT_CN" ]; then
        TERMINAL_CERT_CN="$detected_host"
    fi

    if [ -z "$TERMINAL_CERT_SAN" ]; then
        TERMINAL_CERT_SAN="$(make_subject_alt_name "$detected_host")"
    fi

    log "Writing runtime configuration"
    cat > "$INSTALL_DIR/.env" <<EOF
TERMINAL_PORT=$TERMINAL_PORT
TERMINAL_HOST=$TERMINAL_HOST
TERMINAL_SSL_DIR=$TERMINAL_SSL_DIR
TERMINAL_ALLOWED_ORIGIN=$TERMINAL_ALLOWED_ORIGIN
TERMINAL_ALLOWED_CLIENT_IPS=$TERMINAL_ALLOWED_CLIENT_IPS
TERMINAL_CERT_CN=$TERMINAL_CERT_CN
TERMINAL_CERT_SAN=$TERMINAL_CERT_SAN
EOF
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

configure_firewall() {
    if [ -z "$TERMINAL_ALLOWED_CLIENT_IPS" ]; then
        log "Skipping UFW allow rule because TERMINAL_ALLOWED_CLIENT_IPS is empty"
        return
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        log "Skipping UFW allow rule because ufw is not installed"
        return
    fi

    log "Configuring UFW"
    IFS=',' read -ra ips <<< "$TERMINAL_ALLOWED_CLIENT_IPS"
    for ip in "${ips[@]}"; do
        ip="${ip#"${ip%%[![:space:]]*}"}"
        ip="${ip%"${ip##*[![:space:]]}"}"
        [ -z "$ip" ] && continue
        ufw allow from "$ip" to any port "$TERMINAL_PORT" proto tcp comment 'SSH Terminal' || true
    done
    ufw reload || true
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
echo "Gateway: https://$(detect_public_host):$TERMINAL_PORT"
echo "Allowed origin: $TERMINAL_ALLOWED_ORIGIN"
echo "Allowed client IPs: $TERMINAL_ALLOWED_CLIENT_IPS"