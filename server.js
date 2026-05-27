const https = require('https');
const url = require('url');
const fs = require('fs');
const path = require('path');
const pty = require('node-pty');
const { WebSocketServer } = require('ws');

require('dotenv').config({ path: path.join(__dirname, '.env') });

const PORT = Number(process.env.TERMINAL_PORT || 7867);
const HOST = process.env.TERMINAL_HOST || '0.0.0.0';

const BASE_HOME = process.env.TERMINAL_BASE_HOME || '/home';
const SESSION_DIR = process.env.TERMINAL_SESSION_DIR || '/home/clp/htdocs/app/files/var/sessions';
const SESSION_COOKIE_NAME = process.env.TERMINAL_SESSION_COOKIE_NAME || 'cloudpanel';

const MAX_SESSION_AGE_SECONDS = Number(process.env.TERMINAL_MAX_SESSION_AGE_SECONDS || (24 * 60 * 60));

const ALLOWED_ORIGIN = process.env.TERMINAL_ALLOWED_ORIGIN || '';
const RAW_ALLOWED_CLIENT_IPS =
    (process.env.TERMINAL_ALLOWED_CLIENT_IPS || '')
        .split(',')
        .map((ip) => ip.trim())
        .filter(Boolean);
const SSL_DIR = process.env.TERMINAL_SSL_DIR || '/opt/cloudpanel-terminal-helper/ssl';

const MAX_CONCURRENT_SESSIONS = Number(process.env.TERMINAL_MAX_CONCURRENT_SESSIONS || 3);

if(!Number.isInteger(MAX_CONCURRENT_SESSIONS) || MAX_CONCURRENT_SESSIONS < 1) {
    console.error('TERMINAL_MAX_CONCURRENT_SESSIONS must be a positive integer.');
    process.exit(1);
}

if(process.getuid && process.getuid() !== 0) {
    console.error('CloudPanel Terminal Helper must run as root.');
    process.exit(1);
}

if(!ALLOWED_ORIGIN) {
    console.error('TERMINAL_ALLOWED_ORIGIN is required. Set it in .env or pass it as an environment variable.');
    process.exit(1);
}

function parseIpv4(ip) {
    if(!/^[0-9]+(\.[0-9]+){3}$/.test(ip)) return null;

    const octets = ip.split('.').map((part) => Number(part));
    if(octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)) return null;

    return octets.reduce((value, octet) => (value << 8n) + BigInt(octet), 0n);
}

function parseIpv6(ip) {
    let address = ip;
    const zoneIndex = address.indexOf('%');
    if(zoneIndex !== -1) address = address.slice(0, zoneIndex);
    if(!address.includes(':')) return null;

    if(address.includes('.')) {
        const lastColon = address.lastIndexOf(':');
        const ipv4Value = parseIpv4(address.slice(lastColon + 1));
        if(ipv4Value === null) return null;

        const high = Number((ipv4Value >> 16n) & 0xffffn).toString(16);
        const low = Number(ipv4Value & 0xffffn).toString(16);
        address = `${address.slice(0, lastColon)}:${high}:${low}`;
    }

    const compressedParts = address.split('::');
    if(compressedParts.length > 2) return null;

    const left = compressedParts[0] ? compressedParts[0].split(':') : [];
    const right = compressedParts.length === 2 && compressedParts[1] ? compressedParts[1].split(':') : [];
    if(left.includes('') || right.includes('')) return null;

    const missing = 8 - left.length - right.length;
    if((compressedParts.length === 1 && missing !== 0) || missing < 0) return null;

    const groups = [
        ...left,
        ...Array(compressedParts.length === 2 ? missing : 0).fill('0'),
        ...right
    ];
    if(groups.length !== 8) return null;

    let value = 0n;
    for(const group of groups) {
        if(!/^[0-9a-fA-F]{1,4}$/.test(group)) return null;
        value = (value << 16n) + BigInt(parseInt(group, 16));
    }

    return value;
}

function parseIp(ip) {
    const ipv4 = parseIpv4(ip);
    if(ipv4 !== null) return { version: 4, value: ipv4, bits: 32 };

    const ipv6 = parseIpv6(ip);
    if(ipv6 !== null) return { version: 6, value: ipv6, bits: 128 };

    return null;
}

function parseAllowedClientRule(entry) {
    const [rawIp, rawPrefix, extra] = entry.split('/');
    if(extra !== undefined || !rawIp || rawPrefix === '') return null;

    const parsed = parseIp(rawIp);
    if(!parsed) return null;

    const prefix = rawPrefix === undefined ? parsed.bits : Number(rawPrefix);
    if(!Number.isInteger(prefix) || prefix < 0 || prefix > parsed.bits) return null;

    return {
        version: parsed.version,
        value: parsed.value,
        bits: parsed.bits,
        prefix,
        source: entry
    };
}

function isIpAllowed(clientIp) {
    const parsed = parseIp(clientIp);
    if(!parsed) return false;

    return ALLOWED_CLIENT_RULES.some((rule) => {
        if(rule.version !== parsed.version) return false;

        const shift = BigInt(rule.bits - rule.prefix);
        return (parsed.value >> shift) === (rule.value >> shift);
    });
}

const ALLOWED_CLIENT_RULES = RAW_ALLOWED_CLIENT_IPS.map(parseAllowedClientRule);
const invalidAllowedClientRule = ALLOWED_CLIENT_RULES.findIndex((rule) => rule === null);
if(invalidAllowedClientRule !== -1) {
    console.error(`Invalid TERMINAL_ALLOWED_CLIENT_IPS value: ${RAW_ALLOWED_CLIENT_IPS[invalidAllowedClientRule]}`);
    process.exit(1);
}

const activeSessions = new Map();

const ASSETS = new Map([
    ['/assets/xterm.css', {
        file: path.join(__dirname, 'node_modules', '@xterm', 'xterm', 'css', 'xterm.css'),
        contentType: 'text/css; charset=utf-8'
    }],
    ['/assets/xterm.js', {
        file: path.join(__dirname, 'node_modules', '@xterm', 'xterm', 'lib', 'xterm.js'),
        contentType: 'application/javascript; charset=utf-8'
    }],
    ['/assets/addon-fit.js', {
        file: path.join(__dirname, 'node_modules', '@xterm', 'addon-fit', 'lib', 'addon-fit.js'),
        contentType: 'application/javascript; charset=utf-8'
    }]
]);

const BLOCKED_LINUX_USERS = new Set([
    'root',
    'www-data',
    'mysql',
    'mariadb',
    'postgres',
    'redis',
    'clp',
    'daemon',
    'bin',
    'sys',
    'sync',
    'games',
    'man',
    'lp',
    'mail',
    'news',
    'uucp',
    'proxy',
    'backup',
    'list',
    'irc',
    'gnats',
    'nobody',
    'systemd-network',
    'systemd-resolve',
    'messagebus'
]);

function sendJson(ws, payload) {
    if(ws.readyState === ws.OPEN) ws.send(JSON.stringify(payload));
}

function reject(ws, message = 'Unauthorized') {
    sendJson(ws, { type: 'error', message });

    try{
        ws.close(1008, message);
    }catch (error) {
        ws.close();
    }
}

function normalizeClientIp(ip) {
    if(!ip) return '';

    if(ip.startsWith('::ffff:')) {
        return ip.slice(7);
    }

    return ip;
}

function validateClientIp(req) {
    const clientIp = normalizeClientIp(req.socket.remoteAddress);

    if(ALLOWED_CLIENT_RULES.length === 0) {
        return { ok: false, reason: 'No allowed client IPs configured' };
    }

    if(!isIpAllowed(clientIp)) {
        return { ok: false, reason: `IP not allowed: ${clientIp || 'unknown'}` };
    }

    return { ok: true, clientIp };
}

function getCookieValue(cookieHeader, name) {
    if(!cookieHeader) return null;

    const cookies = cookieHeader.split(';');

    for(const cookie of cookies) {
        const [rawName, ...rawValue] = cookie.trim().split('=');
        if(rawName === name) return decodeURIComponent(rawValue.join('='));
    }

    return null;
}

function isSafeSessionId(sessionId) {
    return /^[a-zA-Z0-9,-]{16,128}$/.test(sessionId);
}

function validateCloudPanelSession(req) {
    if(ALLOWED_ORIGIN) {
        const origin = req.headers.origin;

        if(origin !== ALLOWED_ORIGIN) {
            return { ok: false, reason: 'Invalid origin' };
        }
    }

    const sessionId = getCookieValue(req.headers.cookie, SESSION_COOKIE_NAME);

    if(!sessionId) return { ok: false, reason: 'Missing session cookie' };

    if(!isSafeSessionId(sessionId)) return { ok: false, reason: 'Invalid session id' };

    const sessionFile = path.join(SESSION_DIR, `sess_${sessionId}`);

    const normalizedSessionDir = path.resolve(SESSION_DIR);
    const normalizedSessionFile = path.resolve(sessionFile);

    if(!normalizedSessionFile.startsWith(normalizedSessionDir + path.sep)) return  { ok: false, reason: 'Invalid session path' };

    if(!fs.existsSync(normalizedSessionFile)) return { ok: false, reason: 'Session not found' };

    const stat = fs.statSync(normalizedSessionFile);
    const ageSeconds = (Date.now() - stat.mtimeMs) / 1000;

    if(ageSeconds > MAX_SESSION_AGE_SECONDS) return { ok: false, reason: 'Session expired' };

    const content = fs.readFileSync(normalizedSessionFile, 'utf8');

    const hasSecurityToken = content.includes('_security_main') && content.includes('PostAuthenticationToken');
    const isAdmin = content.includes('ROLE_ADMIN');

    if(!hasSecurityToken) return { ok: false, reason: 'Not authenticated' };

    if(!isAdmin) return { ok: false, reason: 'Admin role required' };

    return { ok: true, sessionId };
}

function getUserByUsername(username) {
    let passwd;

    try{
        passwd = fs.readFileSync('/etc/passwd', 'utf8');
    }catch(error) {
        throw new Error('Unable to read user database');
    }

    for(const line of passwd.split('\n')) {
        if(!line.trim()) continue;

        const parts = line.split(':');

        const name = parts[0];
        const userUid = Number(parts[2]);
        const userGid = Number(parts[3]);
        const home = parts[5];
        const shell = parts[6];

        if(name === username) return { username: name, uid: userUid, gid: userGid, home, shell };
    }

    return null;
}

function isSafeLinuxUsername(username) {
    return /^[a-z_][a-z0-9_-]{0,31}$/.test(username);
}

function resolveSite(query) {
    const username = String(query.user || '').trim();

    if(!username || !isSafeLinuxUsername(username)) throw new Error('Invalid username');

    const user = getUserByUsername(username);

    if(!user) throw new Error(`User not found: ${username}`);

    if(BLOCKED_LINUX_USERS.has(user.username)) throw new Error(`Refusing to open terminal as ${user.username}`);

    const cwd = user.home;

    if(!cwd) throw new Error(`Home directory not found for user ${user.username}`);

    let realBaseHome;
    let realCwd;

    try{
        realBaseHome = fs.realpathSync(BASE_HOME);
        realCwd = fs.realpathSync(cwd);
    }catch(error) {
        throw new Error(`Unable to resolve paths: ${error.message}`);
    }

    if(!realCwd.startsWith(realBaseHome + path.sep)) throw new Error('Invalid user home path');

    return { target: user.username, cwd: realCwd, user };
}

function serveAsset(req, res, pathname) {
    const asset = ASSETS.get(pathname);

    if(!asset) return false;

    const ipCheck = validateClientIp(req);

    if(!ipCheck.ok) {
        res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('Forbidden\n');
        return true;
    }

    try{
        const content = fs.readFileSync(asset.file);

        res.writeHead(200, {
            'Content-Type': asset.contentType,
            'Cache-Control': 'public, max-age=31536000, immutable'
        });
        res.end(content);
    }catch(error) {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('Not found\n');
    }

    return true;
}

const server = https.createServer({
    key: fs.readFileSync(path.join(SSL_DIR, 'terminal.key')),
    cert: fs.readFileSync(path.join(SSL_DIR, 'terminal.crt'))
}, (req, res) => {
    const parsedUrl = url.parse(req.url);

    if(serveAsset(req, res, parsedUrl.pathname)) return;

    res.writeHead(200, {
        'Content-Type': 'text/plain; charset=utf-8'
    });

    res.end('CloudPanel Terminal Helper OK\n');
});

const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
    const ipCheck = validateClientIp(req);

    if(!ipCheck.ok) {
        reject(ws, ipCheck.reason);
        return;
    }

    const auth = validateCloudPanelSession(req);

    if(!auth.ok) {
        reject(ws, auth.reason);
        return;
    }

    const sessionId = auth.sessionId;
    const currentCount = activeSessions.get(sessionId) || 0;

    if(currentCount >= MAX_CONCURRENT_SESSIONS) {
        reject(ws, 'Maximum concurrent terminal sessions reached');
        return;
    }

    activeSessions.set(sessionId, currentCount + 1);

    let sessionReleased = false;

    function releaseSession() {
        if(sessionReleased) return;
        sessionReleased = true;

        const newCount = (activeSessions.get(sessionId) || 1) - 1;
        if(newCount <= 0) activeSessions.delete(sessionId);
        else activeSessions.set(sessionId, newCount);
    }

    ws.once('close', releaseSession);
    ws.once('error', releaseSession);

    let site;

    try{
        const parsedUrl = url.parse(req.url, true);
        site = resolveSite(parsedUrl.query);
    }catch (error) {
        releaseSession();
        reject(ws, error.message);
        return;
    }

    sendJson(ws, { type: 'output', data: `Authenticated with CloudPanel session\r\n` });
    sendJson(ws, { type: 'output', data: `Connecting to ${site.target}\r\n` });
    sendJson(ws, { type: 'output', data: `User: ${site.user.username}\r\n` });
    sendJson(ws, { type: 'output', data: `Directory: ${site.cwd}\r\n\r\n`});

    let ptyProcess;

    try{
        ptyProcess = pty.spawn('sudo', [
            '-u',
            site.user.username,
            '-H',
            '--',
            '/bin/bash',
            '-l'
        ], {
            name: 'xterm-256color',
            cols: 80,
            rows: 24,
            cwd: site.cwd,
            env: {
                TERM: 'xterm-256color',
                HOME: site.user.home || site.cwd,
                USER: site.user.username,
                LOGNAME: site.user.username,
                PATH: '/usr/local/bin:/usr/bin:/bin'
            }
        });
    }catch(error) {
        releaseSession();
        reject(ws, `Unable to start terminal: ${error.message}`);
        return;
    }

    ptyProcess.onData((data) => { sendJson(ws, { type: 'output', data }); });

    ptyProcess.onExit(({ exitCode, signal }) => {
        sendJson(ws, { type: 'output', data: `\r\n[terminal closed: exit=${exitCode}, signal=${signal || 'none'}]\r\n` });

        try{
            ws.close();
        }catch(error) {}
    });

    ws.on('message', (rawMessage) => {
        let message;

        try{
            message = JSON.parse(rawMessage.toString());
        }catch(error) {
            return;
        }

        if(message.type === 'input' && typeof message.data === 'string') {
            ptyProcess.write(message.data);
            return;
        }

        if(message.type === 'resize') {
            const cols = Number(message.cols);
            const rows = Number(message.rows);

            if(
                Number.isInteger(cols) &&
                Number.isInteger(rows) &&
                cols > 0 &&
                rows > 0 &&
                cols < 300 &&
                rows < 120
            ){
                ptyProcess.resize(cols, rows);
            }
        }
    });

    ws.on('close', () => {
        try{
            ptyProcess.kill();
        }catch(error) {}
    });

    ws.on('error', () => {
        try{
            ptyProcess.kill();
        }catch(error) {}
    });
});

server.listen(PORT, HOST, () => {
    console.log(`CloudPanel Terminal Helper listening on ${HOST}:${PORT}`);
});