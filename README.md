# CloudPanel Terminal Helper

Unofficial external web terminal helper for servers running CloudPanel. It uses Node.js, WebSocket, `node-pty`, and PM2.

> **Unofficial project:** this project is not affiliated with, endorsed by, sponsored by, or supported by CloudPanel or MGT-COMMERCE GmbH.

This repository is independent. It does not include CloudPanel source code, assets, logos, binaries, visual branding, or proprietary files. CloudPanel is referenced only descriptively to explain the environment this helper can integrate with.

## Security Warning

Installing a browser-accessible terminal next to an administration panel is sensitive and can be dangerous if exposed incorrectly. Review the code before installing it, restrict access to trusted public IP addresses only, and test it on a non-critical server first.

This helper:

- Does not ask for or store passwords, SSH keys, API keys, or CloudPanel credentials.
- Does not disable CloudPanel authentication, authorization, validation, telemetry, logging, or other security mechanisms.
- Requires an existing authenticated CloudPanel admin session before opening a terminal.
- Restricts WebSocket access to `TERMINAL_ALLOWED_CLIENT_IPS`.
- Should not be exposed publicly without IP restrictions and HTTPS/WSS.

Do not use this project to offer CloudPanel as a managed service to third parties. Do not monetize this helper as an official or endorsed CloudPanel product.

## Installation

Log in to the server via SSH as `root`.

```bash
ssh root@yourIpAddress
```

Prepare the system in the same style as the CloudPanel installer:

```bash
apt update && apt -y upgrade && apt -y install curl sudo
```

Recommended command:

```bash
curl -fsSL https://raw.githubusercontent.com/RaulML20/cloudpanel-terminal-helper/main/install.sh | \
  TERMINAL_PUBLIC_HOST="YOUR_VPS_IP_OR_DOMAIN" \
  TERMINAL_ALLOWED_CLIENT_IPS="YOUR_PUBLIC_IP" \
  TERMINAL_PORT="7867" \
  bash
```

If `npm install` fails while building `node-pty`, install the native build tools and run the installer again:

```bash
apt -y install python3 make g++
```

Download and run the installer:

```bash
curl -sS https://raw.githubusercontent.com/RaulML20/cloudpanel-terminal-helper/main/install.sh -o install.sh
TERMINAL_ALLOWED_CLIENT_IPS="YOUR_PUBLIC_IP" bash install.sh
```

You can also run it as a one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/RaulML20/cloudpanel-terminal-helper/main/install.sh | TERMINAL_ALLOWED_CLIENT_IPS="YOUR_PUBLIC_IP" bash
```

If you fork the repository or use a different branch:

```bash
curl -sS https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/install.sh -o install.sh
TERMINAL_ALLOWED_CLIENT_IPS="YOUR_PUBLIC_IP" GITHUB_REPO="YOUR_USER/YOUR_REPO" REPO_BRANCH="main" bash install.sh
```

## Useful Variables

```bash
TERMINAL_PUBLIC_HOST="YOUR_VPS_IP_OR_DOMAIN"
TERMINAL_ALLOWED_CLIENT_IPS="YOUR_PUBLIC_IP"
TERMINAL_ALLOWED_ORIGIN="https://YOUR_VPS_IP_OR_DOMAIN:8443"
TERMINAL_PORT="7867"
GITHUB_REPO="RaulML20/cloudpanel-terminal-helper"
REPO_BRANCH="main"
```

`TERMINAL_PUBLIC_HOST` is the VPS IP address or domain where CloudPanel is running. It is used for the allowed origin and the self-signed certificate.

The installer derives `TERMINAL_CERT_CN` and `TERMINAL_CERT_SAN` from `TERMINAL_PUBLIC_HOST` when they are not provided. For an IP address, the SAN is generated as `IP:YOUR_VPS_IP`; for a domain, it is generated as `DNS:YOUR_DOMAIN`.

`TERMINAL_ALLOWED_CLIENT_IPS` is the public IP address that will access the visual terminal from the browser. It is required and can contain multiple comma-separated IPs:

```bash
TERMINAL_ALLOWED_CLIENT_IPS="YOUR_PUBLIC_IP,ANOTHER_PUBLIC_IP"
```

Full example:

```bash
curl -sS https://raw.githubusercontent.com/RaulML20/cloudpanel-terminal-helper/main/install.sh -o install.sh
TERMINAL_PUBLIC_HOST="YOUR_VPS_IP_OR_DOMAIN" \
  TERMINAL_ALLOWED_CLIENT_IPS="YOUR_PUBLIC_IP" \
  TERMINAL_PORT="7867" \
  GITHUB_REPO="RaulML20/cloudpanel-terminal-helper" \
  bash install.sh
```

## Uninstall

The repository includes an uninstaller for a full cleanup of this helper:

```bash
curl -fsSL https://raw.githubusercontent.com/RaulML20/cloudpanel-terminal-helper/main/uninstall.sh | bash
```

Do not run the installer again from inside `/opt/cloudpanel-terminal-helper` after uninstalling. The uninstaller removes that directory, so the current shell may be left pointing to a deleted working directory. Run `cd /root` first, then run the installer again.

The uninstaller:

- Stops and removes the PM2 process named `cloudpanel-terminal-helper`.
- Removes the marked PM2 resurrection block from root's crontab.
- Removes the UFW rule for the configured terminal port when it can identify it from `/opt/cloudpanel-terminal-helper/.env`.
- Restores `users.html.twig` from the helper backup when available, then removes that backup file.
- Removes `/home/clp/htdocs/app/files/templates/Frontend/Site/terminal.html.twig`.
- Clears the CloudPanel cache and restarts `clp-php-fpm` and `clp-nginx`.
- Removes `/opt/cloudpanel-terminal-helper`.

It does not uninstall Node.js, nvm, npm, or PM2 globally because those tools may be used by other applications on the server.

## What The Installer Changes

The installer performs the following actions:

- Verifies that CloudPanel appears to be installed by checking `clp-php-fpm.service`, `clp-nginx.service`, and `/home/clp/htdocs/app/files`.
- Installs Node.js 24 with nvm using the official nvm installer.
- Installs PM2 globally with npm.
- Downloads this helper from GitHub into `/opt/cloudpanel-terminal-helper`; if that directory already exists, it is moved to a timestamped backup before installing a fresh copy.
- Installs the npm dependencies from this repository.
- Writes `/opt/cloudpanel-terminal-helper/.env` with runtime configuration.
- Creates a 5-year self-signed certificate in `/opt/cloudpanel-terminal-helper/ssl` if one does not already exist, using `TERMINAL_CERT_CN` and `TERMINAL_CERT_SAN`.
- Copies `terminal.html.twig` into `/home/clp/htdocs/app/files/templates/Frontend/Site/terminal.html.twig`; the helper serves local `@xterm/xterm` assets from npm under `/assets/...` instead of loading them from a CDN.
- Creates or overwrites a single restorable backup at `/home/clp/htdocs/app/files/templates/Frontend/Site/users.html.twig.cloudpanel-terminal-helper.bak` before modifying `users.html.twig`. The backup has the helper include removed so it can be used by the uninstaller.
- Inserts or updates a Twig include in `users.html.twig`, directly after the FTP users `card card-table` block inside `site-content`, so the helper UI appears as a sibling card in the expected site view position.
- Sets `terminal.html.twig`, the modified `users.html.twig`, and the backup file to owner `clp:clp` and mode `770` by default.
- Adds a UFW allow rule for the configured port and authorized IPs only when UFW is already installed.
- Starts the helper with PM2 and saves the PM2 process list.
- Adds a marked `pm2 resurrect` block to root's crontab only when cron is already available.
- Clears `/home/clp/htdocs/app/files/var/cache`.
- Restarts `clp-php-fpm` and `clp-nginx`.

The installer does not:

- Install, copy, bundle, or modify CloudPanel source code beyond the documented Twig include.
- Include CloudPanel logos, images, assets, branding, or binaries.
- Ask for or store credentials.
- Disable CloudPanel authentication or security controls.
- Install UFW or cron if they are missing.
- Configure this as an official CloudPanel feature.

## Important Notes

The gateway uses a self-signed certificate by default. Because the browser connects to the terminal through `wss://YOUR_VPS_IP_OR_DOMAIN:7867`, you may need to open `https://YOUR_VPS_IP_OR_DOMAIN:7867` once and accept/trust the certificate before the embedded terminal can connect.

`TERMINAL_ALLOWED_CLIENT_IPS` must be your public browser IP, not the VPS IP. This is the IP allowed to open the visual terminal connection.

Site path detection currently expects the CloudPanel site directory to match the first label of the domain under `/home`, for example `example.com` -> `/home/example`.

CloudPanel updates may replace or modify `users.html.twig`. If the terminal UI disappears after a CloudPanel update, run this installer again with the same variables so it can copy the template again, refresh the restorable backup, and reinsert the Twig include in the expected position.

Re-running the installer is supported. It moves the existing `/opt/cloudpanel-terminal-helper` directory to a timestamped backup, installs a fresh copy, rewrites `.env`, restarts PM2, and reapplies the template changes. Because the self-signed certificate is stored inside `/opt/cloudpanel-terminal-helper/ssl`, a reinstall may generate a new certificate and the browser may ask you to trust it again.

## Trademark Notice

CloudPanel and MGT-COMMERCE are trademarks or names of their respective owners. This project uses those names only for descriptive compatibility and installation context.