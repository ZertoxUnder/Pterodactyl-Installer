#!/usr/bin/env bash
# Tests sans root ni installation : écritures limitées à mktemp, commandes simulées.
# Les variables sont consommées par les fonctions du script sourcé ; les
# dollars littéraux servent aux tests d'injection et au sous-processus Bash.
# shellcheck disable=SC2034,SC2016,SC1112
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# Le fichier install.sh est analysé séparément par la CI.
# shellcheck source=/dev/null
source ./install.sh
TMP=$(mktemp -d /tmp/ptero-install.XXXXXXXX)
STATE_DIR=$TMP/state
mkdir -m 700 "$STATE_DIR"

for version in 1.25.1 1.26.0 1.28.0 2.0.0 1.25.1-custom; do
    nginx_modern_http2 "$version"
done
for version in 1.18.0 1.22.1 1.24.0 1.25.0 invalid; do
    if nginx_modern_http2 "$version"; then exit 1; fi
done
printf 'PASS HTTP/2 version boundaries\n'

TEST_ROOT=$TMP
mkdir -p "$TMP/etc/nginx/sites-available" "$TMP/etc/nginx/sites-enabled"
eval "$(declare -f webserver | sed 's|/etc/|$TEST_ROOT/etc/|g')"
nginx() { if [[ $1 == -v ]]; then printf 'nginx version: nginx/%s\n' "$NGINX_TEST_VERSION" >&2; fi; }
systemctl() { :; }
WEB=nginx SSL=le PHP_VERSION=8.3
PANEL_DOMAIN=panel.example.com PANEL_CERT=/cert.pem PANEL_KEY=/key.pem
for NGINX_TEST_VERSION in 1.18.0 1.24.0 1.25.1 1.26.2; do
    webserver
    config=$TMP/etc/nginx/sites-available/pterodactyl.conf
    if nginx_modern_http2 "$NGINX_TEST_VERSION"; then
        grep -Fq 'listen 443 ssl;' "$config"
        grep -Fq 'http2 on;' "$config"
    else
        grep -Fq 'listen 443 ssl http2;' "$config"
        if grep -Fq 'http2 on;' "$config"; then exit 1; fi
    fi
done
printf 'PASS generated Nginx configurations, old and modern versions\n'

DIAGNOSTICS=$TMP/diagnostics
mkdir "$DIAGNOSTICS"
# Appel indirect depuis docker_smoke_test, chargé via source.
# shellcheck disable=SC2329
docker() { printf 'simulated registry failure\n' >&2; return 125; }
docker_smoke_test
grep -Fq 'simulated registry failure' "$DIAGNOSTICS/docker-container-test.log"
printf 'PASS Docker Hub failure is logged without stopping installation\n'

apt-get() { printf '%s\n' "$*" >> "$TMP/apt-calls"; }
APT_REFRESHED=0
apt_update
apt_update
apt_update force
apt_install curl
[[ $(grep -c 'Error-Mode=any update' "$TMP/apt-calls") == 2 ]]
grep -Fq 'install -y --no-install-recommends curl' "$TMP/apt-calls"
printf 'PASS APT cache and forced refresh after repository changes\n'

PANEL_DOMAIN='$(touch SHOULD_NOT_EXIST)'
DB_PASSWORD=$'quote\047 backslash\\ dollar$'
ADMIN_PASSWORD=ADMIN_SECRET_TEST
SMTP_PASSWORD=SMTP_SECRET_TEST
APPLICATION_KEY=API_SECRET_TEST
state_save
DB_PASSWORD=''
# shellcheck source=/dev/null
source "$STATE_DIR/settings"
[[ $DB_PASSWORD == $'quote\047 backslash\\ dollar$' ]]
[[ ! -e SHOULD_NOT_EXIST ]]
if grep -Fq API_SECRET_TEST "$STATE_DIR/settings"; then exit 1; fi
unset DB_PASSWORD ADMIN_PASSWORD SMTP_PASSWORD APPLICATION_KEY
state_save
if grep -Eq 'ADMIN_SECRET_TEST|SMTP_SECRET_TEST|quote' "$STATE_DIR/settings"; then exit 1; fi
printf 'PASS state quoting, API key excluded, explicit secret purge\n'

if "$BASH" -c '
    source ./install.sh
    STATE_DIR=$1
    work() { printf "started\n" >> "$STATE_DIR/events"; false; printf "unexpected\n" >> "$STATE_DIR/events"; }
    run_step interrupted work
' validation "$STATE_DIR" >/dev/null 2>&1; then exit 1; fi
[[ ! -e $STATE_DIR/interrupted.done ]]
[[ $(cat "$STATE_DIR/events") == started ]]
work() { printf 'resumed\n' >> "$STATE_DIR/events"; }
run_step interrupted work
run_step interrupted work
[[ $(cat "$STATE_DIR/events") == $'started\nresumed' ]]
printf 'PASS interrupted step rerun once; completed step skipped\n'

# Reproduire la reprise après panel-env.done : ADMIN_EMAIL est défini,
# mais son attribut export ne l'est pas dans le nouveau processus Bash.
PANEL=1
PANEL_DIR=$TMP/panel
mkdir -p "$PANEL_DIR/storage/logs" "$PANEL_DIR/bootstrap/cache"
touch "$STATE_DIR/panel-files.done" "$STATE_DIR/panel-env.done" "$STATE_DIR/panel-migrations.done"
printf 'APP_KEY=base64:dGVzdA==\n' > "$PANEL_DIR/.env"
ADMIN_EMAIL=admin@example.com
export -n ADMIN_EMAIL
ADMIN_USER=admin ADMIN_FIRST=Test ADMIN_LAST=Admin ADMIN_PASSWORD=ADMIN_TEST_PASSWORD
PANEL_URL=http://203.0.113.10
PHP_BIN=fake_php
fake_php() {
    if [[ ${1:-} == /usr/local/bin/composer ]]; then
        [[ ${COMPOSER_ALLOW_SUPERUSER:-} == 1 && ${COMPOSER_NO_INTERACTION:-} == 1 && ${2:-} == --no-interaction ]]
    fi
    if (( $# == 0 )); then
        cat > /dev/null
        [[ $(printenv ADMIN_EMAIL) == admin@example.com ]]
        printf 'admin-helper\n' >> "$TMP/php-events"
    else
        printf '%s\n' "$*" >> "$TMP/php-events"
    fi
}
# Aucune modification de propriétaires sur la machine de test.
chown() { printf '%s\n' "$*" >> "$TMP/chown-events"; }
panel_install
grep -Fq admin-helper "$TMP/php-events"
if grep -Fq key:generate "$TMP/php-events"; then exit 1; fi
[[ $(cat "$PANEL_DIR/.env") == APP_KEY=base64:dGVzdA== ]]
[[ -e $STATE_DIR/panel-admin.done ]]
grep -Fq "$PANEL_DIR/storage" "$TMP/chown-events"
grep -Fq "$PANEL_DIR/bootstrap/cache" "$TMP/chown-events"
printf 'PASS resumed admin email exported, APP_KEY preserved, runtime ownership repaired\n'
PANEL=0

# Le parcours rapide Panel + Wings avec IP ne demande ni mot de passe,
# ni identité détaillée, ni SMTP, ni paramètres techniques du nœud.
ask_count=0 confirm_count=0
ask() {
    ask_count=$((ask_count + 1))
    case "$2" in
        'Adresse du Panel'*) printf -v "$1" '%s' 203.0.113.10;;
        'Email administrateur') printf -v "$1" '%s' admin@example.com;;
        *) die "Question inattendue dans le mode rapide : $2";;
    esac
}
yesno() {
    confirm_count=$((confirm_count + 1))
    case "$1" in 'Préparer aussi MariaDB pour les bases des jeux'|'Lancer l’installation avec ces paramètres') return 0;; *) die 'Confirmation inattendue';; esac
}
detect_resources() { resource_defaults 8192 100000; }
secret() { die 'Une saisie de mot de passe est inattendue en mode rapide local.'; }
PANEL=1 WINGS=1 GAME_DB_ENABLED=0
questions_quick
[[ $ask_count == 2 && $confirm_count == 2 && $GAME_DB_ENABLED == 1 && $AUTO_LINK == 1 ]]
[[ $WINGS_DOMAIN == "$PANEL_DOMAIN" && $SSL == none && $ADMIN_USER == admin && $MAIL_MAILER == log ]]
[[ -z $DB_PASSWORD && -z $ADMIN_PASSWORD ]]
printf 'PASS quick local flow: four prompts, generated passwords, automatic node resources\n'

# Simulation de l'instance DB dédiée : aucun Docker/MariaDB réel n'est lancé.
mkdir -p "$TMP/etc/pterodactyl"
touch "$TMP/etc/pterodactyl/config.yml" "$PANEL_DIR/artisan"
export TEST_ROOT
cat > "$TMP/php-mock" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ $GAME_DB_GATEWAY == 172.18.0.1 && ${#GAME_DB_PASSWORD} == 64 ]]
cat > "$TEST_ROOT/php-host-request"
MOCK
chmod 700 "$TMP/php-mock"
definition=$(declare -f configure_game_databases)
definition=${definition//\/etc\/pterodactyl/\$TEST_ROOT\/etc\/pterodactyl}
definition=${definition//\/usr\/bin\/php\$PHP_VERSION/\$TEST_ROOT\/php-mock}
eval "$definition"
python3() { if (( $# > 1 )); then printf '172.18.0.1\n'; else cat >/dev/null; printf 'pterodactyl_nw 90ec6608-bbad-40ee-83db-59679ef73185\n'; fi; }
openssl() { printf 'a%.0s' {1..64}; printf '\n'; }
ss() { :; }
stat() { if [[ $1 == -c && $2 == %u ]]; then printf '0\n'; else command stat "$@"; fi; }
docker() {
    case "$1:${2:-}" in
        info:) return 0;;
        network:inspect) printf '[]\n';;
        volume:inspect)
            if [[ $3 == --format ]]; then printf 'game-db\n'; else [[ -f $TMP/volume-created ]]; fi;;
        volume:create) touch "$TMP/volume-created";;
        container:inspect) [[ -f $TMP/container-created ]];;
        inspect:--format)
            if [[ $3 == *gateway* ]]; then printf '172.18.0.1\n'; else printf 'game-db\n'; fi;;
        run:-d)
            printf '%s\n' "$*" >> "$TMP/db-runs"
            touch "$TMP/container-created";;
        start:*) :;;
        exec:-i) cat > "$TMP/generated-game-sql";;
        exec:*) :;;
        *) die "Commande Docker inattendue : $*";;
    esac
}
configure_game_databases
configure_game_databases
[[ $(wc -l < "$TMP/db-runs") == 1 && -f $STATE_DIR/game-db.done ]]
grep -Fq -- '--publish 172.18.0.1:3307:3306/tcp' "$TMP/db-runs"
grep -Fq -- '--restart unless-stopped' "$TMP/db-runs"
grep -Fq 'mariadb:11.4' "$TMP/db-runs"
grep -Fq HostCreationService "$TMP/php-host-request"
grep -Fq "'ptero_games'@'%'" "$TMP/generated-game-sql"
[[ ! -v GAME_DB_PASSWORD ]]
printf 'PASS dedicated game DB: private bridge binding, persistent storage, registration, reuse, secret unset\n'
PANEL=0
