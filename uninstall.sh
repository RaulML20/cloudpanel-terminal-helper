#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-cloudpanel-terminal-helper}"
INSTALL_DIR="${INSTALL_DIR:-/opt/cloudpanel-terminal-helper}"
TERMINAL_PORT="${TERMINAL_PORT:-}"
TERMINAL_ALLOWED_CLIENT_IPS="${TERMINAL_ALLOWED_CLIENT_IPS:-}"
CLOUDPANEL_ROOT="${CLOUDPANEL_ROOT:-/home/clp/htdocs/app/files}"
CLOUDPANEL_TEMPLATE_DIR="${CLOUDPANEL_TEMPLATE_DIR:-$CLOUDPANEL_ROOT/templates/Frontend/Site}"
CLOUDPANEL_TERMINAL_TEMPLATE="${CLOUDPANEL_TERMINAL_TEMPLATE:-$CLOUDPANEL_TEMPLATE_DIR/terminal.html.twig}"
CLOUDPANEL_USERS_TEMPLATE="${CLOUDPANEL_USERS_TEMPLATE:-$CLOUDPANEL_TEMPLATE_DIR/users.html.twig}"
CLOUDPANEL_USERS_TEMPLATE_BACKUP="${CLOUDPANEL_USERS_TEMPLATE_BACKUP:-$CLOUDPANEL_USERS_TEMPLATE.cloudpanel-terminal-helper.bak}"
CLOUDPANEL_CACHE_DIR="${CLOUDPANEL_CACHE_DIR:-$CLOUDPANEL_ROOT/var/cache}"
CLOUDPANEL_FILE_OWNER="${CLOUDPANEL_FILE_OWNER:-clp:clp}"
CLOUDPANEL_FILE_MODE="${CLOUDPANEL_FILE_MODE:-770}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this uninstaller as root." >&2
    exit 1
fi

log() {
    printf '\n[%s] %s\n' "$APP_NAME" "$*"
}

load_installed_env() {
    if [ -f "$INSTALL_DIR/.env" ]; then
        set -a
        # shellcheck disable=SC1091
        . "$INSTALL_DIR/.env"
        set +a
    fi
}

stop_pm2() {
    if ! command -v pm2 >/dev/null 2>&1; then
        log "Skipping PM2 cleanup because pm2 is not available"
        return
    fi

    log "Stopping PM2 service"
    pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
    pm2 save >/dev/null 2>&1 || true
}

remove_pm2_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        log "Skipping PM2 cron cleanup because crontab is not available"
        return
    fi

    log "Removing PM2 resurrection cron block"
    local cron_file
    cron_file="$(mktemp)"

    crontab -l 2>/dev/null | awk '
        /# cloudpanel-terminal-helper pm2 start/ { skip=1; next }
        /# cloudpanel-terminal-helper pm2 end/ { skip=0; next }
        skip != 1 { print }
    ' > "$cron_file" || true

    if [ -s "$cron_file" ]; then
        crontab "$cron_file"
    else
        crontab -r 2>/dev/null || true
    fi

    rm -f "$cron_file"
}

delete_ufw_rules() {
    if ! command -v ufw >/dev/null 2>&1; then
        log "Skipping UFW cleanup because ufw is not installed"
        return
    fi

    if [ -z "${TERMINAL_PORT:-}" ]; then
        log "Skipping UFW cleanup because TERMINAL_PORT is unknown"
        return
    fi

    log "Removing UFW rules for port $TERMINAL_PORT"

    if [ -n "${TERMINAL_ALLOWED_CLIENT_IPS:-}" ]; then
        IFS=',' read -ra ips <<< "$TERMINAL_ALLOWED_CLIENT_IPS"
        for ip in "${ips[@]}"; do
            ip="${ip#"${ip%%[![:space:]]*}"}"
            ip="${ip%"${ip##*[![:space:]]}"}"
            [ -z "$ip" ] && continue
            ufw delete allow from "$ip" to any port "$TERMINAL_PORT" proto tcp >/dev/null 2>&1 || true
        done
    else
        while ufw status numbered | grep -Eq "^[[:space:]]*\\[[0-9]+\\].*${TERMINAL_PORT}/tcp"; do
            local rule_number
            rule_number="$(ufw status numbered | awk -v port="$TERMINAL_PORT/tcp" '$0 ~ port { gsub(/[][]/, "", $1); print $1; exit }')"
            [ -z "$rule_number" ] && break
            yes | ufw delete "$rule_number" >/dev/null 2>&1 || true
        done
    fi

    ufw reload >/dev/null 2>&1 || true
}

restore_users_template() {
    if [ -f "$CLOUDPANEL_USERS_TEMPLATE_BACKUP" ]; then
        log "Restoring users.html.twig from backup"
        cp "$CLOUDPANEL_USERS_TEMPLATE_BACKUP" "$CLOUDPANEL_USERS_TEMPLATE"
        chown "$CLOUDPANEL_FILE_OWNER" "$CLOUDPANEL_USERS_TEMPLATE"
        chmod "$CLOUDPANEL_FILE_MODE" "$CLOUDPANEL_USERS_TEMPLATE"
        rm -f "$CLOUDPANEL_USERS_TEMPLATE_BACKUP"
        return
    fi

    if [ ! -f "$CLOUDPANEL_USERS_TEMPLATE" ]; then
        log "Skipping users.html.twig cleanup because the file was not found"
        return
    fi

    log "Removing terminal include from users.html.twig"
    node - "$CLOUDPANEL_USERS_TEMPLATE" <<'JS'
const fs = require('fs');

const path = process.argv[2];
let text = fs.readFileSync(path, 'utf8');
const includeLinePattern = /^[ \t]*\{\{\s*include\('Frontend\/Site\/terminal\.html\.twig'.*\}\}[ \t]*(?:\r?\n)?/gm;

text = text.replace(includeLinePattern, '');
fs.writeFileSync(path, text);
JS

    chown "$CLOUDPANEL_FILE_OWNER" "$CLOUDPANEL_USERS_TEMPLATE"
    chmod "$CLOUDPANEL_FILE_MODE" "$CLOUDPANEL_USERS_TEMPLATE"
}

remove_templates() {
    if [ -f "$CLOUDPANEL_TERMINAL_TEMPLATE" ]; then
        log "Removing terminal Twig template"
        rm -f "$CLOUDPANEL_TERMINAL_TEMPLATE"
    fi
}

remove_install_dir() {
    if [ -d "$INSTALL_DIR" ]; then
        log "Removing $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
}

restart_cloudpanel() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log "Skipping CloudPanel service restart because systemctl is unavailable"
        return
    fi

    log "Clearing CloudPanel cache and restarting services"
    if [ -d "$CLOUDPANEL_CACHE_DIR" ]; then
        find "$CLOUDPANEL_CACHE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi

    systemctl restart clp-php-fpm >/dev/null 2>&1 || true
    systemctl restart clp-nginx >/dev/null 2>&1 || true
}

load_installed_env
stop_pm2
remove_pm2_cron
delete_ufw_rules
restore_users_template
remove_templates
restart_cloudpanel
remove_install_dir

log "Uninstall completed"
