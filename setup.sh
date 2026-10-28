#!/usr/bin/env bash
set -Eeuo pipefail

readonly ORO_VERSION=7.0.4
readonly APP_DIR=/var/www/orocommerce

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

usage() {
    cat <<'EOF'
Usage: sudo bash setup.sh --domain shop.example.com --email admin@example.com [--ssh-port 22]

Install OroCommerce 7.0.4 Community Edition on a fresh Ubuntu 26.04 server.
Public DNS and inbound ports 80/443 must be ready. Keep your SSH session open.
Prompts for a new oro-admin Linux password and Oro administrator details.
Accepts Let's Encrypt's terms; outgoing application email is initially disabled.
Existing installations are refused. This is not an upgrade or resume script.
EOF
}

validate_inputs() {
    local label
    [[ ${#DOMAIN} -le 253 && $DOMAIN == *.* && $DOMAIN != *..* ]] || die 'Use a public DNS hostname.'
    [[ $DOMAIN =~ ^[a-z0-9.-]+$ && $DOMAIN != .* && $DOMAIN != *. ]] || die 'Invalid domain; use lowercase DNS labels.'
    local -a labels
    IFS=. read -r -a labels <<< "$DOMAIN"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die 'Invalid DNS label.'
    done
    [[ ${labels[-1]} =~ ^[a-z][a-z0-9-]*$ ]] || die 'Use a DNS hostname, not an IP address.'
    [[ $EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die 'Invalid certificate email address.'
    [[ $SSH_PORT =~ ^[0-9]{1,5}$ ]] || die 'SSH port must be a number from 1 to 65535.'
    SSH_PORT=$((10#$SSH_PORT))
    (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die 'SSH port must be from 1 to 65535.'
}

check_fresh_server() {
    local path
    for path in "$APP_DIR" /etc/php/8.5/mods-available/orocommerce.ini \
        /etc/php/8.5/fpm/pool.d/orocommerce.conf /etc/nginx/sites-available/orocommerce \
        /etc/nginx/sites-enabled/orocommerce /etc/systemd/system/oro-consumer.service \
        /etc/systemd/system/oro-websocket.service /etc/cron.d/orocommerce \
        /etc/logrotate.d/orocommerce /etc/letsencrypt/renewal-hooks/deploy/orocommerce-reload-nginx \
        "/etc/letsencrypt/live/$DOMAIN"; do
        [[ ! -e $path && ! -L $path ]] || die "Already exists: $path. Use the README for manual recovery."
    done
    ! id oro &>/dev/null || die 'User oro already exists; use a fresh server.'
    ! getent group oro >/dev/null || die 'Group oro already exists; use a fresh server.'
}

as_oro() {
    sudo -H -u oro env ORO_ENV=prod ORO_DEBUG=0 COMPOSER_PROCESS_TIMEOUT=2000 \
        bash -c 'umask 0027; cd /var/www/orocommerce; exec "$@"' bash "$@"
}

as_web() {
    sudo -H -u www-data env ORO_ENV=prod ORO_DEBUG=0 \
        bash -c 'umask 0007; cd /var/www/orocommerce; exec "$@"' bash "$@"
}

main() {
    DOMAIN='' EMAIL='' SSH_PORT=22
    while (( $# )); do
        case "$1" in
            --domain|--email|--ssh-port)
                (( $# >= 2 )) && [[ -n $2 && $2 != --* ]] || die "Missing value for $1."
                case "$1" in
                    --domain) DOMAIN=$2 ;;
                    --email) EMAIL=$2 ;;
                    --ssh-port) SSH_PORT=$2 ;;
                esac
                shift 2 ;;
            -h|--help) usage; return ;;
            *) die "Unknown argument: $1. Use --help." ;;
        esac
    done
    validate_inputs
    (( EUID == 0 )) || die 'Run with sudo bash setup.sh.'
    [[ -t 0 && -t 1 ]] || die 'Run in an interactive terminal; do not pipe the script.'
    [[ -f /etc/os-release ]] || die 'Ubuntu 26.04 is required.'
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 26.04 ]] || die 'Ubuntu 26.04 is required.'
    [[ -d /run/systemd/system ]] || die 'A booted systemd server is required.'
    command -v sudo >/dev/null || die 'Install sudo first.'
    exec 9>/run/lock/orocommerce-setup.lock
    flock -n 9 || die 'Another setup is running.'
    check_fresh_server
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        [[ ${SSH_CONNECTION##* } == "$SSH_PORT" ]] || die 'Set --ssh-port to the port of this SSH session.'
    fi
    umask 0022
    export DEBIAN_FRONTEND=noninteractive
    trap 'printf "\nSetup failed at line %s. Fix the error and follow README recovery instructions; no data was removed.\n" "$LINENO" >&2' ERR
    local setup_tmp
    setup_tmp=$(mktemp -d /tmp/orocommerce-setup.XXXXXXXX)
    trap 'rm -rf -- "$setup_tmp"' EXIT

    step '1. Update Ubuntu and install prerequisites'
    apt-get update
    apt-get upgrade -y
    if [[ -f /var/run/reboot-required ]]; then
        die 'Ubuntu requires a reboot. Reboot, reconnect, and rerun this command before proceeding.'
    fi
    apt-get install -y software-properties-common ca-certificates curl
    add-apt-repository -y universe
    apt-get update
    apt-get install -y nginx postgresql-18 postgresql-client-18 \
        git unzip acl nano openssl cron ufw certbot logrotate jpegoptim pngquant \
        php8.5-cli php8.5-fpm php8.5-common php8.5-curl php8.5-gd \
        php8.5-intl php8.5-mbstring php8.5-pgsql php8.5-xml php8.5-zip \
        php8.5-soap php8.5-bcmath php8.5-ldap php8.5-tidy
    timedatectl set-timezone UTC
    systemctl enable --now nginx postgresql php8.5-fpm cron
    [[ $(sudo -u postgres psql -XAtqc "SELECT count(*) FROM pg_database WHERE datname='orocommerce'") == 0 ]] || die 'Database orocommerce already exists.'
    [[ $(sudo -u postgres psql -XAtqc "SELECT count(*) FROM pg_roles WHERE rolname='oro'") == 0 ]] || die 'Database role oro already exists.'
    [[ $(sudo -u postgres psql -XAtqc 'SHOW listen_addresses') == localhost ]] || die 'PostgreSQL must listen on localhost only.'
    [[ $(sudo -u postgres psql -XAtqc "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL OR (type LIKE 'host%' AND (auth_method <> 'scram-sha-256' OR address NOT IN ('127.0.0.1', '::1')))") == 0 ]] || die 'Use loopback-only PostgreSQL SCRAM authentication; see README step 6.'

    step '2. Create administrator and deployment users'
    if ! id oro-admin &>/dev/null; then
        adduser --gecos 'OroCommerce administrator' oro-admin
        usermod -aG sudo oro-admin
    else
        id -nG oro-admin | tr ' ' '\n' | grep -qx sudo || die 'Existing oro-admin must already belong to sudo.'
    fi
    adduser --disabled-password --gecos 'OroCommerce deployment' oro
    install -d -o oro -g oro -m 0750 "$APP_DIR"

    step '3. Install Node.js 24, pnpm 10 and Composer 2'
    curl -fsSL https://deb.nodesource.com/setup_24.x -o "$setup_tmp/node-setup.sh"
    bash "$setup_tmp/node-setup.sh"
    apt-get install -y nodejs
    npm install -g pnpm@latest-10
    [[ $(node --version) == v24.* ]] || die 'Node.js 24 is required.'
    dpkg --compare-versions "$(node --version | cut -c2-)" ge 24.11.0 || die 'Node.js 24.11.0 or newer is required.'
    [[ $(pnpm --version) == 10.* ]] || die 'pnpm 10 is required.'
    dpkg --compare-versions "$(pnpm --version)" ge 10.7.0 || die 'pnpm 10.7.0 or newer is required.'
    curl -fsSL https://getcomposer.org/installer -o "$setup_tmp/composer-setup.php"
    curl -fsSL https://composer.github.io/installer.sig -o "$setup_tmp/installer.sig"
    # shellcheck disable=SC2016
    php8.5 -r 'if (trim(file_get_contents($argv[1])) !== hash_file("sha384", $argv[2])) { fwrite(STDERR, "Composer checksum mismatch\n"); exit(1); }' \
        "$setup_tmp/installer.sig" "$setup_tmp/composer-setup.php"
    php8.5 "$setup_tmp/composer-setup.php" --2 --install-dir="$setup_tmp" --filename=composer
    install -m 0755 "$setup_tmp/composer" /usr/local/bin/composer
    php8.5 -r 'exit(PHP_VERSION_ID >= 80500 && PHP_VERSION_ID < 80600 ? 0 : 1);'
    php -r 'exit(PHP_VERSION_ID >= 80500 && PHP_VERSION_ID < 80600 ? 0 : 1);'

    step '4. Configure PHP'
    cat > /etc/php/8.5/mods-available/orocommerce.ini <<'EOF'
date.timezone = UTC
memory_limit = 2048M
max_execution_time = 300
max_input_time = 300
upload_max_filesize = 64M
post_max_size = 80M
realpath_cache_size = 4096K
realpath_cache_ttl = 600
expose_php = Off
display_errors = Off
log_errors = On
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 32
opcache.max_accelerated_files = 40000
opcache.validate_timestamps = 1
EOF
    phpenmod -v 8.5 -s ALL orocommerce
    cat > /etc/php/8.5/fpm/pool.d/orocommerce.conf <<'EOF'
[orocommerce]
user = www-data
group = www-data
listen = /run/php/orocommerce.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 20s
pm.max_requests = 500
request_terminate_timeout = 300s
catch_workers_output = yes
security.limit_extensions = .php
EOF
    php-fpm8.5 -t
    systemctl restart php8.5-fpm

    step '5. Download OroCommerce and generate application secrets'
    as_oro git clone --branch "$ORO_VERSION" --depth 1 \
        https://github.com/oroinc/orocommerce-application.git "$APP_DIR"
    [[ $(as_oro git describe --tags --exact-match) == "$ORO_VERSION" ]]
    test -s "$APP_DIR/composer.lock"
    local db_password app_secret
    db_password=$(openssl rand -hex 32)
    app_secret=$(openssl rand -hex 32)
    install -o oro -g oro -m 0600 /dev/null "$APP_DIR/.env-app.local"
    cat > "$APP_DIR/.env-app.local" <<EOF
ORO_ENV=prod
ORO_DEBUG=0
ORO_SECRET=$app_secret
ORO_APP_URL=https://$DOMAIN
ORO_DB_URL='postgres://oro:$db_password@127.0.0.1:5432/orocommerce?sslmode=disable&charset=utf8&serverVersion=18'
ORO_MAILER_DSN='null://null'
ORO_SEARCH_URL=orm:
ORO_MQ_DSN=dbal:
ORO_SESSION_DSN=native:
ORO_WEBSOCKET_SERVER_DSN=//127.0.0.1:8080
ORO_WEBSOCKET_FRONTEND_DSN=//$DOMAIN:443/ws
ORO_WEBSOCKET_BACKEND_DSN=tcp://127.0.0.1:8080
ORO_JPEGOPTIM_BINARY=/usr/bin/jpegoptim
ORO_PNGQUANT_BINARY=/usr/bin/pngquant
EOF
    sudo -u postgres psql -X -v ON_ERROR_STOP=1 <<EOF
SET password_encryption = 'scram-sha-256';
CREATE ROLE oro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$db_password';
CREATE DATABASE orocommerce OWNER oro ENCODING 'UTF8' TEMPLATE template0;
\connect orocommerce
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
EOF
    PGPASSWORD=$db_password psql -X -h 127.0.0.1 -U oro -d orocommerce -v ON_ERROR_STOP=1 -c 'SELECT current_user;'
    unset db_password app_secret

    step '6. Install OroCommerce (enter administrator details when prompted)'
    as_oro composer install --no-dev --prefer-dist --optimize-autoloader --no-scripts --no-interaction
    as_oro composer check-platform-reqs --no-dev
    as_oro composer run-script post-install-cmd --no-dev --no-interaction
    as_oro php8.5 bin/console oro:check-requirements --env=prod
    as_oro php8.5 bin/console oro:install --env=prod --timeout=2000 \
        --application-url="https://$DOMAIN" --user-email="$EMAIL" --sample-data=n
    if [[ ! -f $APP_DIR/var/oauth_private.key && ! -f $APP_DIR/var/oauth_public.key ]]; then
        as_oro php8.5 bin/console oro:oauth-server:generate-keys --env=prod
    fi
    test -s "$APP_DIR/var/oauth_private.key"
    test -s "$APP_DIR/var/oauth_public.key"
    as_oro php8.5 bin/console cache:warmup --env=prod
    as_oro php8.5 bin/console oro:api:cache:clear --env=prod
    as_oro php8.5 bin/console oro:api:doc:cache:clear --env=prod

    step '7. Set ownership and writable directories'
    chown -R oro:www-data "$APP_DIR"
    chmod -R u=rwX,g=rX,o= "$APP_DIR"
    local -a writable=("$APP_DIR"/var/{sessions,cache,data,logs,maintenance} "$APP_DIR"/public/{media,js})
    install -d -o oro -g www-data -m 0770 "${writable[@]}"
    setfacl -R -m u:oro:rwX,u:www-data:rwX,o::--- "${writable[@]}"
    setfacl -dR -m u:oro:rwx,u:www-data:rwx,o::--- "${writable[@]}"
    chmod 0640 "$APP_DIR/.env-app.local" "$APP_DIR/var/oauth_public.key"
    chown www-data:www-data "$APP_DIR/var/oauth_private.key"
    chmod 0600 "$APP_DIR/var/oauth_private.key"
    chmod 0700 "$APP_DIR/.git"
    as_web test -r .env-app.local
    as_web test -w var/cache
    as_web test ! -w composer.json
    as_web test -r var/oauth_private.key
    namei -l "$APP_DIR/public/index.php"

    step '8. Configure firewall and request HTTPS certificate'
    ufw allow "$SSH_PORT/tcp"
    ufw allow 'Nginx Full'
    ufw --force enable
    install -d -m 0755 /var/www/letsencrypt
    cat > /etc/nginx/sites-available/orocommerce <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }
    location / {
        return 404;
    }
}
EOF
    ln -s /etc/nginx/sites-available/orocommerce /etc/nginx/sites-enabled/orocommerce
    nginx -t
    systemctl reload nginx
    certbot certonly --webroot -w /var/www/letsencrypt --non-interactive \
        --cert-name "$DOMAIN" -d "$DOMAIN" --email "$EMAIL" --agree-tos

    step '9. Configure HTTPS and WebSocket proxy'
    cat > /etc/nginx/sites-available/orocommerce <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }
    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;
    root /var/www/orocommerce/public;
    index index.php;
    server_tokens off;
    client_max_body_size 80m;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header X-Content-Type-Options nosniff always;

    location / {
        try_files \$uri /index.php\$is_args\$args;
    }
    location = /index.php {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root/index.php;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:/run/php/orocommerce.sock;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 32k;
        fastcgi_buffer_size 64k;
        internal;
    }
    location ~ \.php(?:/|$) {
        return 404;
    }
    location ~ /\. {
        deny all;
    }
    location /ws {
        proxy_pass http://127.0.0.1:8080/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
        proxy_buffering off;
    }
    access_log /var/log/nginx/orocommerce-access.log;
    error_log /var/log/nginx/orocommerce-error.log;
}
EOF
    nginx -t
    systemctl reload nginx
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/orocommerce-reload-nginx <<'EOF'
#!/bin/sh
/usr/sbin/nginx -t && /usr/bin/systemctl reload nginx
EOF
    chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/orocommerce-reload-nginx
    systemctl enable --now certbot.timer

    step '10. Start background workers'
    cat > /etc/systemd/system/oro-consumer.service <<'EOF'
[Unit]
Description=OroCommerce message consumer
After=network.target postgresql.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/orocommerce
Environment=ORO_ENV=prod ORO_DEBUG=0
ExecStart=/usr/bin/php8.5 /var/www/orocommerce/bin/console oro:message-queue:consume --env=prod --memory-limit=512
Restart=always
RestartSec=5
TimeoutStopSec=300
UMask=0007

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/oro-websocket.service <<'EOF'
[Unit]
Description=OroCommerce WebSocket server
After=network.target postgresql.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/orocommerce
Environment=ORO_ENV=prod ORO_DEBUG=0
ExecStart=/usr/bin/php8.5 /var/www/orocommerce/bin/console gos:websocket:server --env=prod
Restart=always
RestartSec=5
TimeoutStopSec=60
UMask=0007

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now oro-consumer oro-websocket

    step '11. Configure cron and log rotation'
    install -o www-data -g www-data -m 0660 /dev/null "$APP_DIR/var/cron.lock"
    cat > /etc/cron.d/orocommerce <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * www-data cd /var/www/orocommerce && umask 0007 && /usr/bin/flock -n var/cron.lock /usr/bin/php8.5 bin/console oro:cron --env=prod >> var/logs/cron.log 2>&1
EOF
    chmod 0644 /etc/cron.d/orocommerce
    cat > /etc/logrotate.d/orocommerce <<'EOF'
/var/www/orocommerce/var/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su www-data www-data
}
EOF

    step '12. Verify services and HTTPS'
    logrotate --debug /etc/logrotate.d/orocommerce
    as_web php8.5 bin/console oro:check-requirements --env=prod
    as_web flock -w 60 var/cron.lock php8.5 bin/console oro:cron --env=prod
    local service
    for service in nginx php8.5-fpm postgresql oro-consumer oro-websocket cron; do
        systemctl is-active --quiet "$service" || die "Service is not active: $service. Inspect journalctl -u $service."
    done
    curl --fail --silent --show-error --retry 5 --retry-delay 3 --retry-connrefused \
        --connect-timeout 10 --max-time 60 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" -o /dev/null
    curl --fail --silent --show-error --connect-timeout 10 --max-time 60 \
        --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/admin/" -o /dev/null
    certbot renew --dry-run
    ufw status
    ss -lntp
    journalctl -u oro-consumer -u oro-websocket -n 20 --no-pager
    printf '\nInstalled OroCommerce %s: https://%s/\nAdmin: https://%s/admin/\n' "$ORO_VERSION" "$DOMAIN" "$DOMAIN"
    printf 'Secrets: %s/.env-app.local (never commit or share).\n' "$APP_DIR"
    printf 'Before launch: configure SMTP, off-server backups, and verify login, checkout and WebSockets (README steps 15-16).\n'
    if [[ -f /var/run/reboot-required ]]; then
        printf 'Ubuntu requires a reboot; reboot and repeat README step 15.\n'
    fi
    rm -rf -- "$setup_tmp"
    trap - EXIT
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
