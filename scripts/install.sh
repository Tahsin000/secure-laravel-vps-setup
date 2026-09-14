#!/usr/bin/env bash
set -Eeuo pipefail

# Secure Laravel VPS Bootstrap
# Target OS: Ubuntu Server 24.04 LTS or newer with APT-managed PHP >= 8.3.

export DEBIAN_FRONTEND=noninteractive

DOMAIN=""
APP_DIR="/var/www/laravel"
PHP_VERSION="auto"
SSH_PORT="22"
EMAIL=""
ENABLE_SSL="false"
INSTALL_MYSQL="false"
INSTALL_REDIS="false"
SITE_ID=""
AUTO_FELL_BACK_TO_83="false"
INCLUDE_WWW="false"
ALLOW_PHP_PPA="false"
SKIP_DNS_CHECK="false"
SERVER_NAMES=""
DNS_CHECK_PASSED="unknown"
INSTALL_NODE="true"
NODE_MAJOR="22"

log() {
  printf '\n\033[1;32m[+] %s\033[0m\n' "$*"
}

warn() {
  printf '\n\033[1;33m[!] %s\033[0m\n' "$*" >&2
}

die() {
  printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
  exit 1
}

usage() {
  cat <<USAGE
Secure Laravel VPS Bootstrap

Usage:
  sudo bash scripts/install.sh --domain example.com [options]

Required:
  --domain DOMAIN             Domain name pointed to this VPS, e.g. app.example.com

Options:
  --app-dir PATH              Laravel application directory. Default: /var/www/laravel
  --php-version VERSION       PHP version to install. Default: auto, tries 8.4 then 8.3
  --allow-php-ppa             If PHP 8.4 is not in your default APT repos, add the trusted
                               ondrej/php PPA to get it. Off by default (keeps the installer
                               third-party-repo-free unless you opt in).
  --ssh-port PORT             SSH port to keep open in UFW. Default: 22
  --enable-ssl                Install Certbot and request HTTPS certificate with Nginx
  --email EMAIL               Email for Let's Encrypt registration. Required with --enable-ssl
  --include-www               Also configure and (with --enable-ssl) certify www.DOMAIN.
                               Only use this if www.DOMAIN already has its own DNS A record.
  --install-mysql             Install MySQL server locally. MySQL port is NOT opened in UFW
  --install-redis             Install Redis locally and bind it to localhost only
  --node-version MAJOR        Node.js major version to install via NodeSource. Default: 22
  --skip-node                 Do not install Node.js/npm. On by default it IS installed, since
                               React/Vue/Vite front-end scaffolding needs it to build assets.
  --skip-dns-check            Skip the pre-flight check that DOMAIN resolves to this server.
                               Not recommended: with --enable-ssl, Certbot will fail anyway if
                               DNS is not propagated yet.
  -h, --help                  Show this help

Prerequisite: point DOMAIN's DNS A record (and the AAAA record if you use IPv6) at this
server's public IP BEFORE running this script, then wait for it to propagate. The installer
checks this for you and will refuse to request SSL for a domain that does not resolve here yet.

Examples:
  sudo bash scripts/install.sh --domain example.com --app-dir /var/www/example.com
  sudo bash scripts/install.sh --domain example.com --enable-ssl --email admin@example.com
  sudo bash scripts/install.sh --domain example.com --enable-ssl --email admin@example.com --include-www
  sudo bash scripts/install.sh --domain example.com --php-version 8.4 --allow-php-ppa
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root with sudo."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="${2:-}"; shift 2 ;;
      --app-dir)
        APP_DIR="${2:-}"; shift 2 ;;
      --php-version)
        PHP_VERSION="${2:-}"; shift 2 ;;
      --ssh-port)
        SSH_PORT="${2:-}"; shift 2 ;;
      --enable-ssl)
        ENABLE_SSL="true"; shift ;;
      --email)
        EMAIL="${2:-}"; shift 2 ;;
      --install-mysql)
        INSTALL_MYSQL="true"; shift ;;
      --install-redis)
        INSTALL_REDIS="true"; shift ;;
      --include-www)
        INCLUDE_WWW="true"; shift ;;
      --node-version)
        NODE_MAJOR="${2:-}"; shift 2 ;;
      --skip-node)
        INSTALL_NODE="false"; shift ;;
      --allow-php-ppa)
        ALLOW_PHP_PPA="true"; shift ;;
      --skip-dns-check)
        SKIP_DNS_CHECK="true"; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown option: $1" ;;
    esac
  done
}

validate_input() {
  [[ -n "${DOMAIN}" ]] || die "--domain is required."
  [[ "${DOMAIN}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Invalid domain: ${DOMAIN}"
  [[ "${APP_DIR}" == /var/www/* ]] || die "For safety, --app-dir must be inside /var/www/."
  [[ "${APP_DIR}" != *".."* ]] || die "Invalid --app-dir path."
  [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "--ssh-port must be a number."
  (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "--ssh-port must be between 1 and 65535."
  if [[ "${ENABLE_SSL}" == "true" && -z "${EMAIL}" ]]; then
    die "--email is required when --enable-ssl is used."
  fi
  if [[ -n "${EMAIL}" ]]; then
    [[ "${EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Invalid email: ${EMAIL}"
  fi
  if [[ "${INSTALL_NODE}" == "true" ]]; then
    [[ "${NODE_MAJOR}" =~ ^[0-9]+$ ]] || die "--node-version must be a Node.js major version number, e.g. 20 or 22."
  fi
  SITE_ID="$(printf '%s' "${DOMAIN}" | sed 's/[^A-Za-z0-9._-]/_/g')"

  SERVER_NAMES="${DOMAIN}"
  if [[ "${INCLUDE_WWW}" == "true" ]]; then
    SERVER_NAMES="${DOMAIN} www.${DOMAIN}"
  fi
}

check_os() {
  [[ -r /etc/os-release ]] || die "Cannot detect OS. This script requires Ubuntu with apt."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Unsupported OS: ${PRETTY_NAME:-unknown}. Use Ubuntu Server 24.04 LTS or newer."
  command -v apt-get >/dev/null 2>&1 || die "apt-get is required."
}

apt_update_once() {
  log "Updating APT package index"
  apt-get update -y
}

ensure_curl() {
  command -v curl >/dev/null 2>&1 || apt-get install -y curl ca-certificates
}

resolve_domain_ip() {
  local host="$1"
  getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | head -n1
}

detect_public_ip() {
  local ip url
  for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip="$(curl -fsSL --max-time 5 "${url}" 2>/dev/null | tr -d '[:space:]')" || true
    if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "${ip}"
      return 0
    fi
  done
  return 1
}

check_dns_propagation() {
  if [[ "${SKIP_DNS_CHECK}" == "true" ]]; then
    warn "Skipping DNS propagation check (--skip-dns-check). SSL requests will fail if DNS is not actually live."
    DNS_CHECK_PASSED="skipped"
    return
  fi

  log "Checking that ${DOMAIN} resolves to this server before touching Nginx/SSL"
  ensure_curl

  local public_ip resolved_ip
  public_ip="$(detect_public_ip || true)"
  if [[ -z "${public_ip}" ]]; then
    warn "Could not determine this server's public IP (outbound HTTPS to IP-lookup services may be blocked). Skipping automated DNS check."
    DNS_CHECK_PASSED="unknown"
    return
  fi

  resolved_ip="$(resolve_domain_ip "${DOMAIN}")" || true

  if [[ -z "${resolved_ip}" ]]; then
    DNS_CHECK_PASSED="false"
    warn "${DOMAIN} does not resolve yet (no A record found from this server)."
    if [[ "${ENABLE_SSL}" == "true" ]]; then
      die "Refusing to request SSL for ${DOMAIN}: DNS has not propagated. Point the A record to ${public_ip}, wait for it to propagate (check with: dig +short ${DOMAIN}), then re-run. Use --skip-dns-check to override at your own risk."
    fi
    warn "Continuing without SSL. Nginx/PHP will still be set up, but the site will not be reachable by domain until DNS propagates."
    return
  fi

  if [[ "${resolved_ip}" != "${public_ip}" ]]; then
    DNS_CHECK_PASSED="false"
    warn "${DOMAIN} currently resolves to ${resolved_ip}, but this server's public IP is ${public_ip}."
    if [[ "${ENABLE_SSL}" == "true" ]]; then
      die "Refusing to request SSL for ${DOMAIN}: DNS points somewhere else. Fix the A record, wait for propagation, then re-run. Use --skip-dns-check to override at your own risk."
    fi
    warn "Continuing without SSL. Fix the A record before enabling SSL."
    return
  fi

  if [[ "${INCLUDE_WWW}" == "true" ]]; then
    local www_resolved_ip
    www_resolved_ip="$(resolve_domain_ip "www.${DOMAIN}")" || true
    if [[ -z "${www_resolved_ip}" || "${www_resolved_ip}" != "${public_ip}" ]]; then
      if [[ "${ENABLE_SSL}" == "true" ]]; then
        die "Refusing to request SSL for www.${DOMAIN}: it does not resolve to ${public_ip} yet. Add/fix the www A record, wait for propagation, then re-run (or drop --include-www)."
      fi
      warn "www.${DOMAIN} does not resolve to ${public_ip} yet. Nginx will still accept it, but add/fix its A record before requesting SSL for it."
    fi
  fi

  DNS_CHECK_PASSED="true"
  log "${DOMAIN} correctly resolves to this server (${public_ip})."
}

warn_if_hsts_preload_tld() {
  local tld="${DOMAIN##*.}"
  case "${tld}" in
    app|dev|page|new|foo|gle|prod)
      if [[ "${ENABLE_SSL}" != "true" ]]; then
        warn ".${tld} domains are on browsers' built-in HSTS preload list: browsers refuse plain HTTP and will show a connection error until HTTPS is live. Re-run with --enable-ssl --email you@example.com once DNS has propagated, or your site will look 'down' over HTTP even though Nginx is fine."
      fi
      ;;
  esac
}

package_available() {
  local package="$1"
  apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vq '(none)'
}

add_php_ppa() {
  log "PHP 8.4 is not in your default APT repositories. Adding the trusted ondrej/php PPA (--allow-php-ppa)"
  apt-get install -y software-properties-common gnupg ca-certificates
  add-apt-repository -y ppa:ondrej/php
  apt-get update -y
}

select_php_version() {
  if [[ "${PHP_VERSION}" != "auto" ]]; then
    [[ "${PHP_VERSION}" =~ ^8\.[3-9]$ ]] || die "PHP version must be 8.3 or newer, e.g. 8.3 or 8.4."
    if ! package_available "php${PHP_VERSION}-fpm"; then
      if [[ "${PHP_VERSION}" == "8.4" && "${ALLOW_PHP_PPA}" == "true" ]]; then
        add_php_ppa
        package_available "php${PHP_VERSION}-fpm" || die "php${PHP_VERSION}-fpm is still unavailable even after adding ondrej/php. Check the PPA is reachable from this server."
      else
        die "php${PHP_VERSION}-fpm is not available from your current APT repositories. Re-run with --allow-php-ppa to add the trusted ondrej/php PPA and get PHP 8.4, or use Ubuntu 24.10+/a supported PHP version."
      fi
    fi
    return
  fi

  local candidate
  for candidate in 8.4 8.3; do
    if package_available "php${candidate}-fpm"; then
      PHP_VERSION="${candidate}"
      log "Selected PHP ${PHP_VERSION} from Ubuntu repositories"
      if [[ "${candidate}" == "8.3" ]]; then
        AUTO_FELL_BACK_TO_83="true"
      fi
      return
    fi
  done

  if [[ "${ALLOW_PHP_PPA}" == "true" ]]; then
    add_php_ppa
    if package_available "php8.4-fpm"; then
      PHP_VERSION="8.4"
      log "Selected PHP 8.4 from ondrej/php after adding the PPA"
      return
    fi
  fi

  die "No APT-managed PHP >= 8.3 package was found. Use Ubuntu 24.04+, or re-run with --allow-php-ppa to add the trusted ondrej/php PPA."
}

install_base_packages() {
  log "Installing base server packages"
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    fail2ban \
    git \
    gnupg \
    lsb-release \
    nginx \
    software-properties-common \
    supervisor \
    ufw \
    unattended-upgrades \
    unzip
}

install_php_packages() {
  log "Installing PHP ${PHP_VERSION}, PHP-FPM, and Laravel-ready extensions"
  apt-get install -y \
    "php${PHP_VERSION}-bcmath" \
    "php${PHP_VERSION}-cli" \
    "php${PHP_VERSION}-common" \
    "php${PHP_VERSION}-curl" \
    "php${PHP_VERSION}-fpm" \
    "php${PHP_VERSION}-gd" \
    "php${PHP_VERSION}-intl" \
    "php${PHP_VERSION}-mbstring" \
    "php${PHP_VERSION}-mysql" \
    "php${PHP_VERSION}-opcache" \
    "php${PHP_VERSION}-readline" \
    "php${PHP_VERSION}-redis" \
    "php${PHP_VERSION}-sqlite3" \
    "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-zip"
}

install_optional_datastores() {
  if [[ "${INSTALL_MYSQL}" == "true" ]]; then
    log "Installing MySQL server for local-only database usage"
    apt-get install -y mysql-server
    systemctl enable --now mysql
  fi

  if [[ "${INSTALL_REDIS}" == "true" ]]; then
    log "Installing and hardening Redis for localhost-only usage"
    apt-get install -y redis-server
    if [[ -f /etc/redis/redis.conf ]]; then
      sed -i 's/^#\? *bind .*/bind 127.0.0.1 ::1/' /etc/redis/redis.conf
      sed -i 's/^#\? *protected-mode .*/protected-mode yes/' /etc/redis/redis.conf
      sed -i 's/^#\? *supervised .*/supervised systemd/' /etc/redis/redis.conf
    fi
    systemctl enable --now redis-server
    systemctl restart redis-server
  fi
}

install_composer() {
  if command -v composer >/dev/null 2>&1; then
    log "Composer is already installed: $(composer --version --no-ansi 2>/dev/null || true)"
    return
  fi

  log "Installing Composer with installer checksum verification"
  local installer="/tmp/composer-setup.php"
  local expected actual
  expected="$(curl -fsSL https://composer.github.io/installer.sig)"
  curl -fsSL https://getcomposer.org/installer -o "${installer}"
  actual="$(php -r "echo hash_file('sha384', '${installer}');")"

  if [[ "${expected}" != "${actual}" ]]; then
    rm -f "${installer}"
    die "Composer installer checksum verification failed."
  fi

  php "${installer}" --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f "${installer}"
  composer --version --no-ansi
}

install_nodejs() {
  if [[ "${INSTALL_NODE}" != "true" ]]; then
    warn "Skipping Node.js installation (--skip-node). React/Vue/Vite asset builds will need Node installed manually."
    return
  fi

  if command -v node >/dev/null 2>&1; then
    local installed_major
    installed_major="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
    if [[ "${installed_major}" == "${NODE_MAJOR}" ]]; then
      log "Node.js ${NODE_MAJOR}.x is already installed: $(node -v)"
      return
    fi
    warn "Node.js $(node -v) is already installed (major v${installed_major}), not the requested ${NODE_MAJOR}.x. Leaving it as-is to avoid breaking an existing setup. Pass --node-version ${installed_major} to match it, or upgrade manually if you need ${NODE_MAJOR}.x."
    return
  fi

  log "Installing Node.js ${NODE_MAJOR}.x and npm from the official NodeSource APT repository"
  apt-get install -y ca-certificates curl gnupg
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  chmod 0644 /etc/apt/keyrings/nodesource.gpg
  printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' "${NODE_MAJOR}" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -y
  apt-get install -y nodejs

  log "Installed Node.js $(node -v), npm $(npm -v)"
}

configure_php() {
  log "Applying PHP-FPM security and production settings"
  local ini_content
  read -r -d '' ini_content <<PHPINI || true
expose_php = Off
cgi.fix_pathinfo = 0
display_errors = Off
log_errors = On
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 120
opcache.enable = 1
opcache.enable_cli = 0
opcache.validate_timestamps = 0
realpath_cache_size = 4096K
realpath_cache_ttl = 600
PHPINI

  printf '%s\n' "${ini_content}" > "/etc/php/${PHP_VERSION}/fpm/conf.d/99-laravel-production.ini"
  printf '%s\n' "${ini_content}" > "/etc/php/${PHP_VERSION}/cli/conf.d/99-laravel-production.ini"
  systemctl enable --now "php${PHP_VERSION}-fpm"
  systemctl restart "php${PHP_VERSION}-fpm"
}

configure_app_directory() {
  log "Preparing Laravel application directory at ${APP_DIR}"
  install -d -m 0755 -o root -g root "${APP_DIR}"
  install -d -m 0755 -o root -g root "${APP_DIR}/public"
  install -d -m 0775 -o www-data -g www-data "${APP_DIR}/storage"
  install -d -m 0775 -o www-data -g www-data "${APP_DIR}/bootstrap/cache"

  if [[ ! -f "${APP_DIR}/public/index.php" && ! -f "${APP_DIR}/public/index.html" ]]; then
    cat > "${APP_DIR}/public/index.html" <<PLACEHOLDER
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Laravel VPS Ready</title></head>
<body><h1>Laravel VPS environment is ready.</h1><p>Deploy your Laravel project to ${APP_DIR}.</p></body>
</html>
PLACEHOLDER
    chown root:root "${APP_DIR}/public/index.html"
    chmod 0644 "${APP_DIR}/public/index.html"
  fi
}

configure_nginx() {
  log "Configuring Nginx virtual host for ${DOMAIN}"
  cat > /etc/nginx/conf.d/00-security-baseline.conf <<'NGINXSECURITY'
server_tokens off;
NGINXSECURITY

  cat > "/etc/nginx/sites-available/${SITE_ID}.conf" <<NGINXCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};

    root ${APP_DIR}/public;
    index index.php index.html;

    charset utf-8;
    client_max_body_size 64M;

    access_log /var/log/nginx/${SITE_ID}-access.log;
    error_log  /var/log/nginx/${SITE_ID}-error.log warn;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\. {
        deny all;
    }

    location ~* /(\.env|\.git|composer\.(json|lock)|package(-lock)?\.json|vite\.config\.|webpack\.mix\.|phpunit\.xml|server\.php) {
        deny all;
    }
}
NGINXCONF

  ln -sfn "/etc/nginx/sites-available/${SITE_ID}.conf" "/etc/nginx/sites-enabled/${SITE_ID}.conf"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

configure_firewall() {
  log "Configuring UFW firewall: deny incoming by default, allow SSH/HTTP/HTTPS only"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment 'SSH access'
  ufw allow 80/tcp comment 'HTTP for Nginx and ACME challenge'
  ufw allow 443/tcp comment 'HTTPS for Nginx'
  ufw --force enable
  ufw status verbose
}

configure_fail2ban() {
  log "Configuring Fail2ban for SSH and Nginx abuse protection"
  cat > /etc/fail2ban/jail.d/laravel-vps.local <<FAIL2BAN
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
FAIL2BAN

  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

configure_unattended_upgrades() {
  log "Enabling unattended security upgrades"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTCONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APTCONF
}

configure_sysctl() {
  log "Applying conservative kernel network hardening"
  cat > /etc/sysctl.d/99-laravel-vps-hardening.conf <<'SYSCTL'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
SYSCTL
  sysctl --system >/dev/null
}

write_supervisor_template() {
  log "Writing disabled Supervisor template for Laravel queue workers"
  # Named after SITE_ID (derived from --domain), not a fixed "laravel-worker"
  # name: on a droplet running install.sh for more than one domain, a fixed
  # name would make each re-run overwrite the previous domain's template/
  # program name instead of adding its own.
  cat > "/etc/supervisor/conf.d/laravel-worker-${SITE_ID}.conf.example" <<SUPERVISOR
[program:laravel-worker-${SITE_ID}]
process_name=%(program_name)s_%(process_num)02d
command=php ${APP_DIR}/artisan queue:work --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/worker.log
stopwaitsecs=3600
SUPERVISOR
  systemctl enable --now supervisor
  systemctl restart supervisor
}

install_ssl_certificate() {
  if [[ "${ENABLE_SSL}" != "true" ]]; then
    warn "SSL was not requested. Run again with --enable-ssl --email you@example.com after DNS points to this server."
    return
  fi

  log "Installing Certbot via Snap and requesting HTTPS certificate"
  apt-get install -y snapd
  systemctl enable --now snapd.socket
  snap install core >/dev/null 2>&1 || snap refresh core
  snap install --classic certbot
  ln -sfn /snap/bin/certbot /usr/bin/certbot

  local certbot_domain_args=(-d "${DOMAIN}")
  if [[ "${INCLUDE_WWW}" == "true" ]]; then
    certbot_domain_args+=(-d "www.${DOMAIN}")
  fi

  # Note for multi-domain droplets: if you already ran this script for another
  # site on the same server, do NOT create this site's Nginx vhost by copying
  # a previous SSL-enabled vhost file. Certbot writes "listen [::]:443 ssl
  # ipv6only=on;" into each vhost, and ipv6only=on may only appear once across
  # the whole server - copying an existing vhost duplicates it and nginx -t
  # fails with "duplicate listen options". Let this script and Certbot
  # generate each site's config independently instead.
  certbot --nginx \
    "${certbot_domain_args[@]}" \
    --cert-name "${DOMAIN}" \
    --expand \
    --agree-tos \
    --email "${EMAIL}" \
    --redirect \
    --no-eff-email \
    --non-interactive

  systemctl reload nginx
  certbot renew --dry-run
}

print_summary() {
  cat <<SUMMARY

============================================================
Secure Laravel VPS bootstrap completed.
============================================================
Domain:      ${DOMAIN}
App path:    ${APP_DIR}
Web root:    ${APP_DIR}/public
PHP-FPM:     PHP ${PHP_VERSION}
Node.js:     ${INSTALL_NODE} $([[ "${INSTALL_NODE}" == "true" ]] && command -v node >/dev/null 2>&1 && node -v || true)
Nginx site:  /etc/nginx/sites-available/${SITE_ID}.conf
Worker tmpl: /etc/supervisor/conf.d/laravel-worker-${SITE_ID}.conf.example
Firewall:    UFW enabled; inbound default deny; allowed ${SSH_PORT}/tcp, 80/tcp, 443/tcp
SSL:         ${ENABLE_SSL}
DNS check:   ${DNS_CHECK_PASSED}
MySQL:       ${INSTALL_MYSQL}
Redis:       ${INSTALL_REDIS}

Next deployment steps:
  1. Upload or git clone your Laravel project into ${APP_DIR}.
  2. Run: cd ${APP_DIR} && composer install --no-dev --optimize-autoloader
  3. Create .env safely and run: php artisan key:generate
  4. Re-apply Laravel writable permissions:
     sudo bash scripts/fix-permissions.sh --app-dir ${APP_DIR}
  5. Reload services:
     sudo systemctl reload nginx
     sudo systemctl restart php${PHP_VERSION}-fpm

Use scripts/verify.sh to review service status and exposed ports.

Adding another domain or subdomain on this same server later? Re-run this
script again with a different --domain and --app-dir (e.g. a subdomain like
--domain app.${DOMAIN} --app-dir /var/www/app.${DOMAIN}). Each run only
touches its own app directory, Nginx site, and certificate; server-wide
pieces (firewall, PHP-FPM, Node.js, MySQL/Redis) are safely re-applied, not
duplicated. See README: "Multiple domains and subdomains on one droplet".
SUMMARY

  if [[ "${AUTO_FELL_BACK_TO_83}" == "true" ]]; then
    cat <<NOTE

Compatibility note:
  - Auto mode selected PHP 8.3 because PHP 8.4 was not available from current APT repositories.
  - Some Laravel 13 lockfiles resolve Symfony 8 packages that require PHP >= 8.4.
  - If 'composer install' fails with 'symfony/* requires php >=8.4', re-run this installer with:
      --php-version 8.4 --allow-php-ppa
    to add the trusted ondrej/php PPA and get PHP 8.4.
NOTE
  fi

  if [[ "${DNS_CHECK_PASSED}" == "false" ]]; then
    cat <<DNSNOTE

DNS note:
  - ${DOMAIN} did not resolve to this server's public IP during setup.
  - Nginx/PHP are configured, but the site will not be reachable by domain
    (and SSL cannot be issued) until DNS propagates.
  - Check with: dig +short ${DOMAIN}
  - Once it matches this server's IP, re-run with --enable-ssl --email you@example.com.
DNSNOTE
  fi
}

main() {
  require_root
  parse_args "$@"
  validate_input
  warn_if_hsts_preload_tld
  check_os
  apt_update_once
  check_dns_propagation
  select_php_version
  install_base_packages
  install_php_packages
  install_optional_datastores
  install_composer
  install_nodejs
  configure_php
  configure_app_directory
  configure_nginx
  configure_firewall
  configure_fail2ban
  configure_unattended_upgrades
  configure_sysctl
  write_supervisor_template
  install_ssl_certificate
  print_summary
}

main "$@"
