# OroCommerce 7.0.4 on Ubuntu 26.04 LTS
Single-server OroCommerce Community Edition installation. This guide pins the application to release **7.0.4**; use the release's committed dependency lock file. [Releases](https://github.com/oroinc/orocommerce-application/releases) · [Release policy](https://doc.oroinc.com/community/release-process/)

Use a fresh Ubuntu server and replace the example hostname, email address, and secret values with your own. Configure public DNS before requesting a certificate. Do not expose the site over HTTPS until a trusted certificate has been issued for the hostname. SMTP can be configured after installation; the null mail transport is suitable while mail is disabled.

## Automated installation

1. Prepare a fresh Ubuntu Server 26.04 host with systemd, 4 CPU cores, 16 GB RAM and 80 GB SSD. Point your public DNS hostname to it and allow inbound ports 80, 443 and your SSH port in the provider firewall.
2. Copy [setup.sh](setup.sh) to the server. Run it from an interactive Bash terminal using an existing sudo account:

   ```bash
   sudo bash setup.sh --domain shop.example.com --email admin@example.com --ssh-port 22
   ```

   Replace all examples. Set `--ssh-port` to your actual SSH port before the script enables UFW. Keep the existing SSH connection open until you verify a second connection. Use `bash setup.sh --help` for usage. Do not run with `bash -x`; tracing exposes secrets.

3. If the Ubuntu upgrade requires a reboot, the script stops before creating application users or files. Reboot, reconnect and run the same command again.
4. Set the `oro-admin` Linux password when prompted. The script creates `oro-admin` with sudo access and `oro` without sudo access; an existing `oro-admin` must already be a sudo member. It runs deployment commands as `oro` and runtime commands as `www-data`.
5. Enter the organization name and Oro administrator details when the installer prompts. Demo data is disabled. The email argument is used for the certificate and initial Oro administrator email. The script accepts Let's Encrypt's terms and requests a public certificate.
6. Wait for verification to finish, then complete the browser checks in step 15 and configure SMTP and encrypted off-server backups before launch (steps 8 and 16).

The script installs the pinned release and its lock file, generates database and application secrets in `/var/www/orocommerce/.env-app.local`, and configures PHP-FPM, PostgreSQL, Nginx, HTTPS renewal, UFW, workers, cron and log rotation. It does not schedule backups or configure an SMTP provider.

**Recovery:** the script stops on errors and preserves created files and data. It refuses an existing application directory, deployment user, database, or managed configuration; it is not an upgrade or resume tool. After a partial installation, fix the reported error and continue using the corresponding manual steps below. Use the existing secrets; do not rerun `oro:install` against an initialized database or recreate its role. If certificate issuance fails, fix DNS/firewall access, repeat the Certbot command in step 11, and continue at step 12. After a completed installation, use the maintenance procedure in step 16 for upgrades.

The following steps are the manual alternative; do not repeat them after successful automated installation.

## 1. Prepare the server

- Start with a fresh Ubuntu Server 26.04 LTS installation and an existing sudo account.
- Allocate 4 CPU cores, 16 GB RAM and at least 80 GB SSD as a starting point; size for your catalog and traffic.
- Point `shop.example.com` to the server with a DNS A record. Add an AAAA record only if IPv6 is configured and reachable.
- Choose an organization name and administrator email address. Store credentials in a protected password manager or secret store; do not put passwords in this guide.
- SMTP is optional during installation. Configure a verified mail account before enabling transactional email.
- Run commands in Bash, in order. Stop and resolve any failed command before continuing.

This guide uses PHP 8.5, PostgreSQL 18, Node.js 24 and pnpm 10, following [Oro's requirements](https://doc.oroinc.com/backend/setup/system-requirements/). Database-backed search and queues use the Community Edition defaults in the [release configuration](https://github.com/oroinc/orocommerce-application/blob/7.0.4/.env-app).

## 2. Update Ubuntu and create an administrator

Run as your existing sudo account:

```bash
sudo apt update
sudo apt upgrade -y
sudo adduser oro-admin
sudo usermod -aG sudo oro-admin
sudo -iu oro-admin
whoami
```

Expected user: `oro-admin`. Keep using this account unless a step switches users.

```bash
sudo timedatectl set-timezone UTC
test -f /var/run/reboot-required && cat /var/run/reboot-required
```

If a reboot is required, run `sudo reboot`, reconnect using your existing SSH account, then run `sudo -iu oro-admin` again.

## 3. Install prerequisites

```bash
sudo apt install -y software-properties-common
sudo add-apt-repository -y universe
sudo apt update
sudo apt install -y nginx postgresql-18 postgresql-client-18 \
    git curl ca-certificates unzip acl nano openssl cron ufw \
    certbot logrotate jpegoptim pngquant \
    php8.5-cli php8.5-fpm php8.5-common php8.5-curl php8.5-gd \
    php8.5-intl php8.5-mbstring php8.5-pgsql php8.5-xml \
    php8.5-zip php8.5-soap php8.5-bcmath php8.5-ldap php8.5-tidy
sudo systemctl enable --now nginx postgresql php8.5-fpm cron
```

Ubuntu supplies [PostgreSQL 18](https://packages.ubuntu.com/resolute/postgresql-18) and [PHP 8.5 packages](https://packages.ubuntu.com/resolute/php/). PHP's IMAP extension is [absent from Ubuntu 26.04's archive](https://ubuntu.com/security/CVE-2023-35169) and is optional in [Oro Platform 7.0's dependency manifest](https://github.com/oroinc/platform/blob/7.0/composer.json); this installation omits it. MongoDB is only needed when enabling GridFS storage.

Install Node.js and pnpm using [Oro's Ubuntu instructions](https://doc.oroinc.com/backend/setup/dev-environment/ubuntu/):

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x -o /tmp/oro-node-setup.sh
sudo bash /tmp/oro-node-setup.sh
sudo apt install -y nodejs
sudo npm install -g pnpm@latest-10
node --version
pnpm --version
php8.5 --version
psql --version
```

Require Node.js `24.11.0` or newer within major 24, and pnpm `10.7.0` or newer within major 10.

## 4. Install Composer 2

Verify the installer against [Composer's published checksum](https://getcomposer.org/download/):

```bash
mkdir -p ~/oro-composer-setup
cd ~/oro-composer-setup
curl -fsSLo composer-setup.php https://getcomposer.org/installer
curl -fsSLo installer.sig https://composer.github.io/installer.sig
php8.5 -r 'if (trim(file_get_contents("installer.sig")) !== hash_file("sha384", "composer-setup.php")) { fwrite(STDERR, "Checksum mismatch\n"); exit(1); }'
php8.5 composer-setup.php --2 --filename=composer
sudo install -m 0755 composer /usr/local/bin/composer
composer --version
cd ~
```

## 5. Configure PHP

```bash
sudo tee /etc/php/8.5/mods-available/orocommerce.ini > /dev/null <<'EOF'
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
sudo phpenmod -v 8.5 -s ALL orocommerce
```

Create a dedicated PHP-FPM pool. Start with four children on the recommended 16 GB server and adjust after measuring PHP worker memory and load.

```bash
sudo tee /etc/php/8.5/fpm/pool.d/orocommerce.conf > /dev/null <<'EOF'
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
sudo php-fpm8.5 -t
sudo systemctl restart php8.5-fpm
```

## 6. Create the deployment user and database

`oro` owns application code; `www-data` runs PHP, workers and cron. Only `oro-admin` has sudo access.

```bash
sudo adduser --disabled-password --gecos "OroCommerce deployment" oro
sudo install -d -o oro -g oro -m 0750 /var/www/orocommerce
openssl rand -hex 32
```

Save the generated value as the database password in your password manager.

```bash
sudo -u postgres psql
```

Run inside `psql`; enter that password at the `\password` prompts:

```sql
CREATE ROLE oro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
\password oro
CREATE DATABASE orocommerce OWNER oro ENCODING 'UTF8' TEMPLATE template0;
\connect orocommerce
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
\quit
```

Keep PostgreSQL bound to loopback and use password authentication for TCP connections:

```bash
sudo -u postgres psql -c "SHOW listen_addresses;"
sudo -u postgres psql -c "SELECT type, address, auth_method FROM pg_hba_file_rules WHERE type LIKE 'host%';"
psql -h 127.0.0.1 -U oro -d orocommerce -W -c 'SELECT current_user;'
```

On a fresh Ubuntu installation, expect `localhost` and loopback `scram-sha-256` rules. Do not continue with `trust` authentication or a public database listener.

## 7. Download the pinned release

Switch to the deployment user:

```bash
sudo -iu oro
umask 0027
git clone --branch 7.0.4 --depth 1 \
    https://github.com/oroinc/orocommerce-application.git /var/www/orocommerce
cd /var/www/orocommerce
git describe --tags --exact-match
test -f composer.lock
```

Expected tag: `7.0.4`. Install from the release's lock file; retain it for reproducible deployments.

## 8. Configure application secrets

Still as `oro`:

```bash
openssl rand -hex 32
install -m 0600 /dev/null .env-app.local
nano .env-app.local
```

Paste the following, replacing the secret with the new random value and the database password with the value from step 6:

```dotenv
ORO_ENV=prod
ORO_DEBUG=0
ORO_SECRET=GENERATE_A_UNIQUE_RANDOM_SECRET
ORO_APP_URL=https://shop.example.com
ORO_DB_URL='postgres://oro:URL_ENCODED_DATABASE_PASSWORD@127.0.0.1:5432/orocommerce?sslmode=disable&charset=utf8&serverVersion=18'
ORO_MAILER_DSN='null://null'
ORO_SEARCH_URL=orm:
ORO_MQ_DSN=dbal:
ORO_SESSION_DSN=native:
ORO_WEBSOCKET_SERVER_DSN=//127.0.0.1:8080
ORO_WEBSOCKET_FRONTEND_DSN=//shop.example.com:443/ws
ORO_WEBSOCKET_BACKEND_DSN=tcp://127.0.0.1:8080
ORO_JPEGOPTIM_BINARY=/usr/bin/jpegoptim
ORO_PNGQUANT_BINARY=/usr/bin/pngquant
```

`ORO_MAILER_DSN='null://null'` discards outgoing email while SMTP is unconfigured. Before launch, replace it with your provider's SMTP DSN, URL-encoding usernames and passwords (including `@`, `:` and `/`), then clear/warm the production cache and restart PHP-FPM and both workers. [SMTP configuration](https://symfony.com/doc/current/mailer.html#transport-setup)

Keep `.env-app.local` and OAuth private keys out of version control and public backups.

## 9. Install OroCommerce

Still as `oro`, in `/var/www/orocommerce`:

```bash
export ORO_ENV=prod ORO_DEBUG=0
composer install --no-dev --prefer-dist --optimize-autoloader --no-scripts
composer check-platform-reqs --no-dev
composer run-script post-install-cmd --no-dev
php8.5 bin/console oro:check-requirements --env=prod
```

Run `php8.5 bin/console oro:install --env=prod --timeout=2000` interactively. Use the HTTPS URL for your chosen hostname, enter your organization and administrator details, create a unique administrator password, and decline demo data unless you specifically need it. [Installation reference](https://doc.oroinc.com/backend/setup/installation/)

Ensure OAuth keys exist, without replacing existing keys:

```bash
if [ ! -f var/oauth_private.key ] && [ ! -f var/oauth_public.key ]; then
    php8.5 bin/console oro:oauth-server:generate-keys --env=prod
fi
test -s var/oauth_private.key
test -s var/oauth_public.key
php8.5 bin/console cache:warmup --env=prod
php8.5 bin/console oro:api:cache:clear --env=prod
php8.5 bin/console oro:api:doc:cache:clear --env=prod
exit
```

You are now back as `oro-admin`.

## 10. Set ownership and writable directories

Run before exposing the application through Nginx:

```bash
sudo chown -R oro:www-data /var/www/orocommerce
sudo chmod -R u=rwX,g=rX,o= /var/www/orocommerce
sudo install -d -o oro -g www-data -m 0770 \
    /var/www/orocommerce/var/sessions \
    /var/www/orocommerce/var/cache \
    /var/www/orocommerce/var/data \
    /var/www/orocommerce/var/logs \
    /var/www/orocommerce/var/maintenance \
    /var/www/orocommerce/public/media \
    /var/www/orocommerce/public/js
sudo setfacl -R -m u:oro:rwX,u:www-data:rwX,o::--- \
    /var/www/orocommerce/var/{sessions,cache,data,logs,maintenance} \
    /var/www/orocommerce/public/{media,js}
sudo setfacl -dR -m u:oro:rwx,u:www-data:rwx,o::--- \
    /var/www/orocommerce/var/{sessions,cache,data,logs,maintenance} \
    /var/www/orocommerce/public/{media,js}
sudo chmod 0640 /var/www/orocommerce/.env-app.local \
    /var/www/orocommerce/var/oauth_public.key
sudo chown www-data:www-data /var/www/orocommerce/var/oauth_private.key
sudo chmod 0600 /var/www/orocommerce/var/oauth_private.key
sudo chmod 0700 /var/www/orocommerce/.git
sudo -u www-data test -r /var/www/orocommerce/.env-app.local
sudo -u www-data test -w /var/www/orocommerce/var/cache
sudo -u www-data test ! -w /var/www/orocommerce/composer.json
namei -l /var/www/orocommerce/public/index.php
```

All three `test` commands must succeed. Repeat this step after deployments that create files or alter permissions. Never use `chmod -R 777`.

## 11. Open the firewall and obtain a trusted HTTPS certificate

If SSH uses a custom port, allow that port before enabling UFW. Also allow ports 80 and 443 in your provider's firewall.

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable
sudo ufw status
sudo install -d -m 0755 /var/www/letsencrypt
sudo tee /etc/nginx/sites-available/orocommerce > /dev/null <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name shop.example.com;
    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }
    location / {
        return 404;
    }
}
EOF
sudo ln -s /etc/nginx/sites-available/orocommerce /etc/nginx/sites-enabled/orocommerce
sudo nginx -t
sudo systemctl reload nginx
sudo certbot certonly --webroot -w /var/www/letsencrypt \
    --cert-name shop.example.com -d shop.example.com \
    --email admin@example.com --agree-tos
```

Public DNS for `shop.example.com` must already resolve to this server, and inbound HTTP/HTTPS must be allowed, before requesting the certificate. [Certbot webroot reference](https://eff-certbot.readthedocs.io/en/stable/using.html#webroot)

## 12. Configure Nginx and secure WebSockets

```bash
sudo tee /etc/nginx/sites-available/orocommerce > /dev/null <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name shop.example.com;
    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }
    location / {
        return 301 https://shop.example.com$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name shop.example.com;
    root /var/www/orocommerce/public;
    index index.php;
    server_tokens off;
    client_max_body_size 80m;

    ssl_certificate /etc/letsencrypt/live/shop.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/shop.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header X-Content-Type-Options nosniff always;

    location / {
        try_files $uri /index.php$is_args$args;
    }

    location = /index.php {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root/index.php;
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
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
        proxy_buffering off;
    }

    access_log /var/log/nginx/orocommerce-access.log;
    error_log /var/log/nginx/orocommerce-error.log;
}
EOF
sudo nginx -t
sudo systemctl reload nginx
sudo install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx > /dev/null <<'EOF'
#!/bin/sh
/usr/sbin/nginx -t && /usr/bin/systemctl reload nginx
EOF
sudo chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx
sudo systemctl enable --now certbot.timer
sudo certbot renew --dry-run
```

The document root is `public`; only the front controller executes PHP. WebSocket traffic uses HTTPS externally and loopback internally. [Web server reference](https://doc.oroinc.com/backend/setup/dev-environment/web-server-config/) · [WebSocket reference](https://doc.oroinc.com/backend/websockets/configuration/)

## 13. Start persistent background workers

Use systemd to supervise the queue consumer and WebSocket server:

```bash
sudo tee /etc/systemd/system/oro-consumer.service > /dev/null <<'EOF'
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

sudo tee /etc/systemd/system/oro-websocket.service > /dev/null <<'EOF'
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
sudo systemctl daemon-reload
sudo systemctl enable --now oro-consumer oro-websocket
sudo systemctl status oro-consumer oro-websocket --no-pager
```

Start with one consumer; increase concurrency only after measuring database load and queue delays.

## 14. Schedule cron and rotate application logs

```bash
sudo tee /etc/cron.d/orocommerce > /dev/null <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * www-data cd /var/www/orocommerce && umask 0007 && /usr/bin/flock -n var/cron.lock /usr/bin/php8.5 bin/console oro:cron --env=prod >> var/logs/cron.log 2>&1
EOF
sudo install -o www-data -g www-data -m 0660 /dev/null /var/www/orocommerce/var/cron.lock
sudo chmod 0644 /etc/cron.d/orocommerce
sudo tee /etc/logrotate.d/orocommerce > /dev/null <<'EOF'
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
sudo logrotate --debug /etc/logrotate.d/orocommerce
```

## 15. Verify the installation

```bash
sudo -u www-data /usr/bin/php8.5 /var/www/orocommerce/bin/console oro:check-requirements --env=prod
sudo -u www-data bash -c 'umask 0007; cd /var/www/orocommerce && flock -w 60 var/cron.lock php8.5 bin/console oro:cron --env=prod'
for service in nginx php8.5-fpm postgresql oro-consumer oro-websocket cron; do
    sudo systemctl is-active "$service" || break
done
sudo ss -lntp
curl -I https://shop.example.com/
curl -I https://shop.example.com/admin/
sudo journalctl -u oro-consumer -u oro-websocket -n 50 --no-pager
```

- PostgreSQL port 5432 and WebSocket port 8080 must listen only on loopback.
- Open `https://shop.example.com/` and `https://shop.example.com/admin/`.
- Sign in with the administrator created during installation.
- Set the system and website URLs to HTTPS in the back office; confirm the sender email and SMTP delivery.
- Verify storefront search, an uploaded product image, a background export and a test email.
- Confirm `/ws` upgrades with HTTP `101` in the browser's Network panel.
- Run a test order before accepting real orders.

## 16. Back up and maintain the installation

Before upgrades, stop writes during a maintenance window. Run as `oro-admin`:

```bash
sudo -u www-data /usr/bin/php8.5 /var/www/orocommerce/bin/console oro:maintenance:lock --env=prod
sudo systemctl stop cron oro-consumer oro-websocket php8.5-fpm
sudo install -d -m 0700 /var/backups/orocommerce
backup_stamp=$(date -u +%Y%m%dT%H%M%SZ)
set -o pipefail
sudo -u postgres pg_dump -Fc orocommerce | \
    sudo tee "/var/backups/orocommerce/${backup_stamp}.dump" > /dev/null
sudo tar --acls --xattrs -czf "/var/backups/orocommerce/${backup_stamp}-application.tar.gz" \
    -C /var/www/orocommerce .env-app.local composer.json composer.lock \
    config src templates translations public/media var/data \
    var/oauth_private.key var/oauth_public.key
sudo tar --acls --xattrs -czf "/var/backups/orocommerce/${backup_stamp}-server-config.tar.gz" -C / \
    etc/nginx etc/php/8.5 etc/postgresql/18 etc/letsencrypt \
    etc/systemd/system/oro-consumer.service etc/systemd/system/oro-websocket.service \
    etc/cron.d/orocommerce etc/logrotate.d/orocommerce
sudo chmod 0600 /var/backups/orocommerce/"${backup_stamp}"*
sudo -u www-data /usr/bin/php8.5 /var/www/orocommerce/bin/console oro:maintenance:unlock --env=prod
sudo systemctl start php8.5-fpm oro-consumer oro-websocket cron
```

If any backup command fails, restart the services and resolve the problem before upgrading. Keep the backup files private. Test database restoration in an isolated database before production use.

Schedule encrypted off-server backups of the database, uploaded files, secrets, application customizations and `/etc` service configuration. Keep the release tag and dependency lock files. Test restoration on a separate server before launch and regularly afterward.

Install Ubuntu security updates during maintenance windows. Apply new stable Oro 7.0 patches in staging first, following the release's upgrade instructions; never run an unreviewed `composer update` on production.

For code and dependency deployments, switch to `oro` with `sudo -iu oro`, run `cd /var/www/orocommerce`, then use `exit` to return to `oro-admin`. After step 10, run routine application commands as `www-data`, which owns the protected OAuth private key. For example, after editing SMTP settings:

```bash
sudo -u www-data bash -c 'umask 0007; cd /var/www/orocommerce && php8.5 bin/console cache:clear --env=prod && php8.5 bin/console cache:warmup --env=prod'
```

Restart PHP-FPM and both workers after deployments or configuration changes:

```bash
sudo systemctl restart php8.5-fpm oro-consumer oro-websocket
```

## Check the setup script

These checks do not provision a server:

```bash
bash -n setup.sh
bash tests/setup_test.sh
shellcheck setup.sh tests/setup_test.sh
```
