# Secure Laravel VPS Bootstrap

A security-first Bash bootstrap for preparing a fresh Ubuntu VPS for a Laravel application with Nginx, PHP-FPM, Composer, UFW, Fail2ban, Supervisor, and optional HTTPS via Certbot.

Recommended repository name:

```text
secure-laravel-vps-bootstrap
```

## What this repository does

This repository gives you a repeatable one-command workflow for a fresh VPS. It prepares the server so that you can later place your Laravel project inside `/var/www/<project>` and serve it through Nginx with PHP-FPM.

The installer is intentionally conservative:

- It uses Ubuntu APT packages for PHP 8.3+ instead of silently adding third-party repositories, unless you explicitly opt in with `--allow-php-ppa` to get PHP 8.4.
- It checks that your domain's DNS already resolves to the server before touching Nginx/SSL, and refuses to request a certificate for a domain that isn't live yet instead of letting Certbot fail with a confusing error.
- It installs Node.js + npm by default (from the official signed NodeSource repo, no `curl | bash`), so React/Vue/Vite front-end scaffolding builds work without extra setup. Skip with `--skip-node`.
- It enables UFW with `deny incoming` as the default policy.
- It opens only SSH, HTTP, and HTTPS ports.
- It does not expose MySQL or Redis to the public internet.
- It configures Nginx to serve only the Laravel `public` directory.
- It blocks access to hidden files and sensitive project files such as `.env`, `.git`, `composer.lock`, and build configuration files.
- It verifies the Composer installer checksum before installing Composer.

## Folder structure

```text
secure-laravel-vps-bootstrap/
├── README.md
├── SECURITY.md
├── .gitignore
├── scripts/
│   ├── install.sh
│   ├── fix-permissions.sh
│   └── verify.sh
└── config/
    ├── fail2ban/
    │   └── laravel-vps.local
    ├── nginx/
    │   └── laravel-site.conf.template
    ├── php/
    │   └── laravel-production.ini
    └── supervisor/
        └── laravel-worker.conf.example
```

## Supported server

Use a fresh Ubuntu Server VPS, preferably Ubuntu 24.04 LTS or newer.

Laravel currently requires PHP 8.3 or newer for the latest major documentation line. This script therefore installs PHP 8.3+ only. If your Ubuntu repositories do not provide PHP 8.3 or PHP 8.4, the installer stops instead of adding an unreviewed third-party package source.

## Before running

1. **Point your domain's DNS `A` record to the VPS public IP address, then wait for it to propagate before you run the script.** This is the single most common source of setup failures — see [Prerequisite: DNS must be live first](#prerequisite-dns-must-be-live-first) below. `install.sh` checks this itself and will refuse to request SSL for a domain that does not resolve here yet, but Nginx/site setup still runs so you can prepare the server while waiting.
2. SSH into the VPS as a sudo-capable user.
3. Confirm your real SSH port. The default is `22`. If your VPS uses another SSH port, pass it with `--ssh-port` or you may lock yourself out when UFW is enabled.
4. Clone this repository and inspect the script before running it.

Do not run random `curl | bash` commands on a production server. Clone, review, then execute.

### Prerequisite: DNS must be live first

Before running `install.sh` (and definitely before `--enable-ssl`):

1. In your domain registrar / DNS provider, create an `A` record for your domain pointing at the VPS's public IPv4 address. If you also want `www.example.com` to work, add a second `A` record for `www` pointing at the same IP, and pass `--include-www` to the installer.
2. Wait for propagation. This can take anywhere from a couple of minutes to a few hours (rarely up to 48h). Check it from your own machine or the VPS:
   ```bash
   dig +short example.com
   dig +short www.example.com   # if you're using www
   ```
   The output must match your VPS's public IP. You can also use a checker like [intoDNS](https://intodns.com/) or [whatsmydns.net](https://www.whatsmydns.net/).
3. Only run `install.sh --enable-ssl ...` once the domain resolves correctly. The installer performs this same check automatically (`check_dns_propagation`) and will `die` with a clear message instead of letting Certbot fail with a confusing error if DNS is not ready. You can force past this with `--skip-dns-check`, but Certbot will simply fail on its own if DNS truly isn't live yet.

**Why this matters, from real-world testing:** modern TLDs like `.app`, `.dev`, `.page`, and `.new` are on browsers' built-in HSTS preload list. Browsers refuse to even attempt plain HTTP for these domains — you'll see `ERR_CONNECTION_REFUSED` or a broken-security warning even though Nginx and DNS are both working fine. If your domain is one of these, you effectively must run with `--enable-ssl` from the start (once DNS is live) rather than testing over `http://`. `install.sh` now detects this and warns you (`warn_if_hsts_preload_tld`) if you didn't pass `--enable-ssl` for such a domain.

## Quick start

Replace the GitHub URL with your own repository URL after you push this project.

```bash
git clone https://github.com/Tahsin000/secure-laravel-vps-bootstrap.git
cd secure-laravel-vps-bootstrap
sudo bash scripts/install.sh --domain example.com --app-dir /var/www/example.com
```

With HTTPS enabled:

```bash
git clone https://github.com/Tahsin000/secure-laravel-vps-bootstrap.git
cd secure-laravel-vps-bootstrap
sudo bash scripts/install.sh \
  --domain example.com \
  --app-dir /var/www/example.com \
  --enable-ssl \
  --email admin@example.com
```

If your SSH port is not `22`:

```bash
sudo bash scripts/install.sh \
  --domain example.com \
  --app-dir /var/www/example.com \
  --ssh-port 2222
```

Optional local MySQL and Redis:

```bash
sudo bash scripts/install.sh \
  --domain example.com \
  --app-dir /var/www/example.com \
  --install-mysql \
  --install-redis
```

## Full setup checklist, in order

The short version. Do these in order; each links to the section with the actual commands.

1. **Buy/point the domain.** Create an `A` record → this VPS's public IP (and a `www` `A` record too if you want `www.example.com`). → [Prerequisite: DNS must be live first](#prerequisite-dns-must-be-live-first)
2. **Wait for DNS to propagate.** Confirm with `dig +short example.com` before continuing — don't skip this, it's the #1 cause of setup failures.
3. **SSH in, clone this repo.** → [Quick start](#quick-start)
4. **Run `install.sh` once per server**, with `--enable-ssl --email you@example.com` if DNS is confirmed (add `--include-www` if you set up `www`, `--allow-php-ppa` if you need PHP 8.4). This also installs Node.js/npm automatically. → [Step-by-step execution flow](#step-by-step-execution-flow-after-clone-or-pull-on-vps)
5. **Deploy your Laravel app** into the app directory `install.sh` prepared: `composer install`, `npm ci && npm run build` if it has a front end, `.env`, `artisan migrate`. → [One-time Laravel app deploy](#2-one-time-laravel-app-deploy-into-the-prepared-app-directory)
6. **Verify.** `sudo bash scripts/verify.sh <php-version>` → [Verification](#verification)
7. **Repeat step 5's regular-deploy commands** for every future release. → [Regular deployment flow](#3-regular-deployment-flow-every-new-app-release)

If something breaks along the way, jump to [Troubleshooting: `symfony/* requires php >=8.4`](#troubleshooting-symfony-requires-php-84) or [Troubleshooting: Certbot, www, and multiple domains](#troubleshooting-certbot-www-and-multiple-domains-on-one-droplet).

## Step-by-step execution flow after clone or pull on VPS

This section is the exact command flow to run after you clone or pull this repository on your VPS.

### Root cause of setup confusion

- The README had quick-start commands and Laravel deployment commands, but not one dedicated execution runbook.
- The old deploy snippet used `git clone ... .` inside `${APP_DIR}` even though `install.sh` already creates files/directories there, so clone can fail with `destination path '.' already exists and is not an empty directory`.
- The flow did not clearly separate one-time server bootstrap from repeat Laravel deployments.

### 1. One-time VPS bootstrap (run once per server)

```bash
cd ~/secure-laravel-vps-bootstrap
git pull --ff-only

sudo bash scripts/install.sh \
  --domain example.com \
  --app-dir /var/www/example.com \
  --php-version auto \
  --ssh-port 22
```

With HTTPS:

```bash
sudo bash scripts/install.sh \
  --domain example.com \
  --app-dir /var/www/example.com \
  --php-version auto \
  --ssh-port 22 \
  --enable-ssl \
  --email admin@example.com
```

### 2. One-time Laravel app deploy into the prepared app directory

```bash
export APP_DIR=/var/www/example.com
export APP_REPO=https://github.com/your-org/your-laravel-app.git
export PHP_FPM_SERVICE=php8.3-fpm

sudo rm -f "${APP_DIR}/public/index.html"
sudo rm -rf /tmp/laravel-app-src
sudo git clone "${APP_REPO}" /tmp/laravel-app-src
sudo cp -a /tmp/laravel-app-src/. "${APP_DIR}/"
sudo rm -rf /tmp/laravel-app-src

sudo chown -R "$USER":www-data "${APP_DIR}"
cd "${APP_DIR}"

composer install --no-dev --optimize-autoloader

# If your app has a front end (React/Vue/Vite/etc.) - Node.js is installed by
# the bootstrap script already, skip this if your project is API-only.
npm ci
npm run build

cp .env.example .env
php artisan key:generate
php artisan migrate --force
php artisan storage:link
php artisan config:cache
php artisan route:cache
php artisan view:cache

cd ~/secure-laravel-vps-bootstrap
sudo bash scripts/fix-permissions.sh --app-dir "${APP_DIR}"
sudo systemctl reload nginx
sudo systemctl restart "${PHP_FPM_SERVICE}"
```

### 3. Regular deployment flow (every new app release)

```bash
export APP_DIR=/var/www/example.com
export PHP_FPM_SERVICE=php8.3-fpm

cd "${APP_DIR}"
git pull --ff-only
composer install --no-dev --optimize-autoloader
npm ci && npm run build   # skip if your project is API-only
php artisan migrate --force
php artisan optimize
cd ~/secure-laravel-vps-bootstrap
sudo bash scripts/fix-permissions.sh --app-dir "${APP_DIR}"
sudo systemctl reload nginx
sudo systemctl restart "${PHP_FPM_SERVICE}"
```

### 4. When you pull updates to this bootstrap repository later

Re-run `install.sh` with the same options. It is designed to be safely re-applied for package/config alignment.

```bash
cd ~/secure-laravel-vps-bootstrap
git pull --ff-only
sudo bash scripts/install.sh --domain example.com --app-dir /var/www/example.com --ssh-port 22
```

Then verify:

```bash
sudo bash scripts/verify.sh 8.3
```

## Installer options

**Scope matters for re-runs:** `Per-site` options must be set correctly *every* time you run the installer for a given domain/subdomain. `Server-wide` options are read once to configure the whole droplet; on a later run for a *different* domain, keep them identical to your first run (especially `--ssh-port`) or omit them once already applied — see [Multiple domains and subdomains on one droplet](#multiple-domains-and-subdomains-on-one-droplet).

| Option | Scope | Required | Default | Purpose |
|---|---|---:|---|---|
| `--domain example.com` | Per-site | Yes | none | Sets the Nginx `server_name` for the Laravel site. |
| `--app-dir /var/www/example.com` | Per-site | No | `/var/www/laravel` | Directory where the Laravel project will live. Must be inside `/var/www/`. |
| `--enable-ssl` | Per-site | No | disabled | Installs Certbot and requests an HTTPS certificate through the Nginx plugin. Requires DNS to already resolve to this server. |
| `--email admin@example.com` | Per-site | Required with SSL | none | Email used for Let's Encrypt registration and expiry notices. |
| `--include-www` | Per-site | No | disabled | Also adds `www.DOMAIN` to the Nginx `server_name` and (with `--enable-ssl`) to the Certbot certificate. Only use this if `www.DOMAIN` already has its own DNS `A` record. |
| `--skip-dns-check` | Per-site | No | disabled | Skips the pre-flight check that `DOMAIN` resolves to this server. Not recommended — see [Prerequisite: DNS must be live first](#prerequisite-dns-must-be-live-first). |
| `--ssh-port 22` | Server-wide | No | `22` | Keeps your SSH port open when UFW is enabled. **Must match on every re-run** — see the warning below. |
| `--php-version 8.3` | Server-wide | No | `auto` | Installs a specific PHP version. `auto` tries PHP 8.4, then PHP 8.3. Shared by every site using that version. |
| `--allow-php-ppa` | Server-wide | No | disabled | If PHP 8.4 isn't in your default APT repos, adds the trusted `ondrej/php` PPA to get it. Only needed once — see [PHP 8.4 availability](#troubleshooting-symfony-requires-php-84). |
| `--node-version 22` | Server-wide | No | `22` | Node.js major version to install via NodeSource, for `npm run build` (Vite/React/Vue/etc.). Shared by every site. |
| `--skip-node` | Server-wide | No | disabled | Skip Node.js/npm installation. Node.js is installed **by default** so front-end asset builds work out of the box. |
| `--install-mysql` | Server-wide | No | disabled | Installs MySQL locally. The firewall does not open port `3306`. Only needed on the run that first installs it. |
| `--install-redis` | Server-wide | No | disabled | Installs Redis locally and binds it to `127.0.0.1` / `::1`. Only needed on the run that first installs it. |

**Watch out:** `--ssh-port` is a firewall rule, not a per-site setting. If you set a custom port on your first run and forget to pass it again on a later run for another domain, the installer re-applies its *default* (`22`) on top — UFW then has both ports open instead of replacing one with the other. Always pass the same `--ssh-port` every time on a given server.

## What gets installed

Core packages:

```bash
apt-transport-https ca-certificates curl fail2ban git gnupg lsb-release nginx software-properties-common supervisor ufw unattended-upgrades unzip
```

PHP packages:

```bash
php8.x-bcmath php8.x-cli php8.x-common php8.x-curl php8.x-fpm php8.x-gd php8.x-intl php8.x-mbstring php8.x-mysql php8.x-opcache php8.x-readline php8.x-redis php8.x-sqlite3 php8.x-xml php8.x-zip
```

Node.js (installed by default, from the official NodeSource APT repository, for asset builds):

```bash
nodejs   # includes npm
```

Optional packages:

```bash
mysql-server redis-server snapd certbot
```

## Individual command breakdown

This section explains the important commands used by the installer and why each one exists.

| Command | Why it runs |
|---|---|
| `apt-get update -y` | Refreshes the local package index so the VPS installs current packages from configured Ubuntu repositories. |
| `getent ahostsv4 <domain>` + `curl` to an IP-lookup service | Compares the domain's resolved A record against this server's public IP before configuring Nginx/SSL (see [Prerequisite: DNS must be live first](#prerequisite-dns-must-be-live-first)). |
| `add-apt-repository -y ppa:ondrej/php` | Only with `--allow-php-ppa`: adds the trusted ondrej/php PPA so PHP 8.4 can be installed on Ubuntu releases whose default repos only ship 8.3. |
| `curl ... nodesource-repo.gpg.key \| gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg` + `apt-get install -y nodejs` | Adds the official, GPG-signed NodeSource APT repository and installs Node.js + npm (default on, skip with `--skip-node`). No `curl \| bash`; the key is verified by APT like any other signed repo. |
| `apt-get install -y nginx` | Installs Nginx as the public web server. |
| `apt-get install -y php8.x-fpm php8.x-cli ...` | Installs PHP-FPM, CLI PHP, and Laravel-compatible PHP extensions. |
| `apt-get install -y ufw` | Installs the uncomplicated firewall used to restrict inbound traffic. |
| `ufw default deny incoming` | Blocks all inbound connections unless explicitly allowed. |
| `ufw default allow outgoing` | Allows the server to reach package repositories, DNS, APIs, and external services. |
| `ufw allow <ssh-port>/tcp` | Keeps SSH access available after the firewall is enabled. |
| `ufw allow 80/tcp` | Allows HTTP traffic for Nginx and Let's Encrypt ACME HTTP validation. |
| `ufw allow 443/tcp` | Allows HTTPS traffic for production web access. |
| `ufw --force enable` | Enables the firewall without an interactive prompt. |
| `apt-get install -y fail2ban` | Installs brute-force protection for SSH and selected Nginx abuse patterns. |
| `systemctl enable --now fail2ban` | Starts Fail2ban now and enables it after reboot. |
| `systemctl enable --now nginx` | Starts Nginx now and enables it after reboot. |
| `systemctl enable --now php8.x-fpm` | Starts PHP-FPM now and enables it after reboot. |
| `nginx -t` | Validates Nginx configuration before reload, preventing a broken config from being applied. |
| `systemctl reload nginx` | Applies the new Nginx virtual host without a full service stop. |
| `curl -fsSL https://composer.github.io/installer.sig` | Downloads the official Composer installer checksum. |
| `curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php` | Downloads the Composer installer. |
| `php -r "echo hash_file('sha384', '/tmp/composer-setup.php');"` | Calculates the installer hash locally for verification. |
| `php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer` | Installs Composer globally only after checksum verification succeeds. |
| `install -d -m 0755 -o root -g root /var/www/<project>/public` | Creates the web root with safe default ownership and permissions. |
| `install -d -m 0775 -o www-data -g www-data /var/www/<project>/storage` | Creates Laravel's writable storage directory for logs, cache, sessions, and uploads. |
| `install -d -m 0775 -o www-data -g www-data /var/www/<project>/bootstrap/cache` | Creates Laravel's writable bootstrap cache directory. |
| `bash scripts/fix-permissions.sh --app-dir /var/www/<project>` | Re-applies correct writable ownership and mode for `storage` and `bootstrap/cache` after each deployment. |
| `ln -sfn /etc/nginx/sites-available/<site>.conf /etc/nginx/sites-enabled/<site>.conf` | Enables the generated Nginx site. |
| `rm -f /etc/nginx/sites-enabled/default` | Disables the default Nginx site to avoid exposing the placeholder page. |
| `sysctl --system` | Applies conservative kernel network hardening settings. |
| `apt-get install -y unattended-upgrades` | Enables automatic security updates. |
| `snap install --classic certbot` | Installs Certbot using the officially recommended Snap flow when SSL is requested. |
| `certbot --nginx -d example.com --cert-name example.com --expand --redirect` | Requests/updates a certificate and configures Nginx HTTPS redirect automatically. `--cert-name` pins the certificate to a stable name and `--expand` lets a later re-run (e.g. adding `--include-www`) add `www` to the existing certificate instead of failing. |
| `certbot renew --dry-run` | Tests automatic certificate renewal. |

## Nginx security model

The generated Nginx site points to:

```text
/var/www/<project>/public
```

This matters because Laravel's `.env`, `vendor`, `storage`, `bootstrap`, and source files live outside the public web root. Nginx should never serve the whole Laravel project directory.

Additional Nginx protection in this repository:

```nginx
location ~ /\. {
    deny all;
}

location ~* /(\.env|\.git|composer\.(json|lock)|package(-lock)?\.json|vite\.config\.|webpack\.mix\.|phpunit\.xml|server\.php) {
    deny all;
}
```

These rules block common sensitive files even if a deployment mistake places them somewhere reachable.

## Firewall policy

The installer uses this inbound policy:

```text
Default incoming: deny
Default outgoing: allow
Allowed inbound: SSH port, 80/tcp, 443/tcp
```

It does not open these ports:

```text
3306/tcp  MySQL
5432/tcp  PostgreSQL
6379/tcp  Redis
9000/tcp  PHP-FPM
```

PHP-FPM is reached through a Unix socket:

```text
/run/php/php8.x-fpm.sock
```

That avoids exposing PHP-FPM directly to the network.

## Deploying your Laravel project after bootstrap

Use the dedicated runbook in `Step-by-step execution flow after clone or pull on VPS`.

If you ever see Laravel write errors (cache/session/log), run:

```bash
sudo bash scripts/fix-permissions.sh --app-dir /var/www/example.com
```

## Enabling Laravel queue workers

The installer writes a disabled Supervisor example named after your domain, so it doesn't collide with another domain's worker on the same droplet:

```text
/etc/supervisor/conf.d/laravel-worker-<domain>.conf.example
# e.g. for --domain example.com:
/etc/supervisor/conf.d/laravel-worker-example.com.conf.example
```

After your Laravel app is deployed, enable it like this (drop `.example` for the real config name):

```bash
sudo cp /etc/supervisor/conf.d/laravel-worker-example.com.conf.example /etc/supervisor/conf.d/laravel-worker-example.com.conf
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl status
```

## Multiple domains and subdomains on one droplet

**One `install.sh` run = one site.** There is no flag that configures several domains at once — you run the script again for each additional domain or subdomain. This is by design: each site gets its own independent Nginx vhost, folder, and SSL certificate, which is exactly what avoids the Nginx/Certbot config collisions covered in [Troubleshooting: Certbot, www, and multiple domains](#troubleshooting-certbot-www-and-multiple-domains-on-one-droplet).

**Where files go:** whatever you pass to `--app-dir` is the folder your Laravel project lives in — nothing else derives it. Match it to the domain/subdomain so it's obvious which folder belongs to which site:

| You're adding | `--domain` | `--app-dir` |
|---|---|---|
| Main domain | `example.com` | `/var/www/example.com` |
| A subdomain | `app.example.com` | `/var/www/app.example.com` |
| A second, unrelated domain | `other-example.com` | `/var/www/other-example.com` |

A subdomain (`app.example.com`) and a brand-new domain (`other-example.com`) are handled identically by this script — both are just a `--domain` value with an `A` record of their own. There's no special "subdomain mode."

**What's isolated per site vs. shared across the droplet** when you re-run the script for a second domain:

| Isolated per site (safe, independent) | Shared server-wide (configured once, safely re-applied) |
|---|---|
| App folder (`--app-dir`) | Firewall (UFW), Fail2ban, kernel hardening (sysctl) |
| Nginx vhost (`/etc/nginx/sites-available/<domain>.conf`) | PHP-FPM version + Composer |
| SSL certificate (`--cert-name` = the domain) | Node.js/npm |
| Supervisor queue-worker template (named by domain) | MySQL/Redis (if installed) |

### Case study: adding `dev.example.com` next to an already-live `example.com`

Say you already ran this once for the main site:

```bash
sudo bash scripts/install.sh \
  --domain example.com --app-dir /var/www/example.com \
  --ssh-port 22 --enable-ssl --email admin@example.com
```

To add a `dev` subdomain on the *same droplet*, in this order:

1. **DNS first.** Add an `A` record for `dev.example.com` → this droplet's public IP. Wait for it, confirm with `dig +short dev.example.com`.
2. **Re-run the installer**, new `--domain`/`--app-dir`, same `--ssh-port` as before, and skip flags for things already installed (`--install-mysql`, `--allow-php-ppa`, etc. — safe to omit once satisfied):
   ```bash
   cd ~/secure-laravel-vps-bootstrap && git pull --ff-only
   sudo bash scripts/install.sh \
     --domain dev.example.com --app-dir /var/www/dev.example.com \
     --ssh-port 22 --enable-ssl --email admin@example.com
   ```
3. **Deploy the app** into `/var/www/dev.example.com` — same commands as [Regular deployment flow](#3-regular-deployment-flow-every-new-app-release), just pointed at the new folder.
4. **Verify both sites still work**, independently:
   ```bash
   sudo bash scripts/verify.sh 8.3
   curl -I https://example.com
   curl -I https://dev.example.com
   ```

Expected result — nothing from step 1 (`example.com`) got touched:

| | `example.com` | `dev.example.com` |
|---|---|---|
| Folder | `/var/www/example.com` | `/var/www/dev.example.com` |
| Nginx vhost | `sites-available/example.com.conf` | `sites-available/dev.example.com.conf` |
| SSL cert (`--cert-name`) | `example.com` | `dev.example.com` |
| Worker template | `laravel-worker-example.com.conf.example` | `laravel-worker-dev.example.com.conf.example` |

If you're scripting a **repeatable base image**: everything above means the same `install.sh` invocation pattern works unchanged on any fresh droplet — clone the repo, run it once per domain you need, in the order shown in [Full setup checklist](#full-setup-checklist-in-order). No separate "multi-site mode" or image-baking step is needed; the idempotent server-wide setup plus per-site re-runs *is* the repeatable blueprint.

## Verification

Run the verification script after installation:

```bash
sudo bash scripts/verify.sh 8.3
```

It checks:

- OS version
- Service status
- Nginx config validity
- PHP version and modules
- Composer version
- UFW firewall status
- Listening TCP ports

## Troubleshooting: `symfony/* requires php >=8.4`

If `composer install` fails with errors like:

```text
symfony/... requires php >=8.4 -> your php version (8.3.x) does not satisfy that requirement
```

your Laravel app lockfile is targeting Symfony 8 packages, but the VPS is running PHP 8.3.

**Why this happens even though `--php-version auto` tries 8.4 first:** Ubuntu 24.04 LTS's default APT repositories only ship PHP 8.3 — PHP 8.4 is not in the stock `universe` repo on that release, so `auto` silently falls back to 8.3. This is exactly the failure this repo hit in real-world testing on a fresh Ubuntu 24.04 droplet.

Check current PHP:

```bash
php -v
```

Check whether PHP 8.4 is available from your current Ubuntu APT repositories:

```bash
apt-cache policy php8.4-fpm
```

If it shows `(none)` as the candidate, your repos don't have PHP 8.4. Re-run the installer with `--allow-php-ppa` to add the well-known, widely trusted [`ondrej/php`](https://launchpad.net/~ondrej/+archive/ubuntu/php) PPA and install PHP 8.4 from it:

```bash
cd ~/secure-laravel-vps-bootstrap
git pull --ff-only
sudo bash scripts/install.sh \
  --domain example.com \
  --app-dir /var/www/example.com \
  --php-version 8.4 \
  --allow-php-ppa \
  --ssh-port 22
```

(`--allow-php-ppa` is opt-in and off by default, so the installer stays free of third-party repositories unless you explicitly ask for PHP 8.4 this way.)

Then deploy/install dependencies again:

```bash
cd /var/www/example.com
composer install --no-dev --optimize-autoloader
```

If you'd rather not add any third-party repository, use a VPS image that ships `php8.4-*` packages out of the box (e.g. Ubuntu 24.10+), or pin your Laravel app's dependency lockfile to Symfony 7 / versions compatible with PHP 8.3 before deploying.

## Troubleshooting: Certbot, `www`, and multiple domains on one droplet

These are real problems hit while deploying with this repo, and how the installer now avoids or documents them.

**`ERR_CONNECTION_REFUSED` right after DNS propagates, even though Nginx is running.**
Some TLDs (`.app`, `.dev`, `.page`, `.new`, ...) are HSTS-preloaded in every major browser, which refuses plain HTTP for them outright. This isn't a server problem. Confirm DNS is fine (`dig +short example.com`), then run the installer with `--enable-ssl --email you@example.com` — see [Prerequisite: DNS must be live first](#prerequisite-dns-must-be-live-first).

**Certbot secures `example.com` but fails for `www.example.com` with "no entry for that domain".**
This happens when the Nginx vhost's `server_name` only lists the apex domain. Re-run the installer with `--include-www` (only if `www.example.com` has its own `A` record) so both the vhost and the Certbot request cover both names. If you already have a certificate for the apex only, add `www` afterward with:
```bash
sudo certbot --nginx -d example.com -d www.example.com
```

**`nginx: [emerg] duplicate listen options for [::]:443` after adding SSL for a second site on the same server.**
Certbot writes `listen [::]:443 ssl ipv6only=on;` into the vhost it edits, and `ipv6only=on` is only valid once, server-wide. This breaks if a second site's Nginx config was created by copying an already-SSL-enabled vhost file (which carries that line over). Don't copy vhosts between sites — re-run `scripts/install.sh` with the new `--domain`/`--app-dir` to generate that site's vhost independently, then run Certbot for it. If you already copied a file, comment out its `listen ... ssl`, `ssl_certificate*`, and `include .../options-ssl-nginx.conf` lines first, run `nginx -t`, then let Certbot re-add them.

**`Certificate already exists` when re-running Certbot for a domain.**
Certbot already issued and saved a certificate for that name; you don't need a new one, just install it:
```bash
sudo certbot install --cert-name example.com --nginx
```

## Production notes

- Create a non-root deploy user for routine deployments.
- Keep `.env` out of Git.
- Use strong database passwords.
- Use SSH keys instead of password SSH login.
- Do not expose database, Redis, or PHP-FPM ports publicly.
- Keep backups before running migrations.
- Review `/var/log/nginx/`, `/var/log/fail2ban.log`, and Laravel logs regularly.

## References

- Laravel deployment requirements: `https://laravel.com/docs/13.x/deployment`
- Laravel installation notes for Composer and Node/NPM or Bun: `https://laravel.com/docs/13.x/installation`
- Certbot Nginx instructions: `https://certbot.eff.org/instructions`
