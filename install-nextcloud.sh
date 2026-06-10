#!/bin/bash
#
# Installation Nextcloud sur Debian 12 + vhost SSL
# Usage : ./install-nextcloud.sh
#

set -euo pipefail

# ───── Variables à adapter ─────────────────────────────────────────────
DOMAIN="domaine.com"
SERVER_NAME="nextcloudarchive.${DOMAIN}"   # FQDN du vhost
BASE_DOMAIN="${DOMAIN}"                    # domaine du certif wildcard
ADMIN_EMAIL="admin@${DOMAIN}"

WEB_ROOT="/var/www/html"
NC_DIR="${WEB_ROOT}/nextcloud"

# Fonction de génération de mot de passe aléatoire
genpass() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

DB_NAME="nextclouddb"
DB_USER="nextclouduser"
DB_PASS="$(genpass)"
DB_ROOT_PASS="$(genpass)"

# Certificat wildcard *.${DOMAIN}
SSL_DIR="/etc/ssl/_.${BASE_DOMAIN}"
SSL_CRT="${SSL_DIR}/_.${BASE_DOMAIN}.crt"
SSL_KEY="${SSL_DIR}/_.${BASE_DOMAIN}.key"
SSL_CHAIN="${SSL_DIR}/GandiCert.pem"

NC_URL="https://download.nextcloud.com/server/releases/latest.zip"
# ───────────────────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && { echo "Lancer en root."; exit 1; }

log() { echo -e "\n\e[1;34m[+] $*\e[0m"; }

log "Vérification des certificats SSL"
for f in "${SSL_CRT}" "${SSL_KEY}" "${SSL_CHAIN}"; do
    [[ -f "$f" ]] || { echo "Fichier manquant : $f"; exit 1; }
done

log "Mise à jour du système"
apt update
apt upgrade -y

log "Installation Apache, MariaDB, PHP et extensions"
apt install -y \
    apache2 \
    mariadb-server \
    php php-cli php-mysql php-curl php-gd php-mbstring php-xml php-zip \
    php-bz2 php-intl php-bcmath php-gmp php-imagick \
    wget unzip openssl

systemctl enable --now apache2
systemctl enable --now mariadb

log "Sécurisation MariaDB (mot de passe root + nettoyage)"
mysql <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_ROOT_PASS}') OR unix_socket;
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

# Fichier .my.cnf pour root : plus besoin de retaper le mdp
umask 077
cat > /root/.my.cnf <<EOF
[client]
user=root
password=${DB_ROOT_PASS}
EOF

log "Création de la base de données Nextcloud"
mysql <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

cat > /root/.nextcloud_db_credentials <<EOF
# MariaDB root
DB_ROOT_PASS=${DB_ROOT_PASS}

# Base Nextcloud
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
EOF
log "Credentials écrits dans /root/.nextcloud_db_credentials"

log "Téléchargement et extraction de Nextcloud"
cd "${WEB_ROOT}"
if [[ -d "${NC_DIR}" ]]; then
    echo "Le dossier ${NC_DIR} existe déjà, on saute le téléchargement."
else
    wget -q --show-progress "${NC_URL}" -O latest.zip
    unzip -q latest.zip
    rm -f latest.zip
fi

chown -R www-data:www-data "${NC_DIR}"
find "${NC_DIR}" -type d -exec chmod 750 {} \;
find "${NC_DIR}" -type f -exec chmod 640 {} \;

log "Création du vhost HTTP (redirection vers HTTPS)"
cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>
    ServerAdmin ${ADMIN_EMAIL}
    ServerName ${SERVER_NAME}
    DocumentRoot ${NC_DIR}

    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^(.*)$ https://%{HTTP_HOST}\$1 [R=301,L]

    <Directory ${NC_DIR}/>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

log "Création du vhost SSL"
cat > /etc/apache2/sites-available/nextcloud-ssl.conf <<EOF
<VirtualHost *:443>
    ServerName ${SERVER_NAME}
    DocumentRoot ${NC_DIR}

    SSLEngine on
    SSLCertificateFile ${SSL_CRT}
    SSLCertificateKeyFile ${SSL_KEY}
    SSLCertificateChainFile ${SSL_CHAIN}

    <Directory ${NC_DIR}/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_ssl_access.log combined
</VirtualHost>
EOF

log "Activation modules et sites Apache"
a2enmod ssl rewrite headers env dir mime
a2ensite nextcloud.conf
a2ensite nextcloud-ssl.conf
a2dissite 000-default.conf >/dev/null 2>&1 || true

log "Test config et redémarrage Apache"
apache2ctl configtest
systemctl restart apache2
systemctl status apache2 --no-pager -l | head -n 15

log "Terminé."
echo
echo "─────────────────────────────────────────────"
echo " URL          : https://${SERVER_NAME}"
echo " BDD          : ${DB_NAME} / ${DB_USER}"
echo " Pass user    : ${DB_PASS}"
echo " Pass root DB : ${DB_ROOT_PASS}"
echo " (sauvegardés dans /root/.nextcloud_db_credentials)"
echo " /root/.my.cnf créé pour les connexions root"
echo "─────────────────────────────────────────────"
echo
echo "Étapes restantes :"
echo "  - Lancer l'assistant web pour finaliser l'install Nextcloud"
echo "  - Configurer le tuning PHP (memory_limit, opcache, APCu)"
echo "  - Activer un cron pour les jobs Nextcloud (toutes les 5 min)"
