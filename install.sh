#!/usr/bin/env bash
# Pterodactyl 1.x stable — installation NEUVE, root, systemd.
# OS : Ubuntu 22.04/24.04 et Debian 12/13.
# PHP : 8.3 (PPA Ubuntu 22.04, natif Ubuntu 24.04, Sury Debian 13),
# 8.2 natif Debian 12. PHP 8.4 natif de Debian 13 n'est pas utilisé pour Panel 1.x.
# Adresses : domaine ou IPv4 ; Panel et Wings peuvent utiliser la même IP.
# Usage : sudo bash install.sh ; reprise : sudo bash install.sh --resume
# Reprise uniquement d'une installation commencée par cette version ; pas
# d'import automatique d'une ancienne installation ou d'une base tierce.
# Sources officielles :
# https://docs.pterodactyl.io/v1/panel/getting-started
# https://docs.pterodactyl.io/v1/panel/webserver-configuration
# https://docs.pterodactyl.io/v1/wings/installing
# https://docs.docker.com/engine/install/ubuntu/
# https://docs.docker.com/engine/install/debian/
# Liaison automatique : services internes du Panel local, API Application 1.x
# pour un Panel distant (clé Nodes/Locations lecture-écriture, HTTPS requis).
# Aucun mode destructif de désinstallation/mise à jour : volontairement hors périmètre.
# Ne pas utiliser bash -x : les variables contiennent des secrets.
# Les apostrophes typographiques des messages français sont intentionnelles.
# shellcheck disable=SC1112

set -Eeuo pipefail
umask 077
export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive
PANEL_DIR=/var/www/pterodactyl
PANEL=0 WINGS=0 FIREWALL=0 WINGS_READY=0
AUTO_LINK=0 APPLICATION_KEY='' NODE_NAME='' LOCATION_SHORT='' NODE_MEMORY='' NODE_DISK=''
PANEL_DOMAIN='' WINGS_DOMAIN='' PANEL_URL='' WEB='' SSL=''
PANEL_CERT='' PANEL_KEY='' WINGS_CERT='' WINGS_KEY=''
DB_PASSWORD='' ADMIN_PASSWORD='' SMTP_PASSWORD=''
TMP='' STAGE=initialisation
LOG='' CREDENTIALS=''
STATE_DIR=/var/lib/pterodactyl-installer
DIAGNOSTICS='' INSTALL_OS=''
APT_REFRESHED=0
QUICK_MODE=1 GAME_DB_ENABLED=0 DB_ONLY=0
RED=$'\033[31m' GREEN=$'\033[32m' BLUE=$'\033[36m' RESET=$'\033[0m'

info() { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
die() { printf '%s[ERREUR]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
cleanup() {
    local status=$?
    trap - EXIT
    # Un helper PHP root peut créer un log même s'il échoue.
    repair_panel_runtime_permissions || true
    if (( status != 0 )) && [[ -n $DIAGNOSTICS && -n $TMP && -d $TMP ]]; then
        local diagnostic
        for diagnostic in sql-output admin-output game-db-output; do
            if [[ -f $TMP/$diagnostic ]]; then
                cp -- "$TMP/$diagnostic" "$DIAGNOSTICS/$diagnostic.log" || true
                chmod 600 "$DIAGNOSTICS/$diagnostic.log" || true
            fi
        done
        printf 'Diagnostics privés : %s\n' "$DIAGNOSTICS" >&2
    fi
    if [[ -n $TMP && $TMP == /tmp/ptero-install.* ]]; then rm -rf -- "$TMP"; fi
    unset DB_PASSWORD ADMIN_PASSWORD SMTP_PASSWORD APPLICATION_KEY GAME_DB_PASSWORD
    if (( status != 0 )); then
        printf '\nArrêt à l’étape : %s. Journal : %s\n' "$STAGE" "${LOG:-non initialisé}" >&2
        if [[ -z $LOG ]]; then
            printf 'Arrêt avant installation : aucun paquet ni service modifié.\n' >&2
        else
            if [[ -f $STATE_DIR/settings ]]; then
                printf 'Reprise de cette installation : sudo bash install.sh --resume\n' >&2
            else
                printf 'Les modifications déjà effectuées sont conservées pour diagnostic.\n' >&2
            fi
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'printf "\nÉchec ligne %s (code %s), étape : %s\n" "$LINENO" "$?" "$STAGE" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

ask() {
    local target=$1 prompt=$2 fallback=${3-} value
    printf '%s' "$prompt" > /dev/tty
    if [[ -n $fallback ]]; then printf ' [%s]' "$fallback" > /dev/tty; fi
    printf ' : ' > /dev/tty
    IFS= read -r value < /dev/tty || die 'Saisie interrompue.'
    printf -v "$target" '%s' "${value:-$fallback}"
}
secret() {
    local target=$1 prompt=$2 value
    printf '%s : ' "$prompt" > /dev/tty
    IFS= read -rs value < /dev/tty || die 'Saisie interrompue.'
    printf '\n' > /dev/tty
    printf -v "$target" '%s' "$value"
}
yesno() {
    local answer
    while true; do
        ask answer "$1 (o/n)" "${2:-n}"
        case "$answer" in o|O|oui|y|Y) return 0;; n|N|non) return 1;; esac
    done
}
is_ipv4() {
    local address=$1 octet
    local -a octets
    [[ $address =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [[ $octet == 0 || $octet != 0* ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}
valid_address() {
    local address=$1
    if is_ipv4 "$address"; then return 0; fi
    [[ ${#address} -le 253 ]] &&
        [[ $address =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}
address() {
    local target=$1 label=$2 fallback=${3-} entered
    while true; do
        ask entered "$label (domaine ou IPv4, sans protocole ni port)" "$fallback"
        entered=${entered,,}
        if valid_address "$entered"; then
            printf -v "$target" '%s' "$entered"; return
        fi
        info 'Adresse invalide. Exemples : panel.example.com ou 203.0.113.10 (IPv4 uniquement pour les IP).'
    done
}
email() {
    local target=$1 label=$2 entered
    while true; do
        ask entered "$label"
        if [[ $entered =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
            printf -v "$target" '%s' "$entered"; return
        fi
    done
}
port() {
    local target=$1 label=$2 fallback=$3 entered
    while true; do
        ask entered "$label" "$fallback"
        if [[ $entered =~ ^[0-9]{1,5}$ ]] && ((10#$entered >= 1 && 10#$entered <= 65535)); then
            printf -v "$target" '%s' "$((10#$entered))"; return
        fi
    done
}
positive_integer() {
    local target=$1 label=$2 fallback=$3 entered
    while true; do
        ask entered "$label" "$fallback"
        if [[ $entered =~ ^[1-9][0-9]{0,8}$ ]]; then
            printf -v "$target" '%s' "$entered"; return
        fi
        info 'Saisir un entier positif (maximum 999999999).'
    done
}
download() {
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 \
        --max-time 900 --proto '=https' --tlsv1.2 "$1" -o "$2"
}

apt_update() {
    if [[ $APT_REFRESHED == 1 && ${1:-} != force ]]; then return 0; fi
    info 'Mise à jour de la liste des paquets APT…'
    apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=120 \
        -o APT::Update::Error-Mode=any update
    APT_REFRESHED=1
}
apt_install() {
    info "Installation des paquets APT : $*"
    apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=120 install -y --no-install-recommends "$@"
}

composer_run() {
    COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1 \
        "$PHP_BIN" /usr/local/bin/composer --no-interaction "$@"
}

repair_panel_runtime_permissions() {
    if (( PANEL )) && { [[ -f $STATE_DIR/panel-files.done ]] || (( DB_ONLY )); }; then
        local path
        for path in "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"; do
            [[ -d $path ]] || continue
            chown -R www-data:www-data "$path"
            chmod -R u=rwX,g=rX,o= "$path"
        done
    fi
}

nginx_modern_http2() {
    local version=${1#nginx/} major minor patch
    IFS=. read -r major minor patch <<< "$version"
    patch=${patch%%[^0-9]*}
    [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ && $patch =~ ^[0-9]+$ ]] || return 1
    (( major > 1 || (major == 1 && (minor > 25 || (minor == 25 && patch >= 1))) ))
}

docker_smoke_test() {
    if ! docker run --rm hello-world > "$DIAGNOSTICS/docker-container-test.log" 2>&1; then
        info "Le test hello-world a échoué (réseau Docker Hub ou exécution du conteneur). Détails : $DIAGNOSTICS/docker-container-test.log"
        info 'Docker répond à docker info ; l’installation continue, le démarrage des conteneurs reste à vérifier.'
    fi
}

state_save() {
    local name
    local -a names=(INSTALL_OS PANEL WINGS FIREWALL AUTO_LINK QUICK_MODE GAME_DB_ENABLED PANEL_DOMAIN WINGS_DOMAIN PANEL_URL WEB SSL
        PANEL_CERT PANEL_KEY WINGS_CERT WINGS_KEY LE_EMAIL SSH_PORT TIMEZONE
        DB_PASSWORD ADMIN_PASSWORD ADMIN_EMAIL ADMIN_USER ADMIN_FIRST ADMIN_LAST
        MAIL_MAILER SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_ENCRYPTION SMTP_FROM SMTP_NAME
        NODE_NAME LOCATION_SHORT NODE_MEMORY NODE_DISK WINGS_ARCH PANEL_TAG WINGS_TAG PHP_BIN
        WINGS_READY CREDENTIALS)
    : > "$STATE_DIR/settings.new"
    for name in "${names[@]}"; do printf '%s=%q\n' "$name" "${!name-}" >> "$STATE_DIR/settings.new"; done
    chmod 600 "$STATE_DIR/settings.new"
    mv -f "$STATE_DIR/settings.new" "$STATE_DIR/settings"
}
mark_done() {
    state_save
    touch "$STATE_DIR/$1.done"
}
run_step() {
    local step=$1
    shift
    if [[ -f $STATE_DIR/$step.done ]]; then info "Étape déjà terminée : $step"; return 0; fi
    STAGE=$step
    "$@"
    mark_done "$step"
}
resource_defaults() {
    local available_mib=$1 available_disk_mib=$2 reserve
    reserve=1024
    if (( PANEL )); then reserve=2048; fi
    DEFAULT_NODE_MEMORY=$((available_mib * 80 / 100))
    if (( available_mib - reserve < DEFAULT_NODE_MEMORY )); then DEFAULT_NODE_MEMORY=$((available_mib - reserve)); fi
    if (( DEFAULT_NODE_MEMORY < 1 )); then DEFAULT_NODE_MEMORY=1; fi
    DEFAULT_NODE_DISK=$((available_disk_mib * 80 / 100))
    if (( DEFAULT_NODE_DISK < 1 )); then DEFAULT_NODE_DISK=1; fi
}
detect_resources() {
    local available_kib=0 key value remainder disk
    while read -r key value remainder; do
        if [[ $key == MemAvailable: ]]; then available_kib=$value; break; fi
    done < /proc/meminfo
    : "$remainder"
    disk=$(df -Pm /var/lib | awk 'NR==2 {print $4}')
    [[ $available_kib =~ ^[0-9]+$ && $disk =~ ^[0-9]+$ ]] || die 'Impossible de déterminer les ressources disponibles.'
    resource_defaults "$((available_kib / 1024))" "$disk"
    info "Ressources libres détectées : $((available_kib / 1024)) Mio de RAM, $disk Mio sur /var/lib."
}

configure_os() {
    PHP_REPOSITORY=none
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:22.04) PHP_VERSION=8.3; PHP_REPOSITORY=ppa; OS_CODENAME=jammy;;
        ubuntu:24.04) PHP_VERSION=8.3; OS_CODENAME=noble;;
        debian:12|debian:12.*) PHP_VERSION=8.2; OS_CODENAME=bookworm;;
        debian:13|debian:13.*) PHP_VERSION=8.3; PHP_REPOSITORY=sury; OS_CODENAME=trixie;;
        *) die "OS non pris en charge : ${PRETTY_NAME:-${ID:-inconnu} ${VERSION_ID:-}}. Utiliser Debian 12/13 ou Ubuntu 22.04/24.04.";;
    esac
}

preflight() {
    STAGE=prérequis
    (( EUID == 0 )) || die 'Exécuter ce script en root.'
    [[ -r /etc/os-release ]] || die 'OS inconnu.'
    # shellcheck source=/dev/null
    . /etc/os-release
    configure_os
    [[ -d /run/systemd/system ]] || die 'systemd est requis (pas de conteneur minimal/WSL).'
    [[ -r /dev/tty && -w /dev/tty ]] || die 'Un terminal interactif est requis.'
    command -v apt-get >/dev/null || die 'APT est requis sur ce serveur Ubuntu/Debian.'
    LOG="/var/log/pterodactyl-install-$(date +%Y%m%d-%H%M%S)-$$.log"
    touch "$LOG"; chmod 600 "$LOG"
    exec > >(tee -a "$LOG") 2>&1
    if ! command -v flock >/dev/null || ! command -v awk >/dev/null || [[ ! -f /usr/share/zoneinfo/Europe/Paris ]]; then
        apt_update
        apt_install util-linux tzdata mawk
    fi
    exec 9>/run/pterodactyl-installer.lock
    flock -n 9 || die 'Une autre installation est déjà en cours.'
    TMP=$(mktemp -d /tmp/ptero-install.XXXXXXXX)
    [[ ! -L $STATE_DIR ]] || die 'Le dossier d’état ne doit pas être un lien symbolique.'
    if [[ -e $STATE_DIR ]]; then
        [[ $(stat -c %u "$STATE_DIR") == 0 && $(stat -c %a "$STATE_DIR") == 700 ]] || die 'Le dossier d’état doit appartenir à root et être en mode 700.'
    fi
    install -d -m 700 "$STATE_DIR"
    DIAGNOSTICS="$STATE_DIR/diagnostics-$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 700 "$DIAGNOSTICS"
    info "OS détecté : $PRETTY_NAME ; PHP $PHP_VERSION ($PHP_REPOSITORY) ; journal root : $LOG"
}

questions_quick() {
    WEB=nginx FIREWALL=0 TIMEZONE=Europe/Paris
    ADMIN_USER=admin ADMIN_FIRST=Admin ADMIN_LAST=Pterodactyl
    DB_PASSWORD='' ADMIN_PASSWORD=''
    SMTP_HOST='' SMTP_PORT=587 SMTP_USER='' SMTP_PASSWORD='' SMTP_ENCRYPTION=tls
    SMTP_NAME=Pterodactyl MAIL_MAILER=log
    if (( PANEL )); then
        address PANEL_DOMAIN 'Adresse du Panel'
        email ADMIN_EMAIL 'Email administrateur'
        SMTP_FROM=$ADMIN_EMAIL
        LE_EMAIL=$ADMIN_EMAIL
        if (( WINGS )); then WINGS_DOMAIN=$PANEL_DOMAIN; fi
    else
        address WINGS_DOMAIN 'Adresse de Wings'
        address PANEL_DOMAIN 'Adresse du Panel distant'
    fi
    local local_address=$PANEL_DOMAIN
    if (( PANEL == 0 )); then local_address=$WINGS_DOMAIN; fi
    SSL=le
    if is_ipv4 "$local_address"; then SSL=none; fi
    if (( PANEL )); then
        PANEL_URL="http://$PANEL_DOMAIN"
        [[ $SSL == none ]] || PANEL_URL="https://$PANEL_DOMAIN"
    else
        local https_default=o
        if is_ipv4 "$PANEL_DOMAIN"; then https_default=n; fi
        if yesno 'Le Panel distant utilise HTTPS' "$https_default"; then
            PANEL_URL="https://$PANEL_DOMAIN"
            [[ $SSL != none ]] || die 'Panel HTTPS : utiliser le mode avancé pour fournir un certificat Wings couvrant cette IP.'
        else PANEL_URL="http://$PANEL_DOMAIN"; fi
        if [[ $SSL == le ]]; then email LE_EMAIL 'Email Let’s Encrypt'; fi
    fi
    AUTO_LINK=0
    if (( WINGS )); then
        NODE_NAME=Node-1 LOCATION_SHORT=local
        detect_resources
        NODE_MEMORY=$DEFAULT_NODE_MEMORY NODE_DISK=$DEFAULT_NODE_DISK
        if (( PANEL )); then
            AUTO_LINK=1
            if yesno 'Préparer aussi MariaDB pour les bases des jeux' o; then GAME_DB_ENABLED=1; fi
        elif [[ $PANEL_URL == https://* ]]; then
            secret APPLICATION_KEY 'Clé Application API (vide = collage manuel du YAML)'
            if [[ -n $APPLICATION_KEY ]]; then AUTO_LINK=1; fi
        fi
    fi
    info "Mode rapide : Nginx, admin, mots de passe générés, fuseau $TIMEZONE, SMTP et UFW inchangés."
    info "Panel : $PANEL_URL ; SSL : $SSL ; DB jeux : $GAME_DB_ENABLED."
    if [[ $SSL == le ]]; then
        info 'Le DNS doit pointer vers ce serveur et le port 80 être accessible.'
        yesno 'Installer et accepter les conditions Let’s Encrypt https://letsencrypt.org/repository/' o || exit 0
    else
        yesno 'Lancer l’installation avec ces paramètres' o || exit 0
    fi
}

questions() {
    STAGE=questionnaire
    local choice username confirm ssh_default ssl_default=1 link_available=1 panel_https_default=o
    printf '\n1) Panel uniquement\n2) Wings uniquement\n3) Panel + Wings\n4) Configurer MariaDB pour les jeux (Panel + Wings déjà installés ici)\n0) Quitter\n'
    while true; do
        ask choice 'Installation souhaitée'
        case "$choice" in 1) PANEL=1; break;; 2) WINGS=1; break;; 3) PANEL=1; WINGS=1; break;; 4) DB_ONLY=1; return 0;; 0) exit 0;; esac
    done
    while true; do
        ask choice 'Configuration : 1=rapide (recommandé), 2=avancée' 1
        case "$choice" in 1) QUICK_MODE=1; questions_quick; return 0;; 2) QUICK_MODE=0; break;; esac
    done
    (( PANEL == 0 )) || address PANEL_DOMAIN 'Adresse du Panel'
    if (( WINGS )); then
        address WINGS_DOMAIN 'Adresse de Wings (peut être identique à celle du Panel)' "$PANEL_DOMAIN"
    fi
    if (( PANEL )); then
        while true; do
            ask choice 'Serveur web : 1=Nginx, 2=Apache' 1
            case "$choice" in 1) WEB=nginx; break;; 2) WEB=apache2; break;; esac
        done
    fi
    if is_ipv4 "$PANEL_DOMAIN" || is_ipv4 "$WINGS_DOMAIN"; then
        ssl_default=3
        info 'Accès par IP : HTTP sans SSL proposé par défaut. Un certificat existant doit couvrir l’IP.'
    fi
    while true; do
        ask choice 'SSL (pour les composants choisis) : 1=Let’s Encrypt, 2=existant, 3=aucun' "$ssl_default"
        case "$choice" in
            1)
                if is_ipv4 "$PANEL_DOMAIN" || is_ipv4 "$WINGS_DOMAIN"; then
                    info 'Le mode Let’s Encrypt de ce script nécessite un domaine. Choisir 2 ou 3 pour une IP.'
                else SSL=le; break; fi;;
            2) SSL=existing; break;;
            3) SSL=none; break;;
        esac
    done
    if [[ $SSL == le ]]; then
        email LE_EMAIL 'Email Let’s Encrypt'
        info 'Les DNS A/AAAA doivent pointer vers ce serveur ; le port 80 doit être accessible publiquement.'
        yesno 'Accepter les conditions Let’s Encrypt https://letsencrypt.org/repository/' n || die 'Conditions non acceptées.'
    elif [[ $SSL == existing ]]; then
        if (( PANEL )); then
            ask PANEL_CERT 'Chemin absolu du fullchain PEM du Panel'
            ask PANEL_KEY 'Chemin absolu de la clé privée PEM du Panel (sans passphrase)'
        fi
        if (( WINGS )); then
            ask WINGS_CERT 'Chemin absolu du fullchain PEM de Wings'
            ask WINGS_KEY 'Chemin absolu de la clé privée PEM de Wings (sans passphrase)'
        fi
    fi
    if (( PANEL )); then
        PANEL_URL="http://$PANEL_DOMAIN"
        [[ $SSL == none ]] || PANEL_URL="https://$PANEL_DOMAIN"
        secret DB_PASSWORD 'Mot de passe SQL (vide = génération aléatoire)'
        email ADMIN_EMAIL 'Email du premier administrateur'
        while true; do
            ask username 'Nom d’utilisateur administrateur' admin
            if [[ $username =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$ ]]; then ADMIN_USER=$username; break; fi
        done
        ask ADMIN_FIRST 'Prénom' Admin
        ask ADMIN_LAST 'Nom' Pterodactyl
        while true; do
            secret ADMIN_PASSWORD 'Mot de passe administrateur (vide = génération aléatoire, sinon 16 caractères minimum)'
            [[ -n $ADMIN_PASSWORD ]] || break
            if (( ${#ADMIN_PASSWORD} >= 16 )); then
                secret confirm 'Confirmer le mot de passe'
                [[ $confirm != "$ADMIN_PASSWORD" ]] || break
            fi
            info 'Mot de passe trop court ou confirmation différente.'
        done
        while true; do
            ask TIMEZONE 'Fuseau horaire IANA' Europe/Paris
            if [[ $TIMEZONE != /* && $TIMEZONE != *..* && -f /usr/share/zoneinfo/$TIMEZONE ]]; then break; fi
        done
        SMTP_HOST='' SMTP_PORT=587 SMTP_USER='' SMTP_PASSWORD='' SMTP_ENCRYPTION=tls
        SMTP_FROM=$ADMIN_EMAIL SMTP_NAME=Pterodactyl MAIL_MAILER=log
        if yesno 'Configurer SMTP maintenant' n; then
            MAIL_MAILER=smtp
            while [[ -z $SMTP_HOST ]]; do ask SMTP_HOST 'Hôte SMTP'; done
            port SMTP_PORT 'Port SMTP' 587
            ask SMTP_USER 'Utilisateur SMTP (vide = sans authentification)'
            secret SMTP_PASSWORD 'Mot de passe SMTP (vide si absent)'
            while true; do
                ask SMTP_ENCRYPTION 'Chiffrement SMTP : tls, ssl ou none' tls
                [[ $SMTP_ENCRYPTION =~ ^(tls|ssl|none)$ ]] && break
            done
            email SMTP_FROM 'Adresse expéditrice'
            ask SMTP_NAME 'Nom de l’expéditeur' Pterodactyl
        fi
    else
        info 'Le Panel distant doit déjà être installé.'
        address PANEL_DOMAIN 'Adresse du Panel distant'
        if is_ipv4 "$PANEL_DOMAIN"; then panel_https_default=n; fi
        if yesno 'Le Panel distant utilise HTTPS' "$panel_https_default"; then
            PANEL_URL="https://$PANEL_DOMAIN"
            [[ $SSL != none ]] || die 'Un Panel HTTPS nécessite Wings avec TLS.'
        else PANEL_URL="http://$PANEL_DOMAIN"; fi
    fi
    if (( WINGS && PANEL == 0 )) && [[ $PANEL_URL == http://* ]]; then
        link_available=0
        info 'Panel distant en HTTP : liaison par collage du YAML, pour ne pas transmettre de clé administrateur sans chiffrement.'
    fi
    if (( WINGS && link_available )) && yesno 'Créer et relier automatiquement le nœud Wings dans le Panel' o; then
        AUTO_LINK=1
        if (( PANEL == 0 )); then
            [[ $PANEL_URL == https://* ]] || die 'La liaison via API distante exige HTTPS pour protéger la clé administrateur.'
            info 'Panel → Administration → Application API : clé avec Locations et Nodes en lecture/écriture.'
            info 'La clé sera utilisée uniquement pendant l’installation, sans être enregistrée.'
            while [[ -z $APPLICATION_KEY ]]; do secret APPLICATION_KEY 'Clé Application API du Panel distant (pas une clé Client API)'; done
        fi
        while true; do
            ask NODE_NAME 'Nom du nouveau nœud' Node-1
            [[ $NODE_NAME =~ ^[a-zA-Z0-9_.\ -]{1,100}$ ]] && break
        done
        while true; do
            ask LOCATION_SHORT 'Code de localisation (créé si absent)' local
            [[ $LOCATION_SHORT =~ ^[a-zA-Z0-9_.-]{1,60}$ ]] && break
        done
        detect_resources
        positive_integer NODE_MEMORY 'RAM allouable aux jeux, en Mio (réserve système incluse dans la suggestion)' "$DEFAULT_NODE_MEMORY"
        positive_integer NODE_DISK 'Disque allouable aux jeux, en Mio (20 % libres conservés dans la suggestion)' "$DEFAULT_NODE_DISK"
    fi
    if yesno 'Configurer et activer UFW (préserve les règles existantes)' n; then
        FIREWALL=1
        ssh_default=22
        if [[ -n ${SSH_CONNECTION:-} ]]; then ssh_default=${SSH_CONNECTION##* }; fi
        port SSH_PORT 'Port SSH réel à préserver (vérifiez aussi les autres ports SSH)' "$ssh_default"
    fi
    if (( PANEL && WINGS )); then
        if yesno 'Préparer aussi MariaDB pour les bases des jeux' o; then GAME_DB_ENABLED=1; fi
    fi
    printf '\nOS : %s ; Panel : %s ; Wings : %s ; web : %s ; SSL : %s\n' "$PRETTY_NAME" "$PANEL" "$WINGS" "${WEB:-aucun}" "$SSL"
    info 'Les ports 80/443 (web), 8080 (Wings API) et 2022 (SFTP) seront utilisés selon le mode.'
    yesno 'Lancer l’installation sur ce serveur vierge' n || exit 0
}

check_free() {
    local p=$1
    if [[ -n $(ss -H -ltn "sport = :$p") ]]; then die "Le port TCP $p est déjà occupé."; fi
}
base_packages() {
    STAGE='connectivité et dépendances communes'
    apt_update
    apt_install ca-certificates apt-transport-https curl gnupg openssl \
        tar unzip git python3 iproute2 tzdata util-linux coreutils findutils \
        grep sed lsb-release nano sudo
    download https://api.github.com "$TMP/github-connectivity"
    if (( PANEL )); then
        [[ ! -e $PANEL_DIR ]] || die "$PANEL_DIR existe : installation neuve uniquement."
        [[ ! -e /etc/systemd/system/pteroq.service && ! -e /etc/cron.d/pterodactyl ]] || die 'Configuration Panel déjà présente.'
        check_free 80; check_free 443; check_free 3306; check_free 6379
        [[ ! -e /etc/nginx/sites-available/pterodactyl.conf && ! -e /etc/apache2/sites-available/pterodactyl.conf ]] || die 'Vhost Pterodactyl déjà présent.'
    elif [[ $SSL == le ]]; then check_free 80; fi
    if (( WINGS )); then
        [[ ! -e /usr/local/bin/wings && ! -e /etc/pterodactyl && ! -e /etc/systemd/system/wings.service ]] || die 'Wings ou sa configuration existe déjà.'
        check_free 8080; check_free 2022
        case "$(uname -m)" in x86_64) WINGS_ARCH=amd64;; aarch64|arm64) WINGS_ARCH=arm64;; *) die 'Wings : architecture non prise en charge (amd64/arm64 seulement).';; esac
        local virt
        virt=$(systemd-detect-virt || true)
        case "$virt" in lxc|openvz) info "Virtualisation $virt : Docker nécessite le support de la virtualisation imbriquée.";; esac
        local package
        for package in docker.io docker-ce podman-docker containerd runc; do
            if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
                die "$package est déjà installé : installation neuve requise."
            fi
        done
    fi
    if [[ -z $DB_PASSWORD ]] && (( PANEL )); then DB_PASSWORD=$(openssl rand -hex 24); fi
    if [[ -z $ADMIN_PASSWORD ]] && (( PANEL )); then ADMIN_PASSWORD="Aa1!$(openssl rand -hex 24)"; fi
}

release() {
    local repo=$1 override=$2 target=$3 tag page
    if [[ -n $override ]]; then
        [[ $override =~ ^v1\.[0-9]+\.[0-9]+$ ]] || die 'Tag attendu : v1.x.y stable.'
        download "https://api.github.com/repos/pterodactyl/$repo/releases/tags/$override" "$TMP/release.json"
    else
        for page in 1 2 3 4 5; do
            download "https://api.github.com/repos/pterodactyl/$repo/releases?per_page=100&page=$page" "$TMP/release.json"
            tag=$(python3 - "$TMP/release.json" <<'PY'
import json, re, sys
r = json.load(open(sys.argv[1]))
tags = [x['tag_name'] for x in r if not x['draft'] and not x['prerelease'] and re.fullmatch(r'v1\.\d+\.\d+', x['tag_name'])]
print(max(tags, key=lambda t: tuple(map(int, t[1:].split('.')))) if tags else '')
PY
)
            [[ -z $tag ]] || break
        done
        [[ -n $tag ]] || die "Aucune release stable 1.x trouvée pour $repo (épinglez un tag)."
        download "https://api.github.com/repos/pterodactyl/$repo/releases/tags/$tag" "$TMP/release.json"
    fi
    tag=$(python3 - "$TMP/release.json" <<'PY'
import json, re, sys
r = json.load(open(sys.argv[1]))
assert not r['draft'] and not r['prerelease'] and re.fullmatch(r'v1\.\d+\.\d+', r['tag_name']), 'Release non stable'
print(r['tag_name'])
PY
)
    printf -v "$target" '%s' "$tag"
    ok "$repo : $tag"
}

firewall() {
    STAGE=pare-feu
    if (( FIREWALL )); then
        apt_install ufw
        ufw allow "$SSH_PORT/tcp"
        if (( PANEL )) || [[ $SSL == le ]]; then ufw allow 80/tcp; fi
        if (( PANEL )) && [[ $SSL != none ]]; then ufw allow 443/tcp; fi
        if (( WINGS )); then ufw allow 8080/tcp; ufw allow 2022/tcp; fi
        ufw --force enable
    else
        info 'Pare-feu inchangé : ouvrir les ports nécessaires dans le pare-feu local et celui de l’hébergeur.'
    fi
}

validate_cert() {
    local host=$1 cert=$2 key=$3 a b
    [[ $cert =~ ^/[a-zA-Z0-9_./-]+$ && $key =~ ^/[a-zA-Z0-9_./-]+$ ]] || die 'Chemin PEM invalide (sans espace ni caractère spécial).'
    [[ -f $cert && -f $key ]] || die "Certificat/clé introuvable pour $host."
    openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null || die "Certificat expiré ou expirant pour $host."
    if is_ipv4 "$host"; then
        openssl x509 -in "$cert" -noout -checkip "$host" >/dev/null || die "Le certificat ne couvre pas l’IP $host."
    else
        openssl x509 -in "$cert" -noout -checkhost "$host" >/dev/null || die "Le certificat ne couvre pas $host."
    fi
    a=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)
    b=$(openssl pkey -in "$key" -passin pass: -pubout -outform DER | openssl dgst -sha256)
    [[ $a == "$b" ]] || die "La clé ne correspond pas au certificat de $host."
}
certificates() {
    STAGE=certificats
    if [[ $SSL == le ]]; then
        apt_install certbot
        local host previous=''
        local -a hosts=()
        if (( PANEL )); then hosts+=("$PANEL_DOMAIN"); fi
        if (( WINGS )); then hosts+=("$WINGS_DOMAIN"); fi
        for host in "${hosts[@]}"; do
            [[ $host != "$previous" ]] || continue
            previous=$host
            getent ahosts "$host" >/dev/null || die "DNS introuvable pour $host."
            certbot certonly --standalone --preferred-challenges http --non-interactive \
                --agree-tos --email "$LE_EMAIL" --cert-name "$host" -d "$host"
        done
        if (( PANEL )); then PANEL_CERT="/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem"; PANEL_KEY="/etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem"; fi
        if (( WINGS )); then WINGS_CERT="/etc/letsencrypt/live/$WINGS_DOMAIN/fullchain.pem"; WINGS_KEY="/etc/letsencrypt/live/$WINGS_DOMAIN/privkey.pem"; fi
        install -d -m 755 /etc/letsencrypt/renewal-hooks/{pre,post,deploy}
        cat > /etc/letsencrypt/renewal-hooks/pre/50-pterodactyl <<'HOOK'
#!/usr/bin/env bash
set -eu
install -d -m 700 /run/pterodactyl-certbot
for service in nginx apache2; do
    if systemctl is-active --quiet "$service"; then
        touch "/run/pterodactyl-certbot/$service"
        systemctl stop "$service"
    fi
done
HOOK
        cat > /etc/letsencrypt/renewal-hooks/post/50-pterodactyl <<'HOOK'
#!/usr/bin/env bash
set -eu
for service in nginx apache2; do
    if [[ -f /run/pterodactyl-certbot/$service ]]; then
        systemctl start "$service"
        rm -f "/run/pterodactyl-certbot/$service"
    fi
done
HOOK
        cat > /etc/letsencrypt/renewal-hooks/deploy/50-pterodactyl-wings <<'HOOK'
#!/usr/bin/env bash
set -eu
if systemctl is-active --quiet wings; then systemctl restart wings; fi
HOOK
        chmod 755 /etc/letsencrypt/renewal-hooks/{pre,post,deploy}/50-pterodactyl*
        systemctl enable --now certbot.timer
    fi
    if [[ $SSL != none ]]; then
        if (( PANEL )); then validate_cert "$PANEL_DOMAIN" "$PANEL_CERT" "$PANEL_KEY"; fi
        if (( WINGS )); then validate_cert "$WINGS_DOMAIN" "$WINGS_CERT" "$WINGS_KEY"; fi
    fi
}

panel_dependencies() {
    STAGE='dépendances Panel'
    if [[ $PHP_REPOSITORY == ppa ]]; then
        apt_install software-properties-common
        add-apt-repository -y ppa:ondrej/php
        apt_update force
    elif [[ $PHP_REPOSITORY == sury ]]; then
        download https://packages.sury.org/debsuryorg-archive-keyring.deb "$TMP/sury-keyring.deb"
        dpkg -i "$TMP/sury-keyring.deb"
        printf 'deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n' \
            "$OS_CODENAME" > /etc/apt/sources.list.d/pterodactyl-sury-php.list
        chmod 644 /etc/apt/sources.list.d/pterodactyl-sury-php.list
        apt_update force
    fi
    apt_install "php$PHP_VERSION"-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,opcache} \
        mariadb-server redis-server cron "$WEB"
    PHP_BIN="/usr/bin/php$PHP_VERSION"
    cat > "/etc/php/$PHP_VERSION/fpm/conf.d/99-pterodactyl.ini" <<'INI'
upload_max_filesize = 100M
post_max_size = 100M
max_execution_time = 300
INI
    systemctl enable --now mariadb redis-server cron "php$PHP_VERSION-fpm"
    systemctl restart "php$PHP_VERSION-fpm"
    cat > /etc/mysql/mariadb.conf.d/60-pterodactyl-local.cnf <<'CNF'
[mysqld]
bind-address = 127.0.0.1
CNF
    systemctl restart mariadb
    download https://getcomposer.org/installer "$TMP/composer-setup.php"
    download https://composer.github.io/installer.sig "$TMP/composer.sig"
    # Le fragment PHP doit conserver $argv littéralement.
    # shellcheck disable=SC2016
    [[ $("$PHP_BIN" -r 'echo hash_file("sha384", $argv[1]);' "$TMP/composer-setup.php") == "$(cat "$TMP/composer.sig")" ]] || die 'Signature de l’installateur Composer incorrecte.'
    "$PHP_BIN" "$TMP/composer-setup.php" --2 --install-dir=/usr/local/bin --filename=composer
}

database() {
    STAGE='base de données'
    local exists escaped
    if [[ ! -f $STATE_DIR/database.claimed ]]; then
        exists=$(mariadb --batch --skip-column-names -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='panel'; SELECT COUNT(*) FROM mysql.user WHERE User='pterodactyl';")
        [[ $exists == $'0\n0' ]] || die 'Base panel ou utilisateur pterodactyl déjà présent ; aucun écrasement effectué.'
        touch "$STATE_DIR/database.claimed"
    fi
    escaped=${DB_PASSWORD//\'/\'\'}
    mariadb > "$TMP/sql-output" 2>&1 <<SQL
SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES';
CREATE DATABASE IF NOT EXISTS panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$escaped';
ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$escaped';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';
SQL
    unset escaped
}

panel_install() {
    STAGE='fichiers et environnement Panel'
    if [[ ! -f $STATE_DIR/panel-files.done ]]; then
        download "https://github.com/pterodactyl/panel/releases/download/$PANEL_TAG/panel.tar.gz" "$TMP/panel.tar.gz"
        install -d -m 755 "$PANEL_DIR"
        tar -xzf "$TMP/panel.tar.gz" --no-same-owner --exclude=.env -C "$PANEL_DIR"
        mark_done panel-files
    fi
    cd "$PANEL_DIR"
    if [[ ! -f $STATE_DIR/panel-env.done ]]; then
    [[ -f .env ]] || cp .env.example .env
    export PANEL_URL TIMEZONE DB_PASSWORD ADMIN_EMAIL MAIL_MAILER SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_ENCRYPTION SMTP_FROM SMTP_NAME
    python3 - <<'PY'
import ipaddress, os, re
from pathlib import Path
e = os.environ
settings = dict(APP_ENV='production', APP_DEBUG='false', APP_URL=e['PANEL_URL'],
    APP_TIMEZONE=e['TIMEZONE'], APP_SERVICE_AUTHOR=e['ADMIN_EMAIL'],
    APP_LOCALE='en', APP_NAME='Pterodactyl', APP_TELEMETRY_ENABLED='false',
    DB_CONNECTION='mysql', DB_HOST='127.0.0.1', DB_PORT='3306', DB_DATABASE='panel',
    DB_USERNAME='pterodactyl', DB_PASSWORD=e['DB_PASSWORD'], CACHE_DRIVER='redis',
    CACHE_STORE='redis', SESSION_DRIVER='redis', QUEUE_CONNECTION='redis', QUEUE_DRIVER='redis',
    REDIS_HOST='127.0.0.1', REDIS_PORT='6379', MAIL_MAILER=e['MAIL_MAILER'],
    MAIL_DRIVER=e['MAIL_MAILER'], MAIL_HOST=e['SMTP_HOST'], MAIL_PORT=e['SMTP_PORT'],
    MAIL_USERNAME=e['SMTP_USER'], MAIL_PASSWORD=e['SMTP_PASSWORD'],
    MAIL_FROM_ADDRESS=e['SMTP_FROM'], MAIL_FROM_NAME=e['SMTP_NAME'])
mail_host = e['PANEL_URL'].split('://', 1)[1]
try:
    settings['MAIL_EHLO_DOMAIN'] = '[' + str(ipaddress.IPv4Address(mail_host)) + ']'
except ipaddress.AddressValueError:
    settings['MAIL_EHLO_DOMAIN'] = mail_host
# phpdotenv : protéger antislash, guillemet et interpolation ${...}.
def quoted(v):
    if any(ord(c) < 32 or ord(c) == 127 for c in v):
        raise ValueError('Caractère de contrôle interdit dans la configuration')
    return '"' + v.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$') + '"'
p = Path('.env')
text = p.read_text()
for key, value in settings.items():
    line = key + '=' + quoted(value)
    pattern = r'^' + re.escape(key) + r'=.*$'
    text = re.sub(pattern, lambda m: line, text, flags=re.M) if re.search(pattern, text, re.M) else text + '\n' + line
# Remplacer aussi les valeurs déjà présentes ; éviter les clés dupliquées.
for key, value in {'REDIS_PASSWORD': 'null', 'MAIL_ENCRYPTION': 'null' if e['SMTP_ENCRYPTION'] == 'none' else e['SMTP_ENCRYPTION']}.items():
    pattern = r'^' + key + r'=.*$'
    line = key + '=' + value
    text = re.sub(pattern, lambda m: line, text, flags=re.M) if re.search(pattern, text, re.M) else text + '\n' + line
temporary = p.with_name('.env.installing')
temporary.write_text(text + '\n')
temporary.chmod(0o640)
temporary.replace(p)
PY
    mark_done panel-env
    fi
    unset DB_PASSWORD SMTP_PASSWORD
    composer_run install --no-dev --optimize-autoloader
    composer_run check-platform-reqs --no-dev
    if ! grep -Eq '^APP_KEY="?base64:[A-Za-z0-9+/=]+' .env; then
        [[ ! -f $STATE_DIR/panel.env.backup ]] || die 'APP_KEY absente ou modifiée : restaurer la copie privée panel.env.backup, ne pas régénérer la clé.'
        "$PHP_BIN" artisan key:generate --force --no-interaction
    fi
    install -m 600 .env "$STATE_DIR/panel.env.backup"
    STAGE='migrations et administrateur'
    run_step panel-migrations "$PHP_BIN" artisan migrate --seed --force --no-interaction
    # Nécessaire aussi à la reprise : le bloc de génération .env peut être sauté.
    export ADMIN_EMAIL ADMIN_PASSWORD ADMIN_USER ADMIN_FIRST ADMIN_LAST
    if [[ ! -f $STATE_DIR/panel-admin.done ]]; then
    "$PHP_BIN" > "$TMP/admin-output" 2>&1 <<'PHP'
<?php
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$existing = Pterodactyl\Models\User::where('email', getenv('ADMIN_EMAIL'))->orWhere('username', getenv('ADMIN_USER'))->first();
if ($existing) {
    if ($existing->email !== getenv('ADMIN_EMAIL') || $existing->username !== getenv('ADMIN_USER') ||
        !$existing->root_admin || !$app->make(Illuminate\Contracts\Hashing\Hasher::class)->check(getenv('ADMIN_PASSWORD'), $existing->password)) {
        throw new RuntimeException('Compte existant différent : arrêt sans modification.');
    }
} else {
$app->make(Pterodactyl\Services\Users\UserCreationService::class)->handle([
    'email' => getenv('ADMIN_EMAIL'), 'username' => getenv('ADMIN_USER'),
    'name_first' => getenv('ADMIN_FIRST'), 'name_last' => getenv('ADMIN_LAST'),
    'password' => getenv('ADMIN_PASSWORD'), 'root_admin' => true,
]);
}
PHP
    CREDENTIALS="$STATE_DIR/credentials.txt"
    {
        printf 'Panel : %s\nEmail : %s\nUtilisateur : %s\nMot de passe : %s\n' "$PANEL_URL" "$ADMIN_EMAIL" "$ADMIN_USER" "$ADMIN_PASSWORD"
        printf '\nBase SQL : panel ; utilisateur : pterodactyl@127.0.0.1\n'
        printf 'Mot de passe SQL et APP_KEY : /var/www/pterodactyl/.env\n'
        printf 'Sauvegarder .env (notamment APP_KEY) hors du serveur avec la base et les données.\n'
    } > "$CREDENTIALS"
    chmod 600 "$CREDENTIALS"
    mark_done panel-admin
    fi
    unset ADMIN_PASSWORD
    chown -R www-data:www-data "$PANEL_DIR"
    chmod -R u=rwX,go=rX "$PANEL_DIR"
    chmod 640 "$PANEL_DIR/.env"
    "$PHP_BIN" artisan config:clear --no-interaction
    repair_panel_runtime_permissions
}

panel_services() {
    STAGE='services et cron Panel'
    cat > /etc/systemd/system/pteroq.service <<UNIT
[Unit]
Description=Pterodactyl queue worker
After=network-online.target mariadb.service redis-server.service
Wants=network-online.target
StartLimitIntervalSec=180
StartLimitBurst=30

[Service]
User=www-data
Group=www-data
WorkingDirectory=$PANEL_DIR
ExecStart=$PHP_BIN $PANEL_DIR/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    printf '* * * * * www-data %s %s/artisan schedule:run >> /dev/null 2>&1\n' "$PHP_BIN" "$PANEL_DIR" > /etc/cron.d/pterodactyl
    chmod 644 /etc/cron.d/pterodactyl
    systemctl daemon-reload
    systemctl enable --now pteroq
}

webserver() {
    STAGE='configuration web'
    local listen='listen 80;' redirect='' tls='' http2='' version
    if [[ $SSL != none ]]; then
        listen='listen 443 ssl http2;'
        if [[ $WEB == nginx ]]; then
            version=$(nginx -v 2>&1)
            version=${version##*nginx/}
            if nginx_modern_http2 "$version"; then
                listen='listen 443 ssl;'
                http2='http2 on;'
            fi
        fi
        tls="ssl_certificate $PANEL_CERT;
    ssl_certificate_key $PANEL_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;"
        redirect="server {
    listen 80;
    server_name $PANEL_DOMAIN;
    return 301 https://\$host\$request_uri;
}"
    fi
    if [[ $WEB == nginx ]]; then
        cat > /etc/nginx/sites-available/pterodactyl.conf <<NGINX
$redirect
server {
    $listen
    $http2
    server_name $PANEL_DOMAIN;
    root $PANEL_DIR/public;
    index index.php;
    $tls
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
    access_log /var/log/nginx/pterodactyl-access.log;
    error_log /var/log/nginx/pterodactyl-error.log;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm.sock;
        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
    }
    location ~ /\. { deny all; }
}
NGINX
        rm -f /etc/nginx/sites-enabled/default
        ln -sfn /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
        nginx -t
    else
        a2enmod rewrite proxy_fcgi setenvif headers
        a2enconf "php$PHP_VERSION-fpm"
        a2dissite 000-default default-ssl 2>/dev/null || true
        local webport=80
        if [[ $SSL != none ]]; then
            a2enmod ssl
            webport=443
            cat > /etc/apache2/sites-available/pterodactyl.conf <<APACHE
<VirtualHost *:80>
    ServerName $PANEL_DOMAIN
    Redirect permanent / https://$PANEL_DOMAIN/
</VirtualHost>
APACHE
        else : > /etc/apache2/sites-available/pterodactyl.conf; fi
        cat >> /etc/apache2/sites-available/pterodactyl.conf <<APACHE
<VirtualHost *:$webport>
    ServerName $PANEL_DOMAIN
    DocumentRoot $PANEL_DIR/public
    DirectoryIndex index.php
    AllowEncodedSlashes NoDecode
    LimitRequestBody 104857600
    <Directory $PANEL_DIR/public>
        AllowOverride All
        Options -Indexes +FollowSymLinks
        Require all granted
    </Directory>
    <FilesMatch "\\.php$">
        SetHandler "proxy:unix:/run/php/php$PHP_VERSION-fpm.sock|fcgi://localhost/"
    </FilesMatch>
    Header always set X-Content-Type-Options "nosniff"
    ErrorLog /var/log/apache2/pterodactyl-error.log
    CustomLog /var/log/apache2/pterodactyl-access.log combined
APACHE
        if [[ $SSL != none ]]; then
            cat >> /etc/apache2/sites-available/pterodactyl.conf <<APACHE
    SSLEngine on
    SSLCertificateFile $PANEL_CERT
    SSLCertificateKeyFile $PANEL_KEY
    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
APACHE
        fi
        printf '</VirtualHost>\n' >> /etc/apache2/sites-available/pterodactyl.conf
        a2ensite pterodactyl
        apache2ctl configtest
    fi
    systemctl enable "$WEB"
    systemctl restart "$WEB"
}

docker_install() {
    STAGE=Docker
    install -d -m 755 /etc/apt/keyrings
    download "https://download.docker.com/linux/$ID/gpg" /etc/apt/keyrings/docker.asc
    chmod 644 /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<DOCKER
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $OS_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER
    chmod 644 /etc/apt/sources.list.d/docker.sources
    apt_update force
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin python3-yaml
    systemctl enable --now docker
    docker info >/dev/null
    docker_smoke_test
}

# Instance MariaDB dédiée aux jeux : volume persistant et port 3307 lié
# uniquement à la passerelle privée du réseau Docker de Wings. La base du
# Panel, sur MariaDB système/3306, conserve sa configuration et ses comptes.
configure_game_databases() {
    STAGE='configuration MariaDB des jeux'
    [[ -f $PANEL_DIR/artisan && -f /etc/pterodactyl/config.yml ]] || die 'Installer le Panel et configurer Wings sur cette machine avant l’option DB.'
    PANEL=1
    command -v docker >/dev/null || die 'Docker doit être installé sur cette machine.'
    PHP_BIN="/usr/bin/php$PHP_VERSION"
    [[ -x $PHP_BIN ]] || die "PHP $PHP_VERSION introuvable pour le Panel local."
    docker info >/dev/null
    apt_update
    apt_install python3-yaml openssl
    local metadata
    metadata=$(python3 - <<'PY'
import re, uuid, yaml
from pathlib import Path
c = yaml.safe_load(Path('/etc/pterodactyl/config.yml').read_text())
network = c.get('docker', {}).get('network', {}).get('name', 'pterodactyl_nw')
assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,62}', network), 'Nom du réseau Docker invalide'
print(network, uuid.UUID(c['uuid']))
PY
)
    read -r GAME_DB_NETWORK GAME_DB_NODE_UUID <<< "$metadata"
    docker network inspect "$GAME_DB_NETWORK" > "$TMP/game-network.json"
    GAME_DB_GATEWAY=$(python3 - "$TMP/game-network.json" <<'PY'
import ipaddress, json, sys
n = json.load(open(sys.argv[1]))[0]
assert n['Driver'] == 'bridge', 'L’option DB nécessite le réseau bridge de Wings'
gateways = [ipaddress.ip_address(x['Gateway']) for x in n['IPAM']['Config'] if x.get('Gateway')]
gateway = next(x for x in gateways if x.version == 4 and x.is_private and not x.is_loopback)
print(gateway)
PY
)
    local container=ptero-installer-game-db volume=ptero-installer-game-db
    local envfile=$STATE_DIR/game-db.env root_password='' key value attempt ready=0
    if [[ ! -e $envfile ]]; then
        {
            printf 'MARIADB_ROOT_PASSWORD=%s\n' "$(openssl rand -hex 32)"
            printf 'MARIADB_ROOT_HOST=localhost\n'
            printf 'GAME_DB_PASSWORD=%s\n' "$(openssl rand -hex 32)"
        } > "$envfile.new"
        chmod 600 "$envfile.new"
        mv "$envfile.new" "$envfile"
    fi
    [[ ! -L $envfile && $(stat -c %a "$envfile") == 600 && $(stat -c %u "$envfile") == 0 ]] || die 'Fichier des identifiants DB non sûr.'
    while IFS='=' read -r key value; do
        case "$key" in GAME_DB_PASSWORD) GAME_DB_PASSWORD=$value;; MARIADB_ROOT_PASSWORD) root_password=$value;; esac
    done < "$envfile"
    [[ ${GAME_DB_PASSWORD:-} =~ ^[a-f0-9]{64}$ && $root_password =~ ^[a-f0-9]{64}$ ]] || die 'Identifiants DB absents ou invalides.'
    unset root_password
    if docker volume inspect "$volume" >/dev/null 2>&1; then
        [[ $(docker volume inspect --format '{{index .Labels "io.ptero-installer.managed"}}' "$volume") == game-db ]] || die 'Un volume DB étranger porte déjà ce nom.'
    else
        docker volume create --label io.ptero-installer.managed=game-db "$volume" >/dev/null
    fi
    if docker container inspect "$container" >/dev/null 2>&1; then
        [[ $(docker inspect --format '{{index .Config.Labels "io.ptero-installer.managed"}}' "$container") == game-db ]] || die 'Un conteneur étranger porte déjà ce nom.'
        [[ $(docker inspect --format '{{index .Config.Labels "io.ptero-installer.gateway"}}' "$container") == "$GAME_DB_GATEWAY" ]] || die 'Le réseau Wings a changé ; vérifier le conteneur DB existant.'
        docker start "$container" >/dev/null
    else
        if [[ -n $(ss -H -ltn 'sport = :3307') ]]; then die 'Le port TCP 3307 est déjà occupé.'; fi
        docker run -d --name "$container" --restart unless-stopped \
            --label io.ptero-installer.managed=game-db --label "io.ptero-installer.gateway=$GAME_DB_GATEWAY" \
            --env-file "$envfile" --network "$GAME_DB_NETWORK" \
            --publish "$GAME_DB_GATEWAY:3307:3306/tcp" --volume "$volume:/var/lib/mysql" \
            mariadb:11.4 >/dev/null
    fi
    for attempt in {1..30}; do
        if docker exec "$container" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then ready=1; break; fi
        if (( attempt % 10 == 0 )); then info 'Initialisation de MariaDB jeux en cours…'; fi
        sleep 2
    done
    (( ready )) || die 'MariaDB jeux ne répond pas ; consulter docker logs ptero-installer-game-db.'
    # Compte de gestion privilégié limité à cette instance dédiée, jamais à
    # l'instance SQL du Panel. Mot de passe hexadécimal validé, envoyé sur stdin.
    docker exec -i "$container" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot' > "$TMP/game-db-output" 2>&1 <<SQL
CREATE USER IF NOT EXISTS 'ptero_games'@'%' IDENTIFIED BY '$GAME_DB_PASSWORD';
ALTER USER 'ptero_games'@'%' IDENTIFIED BY '$GAME_DB_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'ptero_games'@'%' WITH GRANT OPTION;
SQL
    export GAME_DB_GATEWAY GAME_DB_NODE_UUID GAME_DB_PASSWORD
    (
        cd "$PANEL_DIR"
        "$PHP_BIN" >> "$TMP/game-db-output" 2>&1 <<'PHP'
<?php
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$node = Pterodactyl\Models\Node::where('uuid', getenv('GAME_DB_NODE_UUID'))->firstOrFail();
$host = Pterodactyl\Models\DatabaseHost::where('host', getenv('GAME_DB_GATEWAY'))->where('port', 3307)->first();
if ($host) {
    if ($host->username !== 'ptero_games' || $host->node_id !== $node->id ||
        $app->make(Illuminate\Contracts\Encryption\Encrypter::class)->decrypt($host->password) !== getenv('GAME_DB_PASSWORD')) {
        throw new RuntimeException('Hôte DB existant différent : arrêt sans modification.');
    }
} else {
    $app->make(Pterodactyl\Services\Databases\Hosts\HostCreationService::class)->handle([
        'name' => 'MariaDB jeux - ' . $node->name, 'host' => getenv('GAME_DB_GATEWAY'), 'port' => 3307,
        'username' => 'ptero_games', 'password' => getenv('GAME_DB_PASSWORD'), 'node_id' => $node->id,
    ]);
}
PHP
    )
    unset GAME_DB_PASSWORD
    repair_panel_runtime_permissions
    touch "$STATE_DIR/game-db.done"
    ok "MariaDB jeux ajoutée au Panel : $GAME_DB_GATEWAY:3307. Volume : $volume."
    info 'Dans le Panel, attribuer une limite de bases supérieure à 0 au serveur, puis utiliser son onglet Databases.'
}

link_local_panel() {
    (
        cd "$PANEL_DIR"
        "$PHP_BIN" <<'PHP'
<?php
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
try {
    $result = $app->make(Illuminate\Database\ConnectionInterface::class)->transaction(function () use ($app) {
        $existing = Pterodactyl\Models\Node::where('fqdn', getenv('WINGS_DOMAIN'))->first();
        if ($existing) {
            $checkpoint = is_file('/etc/pterodactyl/panel-link.json')
                ? json_decode(file_get_contents('/etc/pterodactyl/panel-link.json'), true) : [];
            if (($checkpoint['node_id'] ?? null) !== $existing->id) {
                throw new RuntimeException('Un nœud utilise déjà ce FQDN ; aucun écrasement.');
            }
            return ['node_id' => $existing->id, 'location_id' => $existing->location_id, 'config' => $existing->getConfiguration()];
        }
        $location = Pterodactyl\Models\Location::where('short', getenv('LOCATION_SHORT'))->first();
        if (!$location) {
            $location = $app->make(Pterodactyl\Contracts\Repository\LocationRepositoryInterface::class)->create([
                'short' => getenv('LOCATION_SHORT'), 'long' => 'Installation Wings',
            ], true, true);
        }
        $node = $app->make(Pterodactyl\Services\Nodes\NodeCreationService::class)->handle([
            'name' => getenv('NODE_NAME'), 'location_id' => $location->id,
            'fqdn' => getenv('WINGS_DOMAIN'), 'scheme' => getenv('SSL') === 'none' ? 'http' : 'https',
            'behind_proxy' => false, 'public' => true, 'maintenance_mode' => false,
            'memory' => (int) getenv('NODE_MEMORY'), 'memory_overallocate' => 0,
            'disk' => (int) getenv('NODE_DISK'), 'disk_overallocate' => 0,
            'upload_size' => 100, 'daemonListen' => 8080, 'daemonSFTP' => 2022,
            'daemonBase' => '/var/lib/pterodactyl/volumes',
        ]);
        $result = ['node_id' => $node->id, 'location_id' => $location->id];
        // Écrit avant commit : permet de reconnaître notre nœud après un arrêt.
        $checkpoint = '/etc/pterodactyl/panel-link.json';
        if (file_put_contents($checkpoint . '.new', json_encode($result, JSON_THROW_ON_ERROR)) === false || !rename($checkpoint . '.new', $checkpoint)) {
            throw new RuntimeException('Impossible de sauvegarder les identifiants du nœud.');
        }
        $result['config'] = $node->getConfiguration();
        return $result;
    });
    $temporary = getenv('LINK_CONFIG') . '.new';
    if (file_put_contents($temporary, json_encode($result['config'], JSON_THROW_ON_ERROR)) === false || !rename($temporary, getenv('LINK_CONFIG'))) {
        throw new RuntimeException('Écriture de la configuration impossible.');
    }
} catch (Throwable $error) {
    // Aucun dump des données, de l'environnement ou des jetons dans le journal.
    file_put_contents('php://stderr', 'Création locale du nœud impossible (' . get_class($error) . '). Vérifier les paramètres et les logs du Panel.' . PHP_EOL);
    exit(1);
}
PHP
    )
}

link_remote_panel() {
    python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request
from pathlib import Path
e = os.environ
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # Ne jamais transmettre la clé à une autre URL.
opener = urllib.request.build_opener(NoRedirect())
def write_json(path, value):
    temporary = path.with_name(path.name + '.new')
    temporary.write_text(json.dumps(value))
    temporary.replace(path)
def api(method, path, data=None):
    request = urllib.request.Request(e['PANEL_URL'] + '/api/application/' + path,
        data=None if data is None else json.dumps(data).encode(), method=method,
        headers={'Authorization': 'Bearer ' + e['APPLICATION_KEY'],
                 'Accept': 'Application/vnd.pterodactyl.v1+json', 'Content-Type': 'application/json'})
    try:
        with opener.open(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f'API {method} {path} : HTTP {error.code}. Vérifier les droits Locations/Nodes et les paramètres.') from None
    except (urllib.error.URLError, TimeoutError):
        raise RuntimeError('API inaccessible (DNS, TLS ou réseau). Vérifier le Panel avant toute nouvelle tentative.') from None
def items(resource):
    page = 1
    while True:
        result = api('GET', resource + '?per_page=100&page=' + str(page))
        for item in result['data']:
            yield item['attributes']
        pages = result.get('meta', {}).get('pagination', {}).get('total_pages', 1)
        if page >= pages:
            return
        page += 1
try:
    checkpoint = Path('/etc/pterodactyl/panel-link.json')
    previous = json.loads(checkpoint.read_text()) if checkpoint.exists() else {}
    if previous.get('node_id'):
        node = api('GET', 'nodes/' + str(previous['node_id']))['attributes']
        if node['fqdn'].lower() != e['WINGS_DOMAIN'].lower():
            raise RuntimeError('Le nœud enregistré utilise une autre adresse ; arrêt sans modification.')
        config = api('GET', 'nodes/' + str(node['id']) + '/configuration')
        write_json(Path(e['LINK_CONFIG']), config)
        sys.exit(0)
    if any(n['fqdn'].lower() == e['WINGS_DOMAIN'].lower() for n in items('nodes')):
        raise RuntimeError('Un nœud utilise déjà ce FQDN ; aucun écrasement. Utiliser sa configuration manuellement.')
    location = next((x for x in items('locations') if x['short'] == e['LOCATION_SHORT']), None)
    if location is None:
        location = api('POST', 'locations', {'short': e['LOCATION_SHORT'], 'long': 'Installation Wings'})['attributes']
    state = {'location_id': location['id']}
    write_json(checkpoint, state)
    node = api('POST', 'nodes', dict(name=e['NODE_NAME'], location_id=location['id'],
        fqdn=e['WINGS_DOMAIN'], scheme='http' if e['SSL'] == 'none' else 'https',
        behind_proxy=False, public=True, maintenance_mode=False,
        memory=int(e['NODE_MEMORY']), memory_overallocate=0, disk=int(e['NODE_DISK']), disk_overallocate=0,
        upload_size=100, daemon_listen=8080, daemon_sftp=2022,
        daemon_base='/var/lib/pterodactyl/volumes'))['attributes']
    state['node_id'] = node['id']
    write_json(checkpoint, state)
    config = api('GET', 'nodes/' + str(node['id']) + '/configuration')
    write_json(Path(e['LINK_CONFIG']), config)
except (RuntimeError, KeyError, ValueError, OSError) as error:
    # Afficher seulement nos messages contrôlés, jamais les réponses avec jetons.
    print(str(error) if isinstance(error, RuntimeError) else 'Réponse API invalide ou écriture impossible.', file=sys.stderr)
    print('Des objets peuvent avoir été créés : consulter panel-link.json et le Panel avant de réessayer.', file=sys.stderr)
    sys.exit(1)
PY
}

automatic_wings_link() {
    STAGE='liaison automatique Panel/Wings'
    export SSL WINGS_CERT WINGS_KEY PANEL_URL WINGS_DOMAIN NODE_NAME LOCATION_SHORT NODE_MEMORY NODE_DISK
    LINK_CONFIG="$STATE_DIR/wings-config.json"
    export LINK_CONFIG
    if [[ -s $LINK_CONFIG ]]; then
        info 'Configuration du nœud déjà récupérée : réutilisation.'
    elif (( PANEL )); then
        link_local_panel
        repair_panel_runtime_permissions
    else
        export APPLICATION_KEY
        link_remote_panel
        unset APPLICATION_KEY
    fi
    cp "$LINK_CONFIG" "$TMP/config.yml"
    ok 'Localisation et nœud configurés dans le Panel ; configuration Wings récupérée.'
}

wings_install() {
    STAGE=Wings
    download "https://github.com/pterodactyl/wings/releases/download/$WINGS_TAG/wings_linux_$WINGS_ARCH" "$TMP/wings"
    install -m 755 "$TMP/wings" /usr/local/bin/wings
    install -d -m 700 /etc/pterodactyl
    cat > /etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Pterodactyl Wings
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target
PartOf=docker.service
StartLimitIntervalSec=180
StartLimitBurst=30

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings --config /etc/pterodactyl/config.yml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    local configure=0
    if (( AUTO_LINK )); then
        automatic_wings_link
        configure=1
    else
        printf '\nDans %s : Admin → Locations → créer une localisation → Nodes → créer un nœud.\n' "$PANEL_URL"
        printf 'Adresse du nœud (champ FQDN, accepte l’IPv4) : %s ; API : 8080 ; SFTP : 2022 ; proxy : non.\n' "$WINGS_DOMAIN"
        if [[ $SSL == none ]]; then info 'Schéma du nœud : HTTP.'; else info 'Schéma du nœud : HTTPS.'; fi
        info 'Utiliser le DNS direct vers le serveur (pas de proxy CDN sur 8080/2022).'
        info 'Onglet Configuration : copier tout le YAML. Les ports/TLS seront ajustés aux choix ci-dessus.'
        if yesno 'Coller maintenant la configuration Wings générée par le Panel' n; then
            printf 'Coller le YAML puis une ligne contenant uniquement END (saisie masquée).\n' > /dev/tty
            local line
            : > "$TMP/config.yml"
            while IFS= read -rs line < /dev/tty; do
                [[ $line != END ]] || break
                printf '%s\n' "$line" >> "$TMP/config.yml"
            done
            configure=1
        fi
    fi
    if (( configure )); then
        export SSL WINGS_CERT WINGS_KEY PANEL_URL
        python3 - "$TMP/config.yml" <<'PY'
import os, sys, yaml
from pathlib import Path
p = Path(sys.argv[1])
c = yaml.safe_load(p.read_text())
assert isinstance(c, dict), 'Configuration YAML absente/invalide'
for key in ('uuid', 'token_id', 'token', 'remote', 'api', 'system'):
    assert c.get(key), 'Champ requis absent : ' + key
assert c['remote'].rstrip('/') == os.environ['PANEL_URL'], 'URL Panel distante différente'
c['api']['host'] = '0.0.0.0'
c['api']['port'] = 8080
c['api']['ssl'] = dict(enabled=os.environ['SSL'] != 'none', cert=os.environ['WINGS_CERT'], key=os.environ['WINGS_KEY'])
c['system'].setdefault('sftp', {})['bind_port'] = 2022
p.write_text(yaml.safe_dump(c, sort_keys=False))
PY
        install -m 600 "$TMP/config.yml" /etc/pterodactyl/config.yml
        systemctl enable --now wings
        sleep 5
        systemctl is-active --quiet wings || die 'Wings a échoué : consulter journalctl -u wings -n 80.'
        WINGS_READY=1
        if (( AUTO_LINK )); then
            python3 - "$TMP/wings-probe.conf" <<'PY'
import sys, yaml
from pathlib import Path
c = yaml.safe_load(Path('/etc/pterodactyl/config.yml').read_text())
token = c['token']
assert isinstance(token, str) and token.isalnum(), 'Jeton Wings invalide'
Path(sys.argv[1]).write_text('header = "Authorization: Bearer ' + token + '"\n')
PY
            local scheme=http
            [[ $SSL == none ]] || scheme=https
            curl --fail --silent --show-error --retry 5 --retry-connrefused --retry-delay 2 --max-time 5 \
                --config "$TMP/wings-probe.conf" --noproxy '*' --connect-to "$WINGS_DOMAIN:8080:127.0.0.1:8080" \
                "$scheme://$WINGS_DOMAIN:8080/api/system" -o "$TMP/wings-probe.json"
            ok 'API Wings accessible localement avec le jeton généré par le Panel.'
        fi
    else
        info 'Wings reste arrêté jusqu’à la création de /etc/pterodactyl/config.yml.'
    fi
}

verify() {
    STAGE=vérifications
    if (( PANEL )); then
        local service code
        for service in mariadb redis-server "php$PHP_VERSION-fpm" "$WEB" pteroq cron; do
            systemctl is-active --quiet "$service" || die "Service inactif : $service (journalctl -u $service)."
        done
        if [[ $SSL == none ]]; then
            code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 30 \
                --noproxy '*' --connect-to "$PANEL_DOMAIN:80:127.0.0.1:80" "$PANEL_URL/auth/login")
        else
            code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 30 \
                --noproxy '*' --connect-to "$PANEL_DOMAIN:443:127.0.0.1:443" "$PANEL_URL/auth/login")
        fi
        [[ $code == 200 ]] || die "Le Panel répond HTTP $code ; consulter les logs web et storage/logs."
        ok 'Panel : page de connexion accessible et services actifs.'
    fi
    if (( WINGS )); then systemctl is-active --quiet docker; fi
}

summary() {
    STAGE=terminé
    printf '\n========== Installation terminée ==========\n'
    printf 'OS : %s\nJournal : %s\n' "$PRETTY_NAME" "$LOG"
    printf 'Configuration rapide : %s ; DB jeux demandée : %s\n' "$QUICK_MODE" "$GAME_DB_ENABLED"
    printf 'État de l’installation et diagnostics privés : %s\n' "$STATE_DIR"
    printf 'Les versions sélectionnées sont conservées pour les reprises ; ce script ne met pas à jour une installation terminée.\n'
    if (( PANEL )); then
        printf 'Panel %s : %s\nAdministrateur : %s (%s)\n' "$PANEL_TAG" "$PANEL_URL" "$ADMIN_USER" "$ADMIN_EMAIL"
        printf 'Identifiants (root uniquement) : %s\nLecture : sudo cat %s\n' "$CREDENTIALS" "$CREDENTIALS"
        printf 'Sauvegarder la base, .env et APP_KEY hors du serveur. Ne jamais régénérer APP_KEY.\n'
        [[ $MAIL_MAILER != log ]] || printf 'SMTP non configuré : les emails sont consignés localement, sans envoi.\n'
    fi
    if (( WINGS )); then
        printf 'Wings %s : %s:8080 ; SFTP : %s:2022\n' "$WINGS_TAG" "$WINGS_DOMAIN" "$WINGS_DOMAIN"
        if (( WINGS_READY )); then
            printf 'Wings démarré. Vérifier le statut du nœud dans le Panel.\n'
            if (( AUTO_LINK )); then
                printf 'Nœud créé automatiquement : %s ; localisation : %s.\n' "$NODE_NAME" "$LOCATION_SHORT"
                printf 'Identifiants des objets créés : /etc/pterodactyl/panel-link.json\n'
            fi
        else
            printf 'Wings installé, configuration à ajouter avant démarrage :\n'
            printf '  1. %s → Admin → Locations / Nodes → Configuration.\n' "$PANEL_URL"
            printf '  2. sudo nano /etc/pterodactyl/config.yml (coller le YAML complet).\n'
            printf '     Nœud %s, API 8080, SFTP 2022 ; mêmes valeurs dans le Panel.\n' "$WINGS_DOMAIN"
            if [[ $SSL != none ]]; then
                printf '     api.ssl.enabled: true\n     api.ssl.cert: %s\n     api.ssl.key: %s\n' "$WINGS_CERT" "$WINGS_KEY"
            else printf '     api.ssl.enabled: false ; Panel et nœud en HTTP.\n'; fi
            printf '  3. sudo chmod 600 /etc/pterodactyl/config.yml\n'
            printf '  4. sudo wings --debug (vérifier, puis Ctrl+C)\n'
            printf '  5. sudo systemctl enable --now wings\n'
        fi
        printf 'Créer les allocations IP/ports des jeux et ouvrir ces ports TCP/UDP chez l’hébergeur.\n'
        printf 'Docker publie les ports des conteneurs en contournant UFW : filtrer via DOCKER-USER ou le pare-feu hébergeur.\n'
    fi
    if [[ $SSL == le ]]; then
        printf 'Renouvellement : certbot.timer ; test conseillé : sudo certbot renew --dry-run\n'
        printf 'Le renouvellement standalone interrompt brièvement le web ; Wings redémarre après renouvellement réussi.\n'
    elif [[ $SSL == existing ]]; then
        printf 'Certificats existants : prévoir leur renouvellement et le rechargement du web/redémarrage de Wings.\n'
    fi
    printf 'Diagnostic : journalctl -u pteroq -u wings -n 80 --no-pager\n'
}

main() {
    local action=1
    case "${1:-}" in
        --help|-h) printf 'Usage : sudo bash install.sh [--resume|--configure-databases]\n'; return 0;;
        ''|--resume) ;;
        --configure-databases) DB_ONLY=1;;
        *) die 'Option inconnue. Utiliser --help.';;
    esac
    preflight
    if [[ -f $STATE_DIR/settings ]]; then
        [[ ! -L $STATE_DIR/settings && $(stat -c %u "$STATE_DIR/settings") == 0 && $(stat -c %a "$STATE_DIR/settings") == 600 ]] || die 'Fichier d’état non sûr.'
        if [[ ${1:-} != --resume ]]; then
            if (( DB_ONLY == 0 )); then
                while true; do
                    ask action 'Installation enregistrée : 1=reprendre/résumé, 4=configurer les DB des jeux, 0=quitter' 1
                    case "$action" in 1) break;; 4) DB_ONLY=1; break;; 0) return 0;; esac
                done
            fi
        fi
        # shellcheck source=/dev/null
        . "$STATE_DIR/settings"
        [[ $INSTALL_OS == "$ID:$OS_CODENAME" ]] || die 'L’OS diffère de celui de l’installation enregistrée.'
        if (( DB_ONLY )); then configure_game_databases; return 0; fi
        info "Reprise : Panel $PANEL_TAG ; Wings $WINGS_TAG ; $PANEL_URL"
        if [[ -f $STATE_DIR/complete.done ]]; then summary; return 0; fi
    else
        [[ ${1:-} != --resume ]] || die 'Aucun état de reprise trouvé pour cette version du script.'
        if (( DB_ONLY )); then PANEL=1; configure_game_databases; return 0; fi
        questions
        if (( DB_ONLY )); then PANEL=1; configure_game_databases; return 0; fi
        base_packages
        if (( PANEL )); then release panel "${PANEL_VERSION:-}" PANEL_TAG; fi
        if (( WINGS )); then release wings "${WINGS_VERSION:-}" WINGS_TAG; fi
        INSTALL_OS="$ID:$OS_CODENAME"
        state_save
    fi
    run_step firewall firewall
    run_step certificates certificates
    if (( PANEL )); then
        run_step panel-dependencies panel_dependencies
        run_step database database
        run_step panel-install panel_install
        run_step panel-services panel_services
        run_step webserver webserver
    fi
    if (( WINGS )); then
        run_step docker docker_install
        if (( AUTO_LINK && PANEL == 0 )) && [[ ! -s $STATE_DIR/wings-config.json && -z $APPLICATION_KEY ]]; then
            secret APPLICATION_KEY 'Clé Application API du Panel distant pour terminer la liaison'
        fi
        run_step wings-install wings_install
    fi
    if (( GAME_DB_ENABLED )) && [[ ! -f $STATE_DIR/game-db.done ]]; then configure_game_databases; fi
    repair_panel_runtime_permissions
    verify
    unset DB_PASSWORD ADMIN_PASSWORD SMTP_PASSWORD APPLICATION_KEY
    mark_done complete
    summary
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
