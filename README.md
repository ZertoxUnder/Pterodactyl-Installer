# Ptero Vibe Installer

Installateur Bash interactif pour **Pterodactyl Panel 1.x et Wings**, avec domaine ou IPv4, SSL optionnel et reprise après interruption.

> **100 % vibecodé.** L’installateur, ses corrections, ses tests et cette documentation ont été réalisés avec l’aide d’IA, à partir de consignes et de retours humains. Ce projet est expérimental, communautaire et indépendant de l’équipe Pterodactyl.
>
> Les contrôles statiques et les tests simulés ne remplacent pas une installation réelle. Testez d’abord sur une VM vierge et conservez vos sauvegardes avant tout usage réel.

## Fonctionnalités

- Menu : Panel seul, Wings seul ou les deux sur la même machine.
- Installation des dépendances APT et de Composer selon le mode choisi.
- Création de la base MariaDB, de l’utilisateur SQL et du premier administrateur.
- Configuration du Panel, des migrations, du worker `pteroq` et du cron.
- Choix entre Nginx et Apache, avec PHP-FPM.
- Accès par domaine ou IPv4 ; le Panel et Wings peuvent partager la même adresse.
- SSL : Let’s Encrypt, certificat existant ou HTTP sans SSL.
- Installation de Docker, de Wings et de son service systemd.
- Liaison automatique Panel/Wings : localisation, nœud et récupération de sa configuration.
- Configuration SMTP et UFW en option.
- Suggestions de RAM et de disque calculées depuis les ressources disponibles.
- Journalisation, diagnostics privés et reprise par étapes avec `--resume`.

## Systèmes pris en charge

| Système | PHP installé pour le Panel | Dépôt PHP |
| --- | --- | --- |
| Ubuntu 22.04 | 8.3 | PPA Ondřej |
| Ubuntu 24.04 | 8.3 | Dépôts Ubuntu |
| Debian 12 | 8.2 | Dépôts Debian |
| Debian 13 | 8.3 | Sury |

Ces systèmes sont gérés par le script ; cette liste ne constitue pas une certification par des tests d’installation complets sur chaque OS.

Prérequis :

- Un serveur Linux vierge, avec systemd, et une connexion Internet.
- Un accès root et un terminal interactif.
- Pour Wings : architecture AMD64 ou ARM64 et un noyau permettant de démarrer des conteneurs Docker.
- Les ports nécessaires disponibles et accessibles depuis les clients concernés.

Le script refuse de remplacer une installation préexistante. Il ne permet pas de migrer automatiquement une installation faite avec un autre outil.

## Installation

Téléchargez [`install.sh`](install.sh) depuis ce dépôt, puis transférez-le sur votre serveur. Depuis le dossier contenant le fichier :

```bash
sudo bash install.sh
```

Si vous êtes déjà connecté en root :

```bash
bash install.sh
```

Répondez aux questions du menu. Les paquets nécessaires sont installés automatiquement ; il n’est pas nécessaire de préparer PHP, MariaDB, Redis ou Docker à la main.

Pour afficher l’aide :

```bash
bash install.sh --help
```

### Sans domaine

Saisissez une IPv4 à la place du domaine. Le mode sans SSL est proposé par défaut.

| Composant | Adresse |
| --- | --- |
| Panel | `http://VOTRE_IP` |
| API Wings | `http://VOTRE_IP:8080` |
| SFTP Wings | `VOTRE_IP:2022` |

Les échanges HTTP ne sont pas chiffrés. Le mode Let’s Encrypt intégré au script nécessite un domaine. Un certificat existant peut être utilisé s’il couvre l’adresse saisie et est reconnu par les clients.

### Avec un domaine

Créez les enregistrements DNS vers votre serveur avant de lancer l’installation. Pour Let’s Encrypt, le port 80 doit être accessible publiquement, y compris pendant les renouvellements.

Le renouvellement utilise Certbot en mode standalone : le serveur web peut être brièvement arrêté, puis redémarré. Wings est redémarré après un renouvellement réussi lorsqu’il est actif.

## Liaison Panel et Wings

En mode **Panel + Wings**, le script peut créer la localisation et le nœud via les services internes du Panel, sans vous demander de clé API.

En mode **Wings seul**, la liaison automatique nécessite :

- Un Panel distant déjà installé et accessible en HTTPS.
- Une clé **Application API**, avec les permissions de lecture/écriture sur **Locations** et **Nodes**.

La clé API est saisie de manière masquée et n’est pas enregistrée dans l’état de reprise. Elle peut être redemandée après une interruption. Un Panel distant en HTTP utilise la méthode manuelle, par collage du YAML, afin de ne pas transmettre cette clé sans chiffrement.

Le collage manuel de la configuration reste disponible. Si vous le reportez, Wings reste arrêté jusqu’à sa configuration et son démarrage manuel.

## Reprise après interruption

```bash
sudo bash install.sh --resume
```

Les paramètres et les étapes terminées sont conservés dans `/var/lib/pterodactyl-installer`. La reprise réutilise les versions Panel/Wings sélectionnées au début de l’installation et évite de rejouer les étapes déjà terminées.

Cette reprise concerne uniquement une installation commencée avec une version du script qui enregistre cet état. Elle ne constitue pas un retour arrière automatique. Après une erreur, consultez les diagnostics et corrigez sa cause avant de reprendre.

Une installation marquée comme terminée n’est pas mise à jour par `--resume`.

## Identifiants et diagnostics

| Élément | Emplacement sur le serveur |
| --- | --- |
| Journaux d’installation | `/var/log/pterodactyl-install-*.log` |
| État, étapes et diagnostics privés | `/var/lib/pterodactyl-installer/` |
| Identifiants administrateur | `/var/lib/pterodactyl-installer/credentials.txt` |
| Environnement du Panel | `/var/www/pterodactyl/.env` |
| Copie privée du `.env` | `/var/lib/pterodactyl-installer/panel.env.backup` |
| Configuration de Wings | `/etc/pterodactyl/config.yml` |

Ces fichiers peuvent contenir des secrets. Ne publiez pas leur contenu dans une issue. L’état de reprise peut conserver des mots de passe en clair, sous permissions root uniquement, jusqu’à leur purge en fin d’installation. La copie du `.env` et le fichier d’identifiants restent volontairement conservés.

Sauvegardez le `.env`, particulièrement `APP_KEY`, avec la base de données et les données des serveurs. **Ne régénérez pas une clé `APP_KEY` déjà utilisée.** La copie locale de récupération ne remplace pas une sauvegarde hors du serveur.

Diagnostic des services :

```bash
sudo journalctl -u pteroq -u wings -n 80 --no-pager
```

## Ce qui reste à votre charge

- La configuration DNS, du NAT et du pare-feu de l’hébergeur.
- La création des allocations et des serveurs de jeu dans le Panel.
- L’ouverture des ports TCP/UDP utilisés par les jeux.
- La fourniture d’un service SMTP si vous souhaitez envoyer des emails.
- Les sauvegardes régulières et leur stockage distant.
- Le renouvellement des certificats fournis manuellement.
- Les mises à jour et la désinstallation du Panel/Wings, non implémentées ici.

UFW est optionnel. Les ports publiés par Docker peuvent contourner ses règles : le filtrage des conteneurs doit être traité avec les règles Docker appropriées ou le pare-feu de l’hébergeur.

Le test `hello-world` de Docker est non bloquant. Son échec est conservé dans les diagnostics ; continuer l’installation ne garantit alors pas que les conteneurs démarrent correctement.

## Tests et CI

Depuis la racine du dépôt, dans un environnement avec Bash et ShellCheck :

```bash
bash -n install.sh
bash -n tests/test-installer.sh
shellcheck install.sh tests/test-installer.sh
bash tests/test-installer.sh
```

Les tests utilisent des commandes simulées et des dossiers temporaires. Ils couvrent notamment la reprise, l’export de l’email administrateur, la conservation d’`APP_KEY`, le traitement des secrets, la génération de configurations Nginx et un échec simulé de Docker Hub.

Le [workflow GitHub Actions](.github/workflows/validate.yml) lance ces vérifications et contrôle la syntaxe du Python embarqué. Il ne déploie pas Pterodactyl et ne valide pas une installation complète sur les quatre OS.

L’installation reste autonome : seul `install.sh` est nécessaire sur le serveur. Les fichiers de tests et de CI servent au développement du dépôt.

## Signaler un problème

Indiquez votre OS, le mode choisi, l’étape en échec et un extrait de journal **sans secrets**. Précisez si le serveur était vierge et si vous avez utilisé `--resume`.

Les corrections et revues humaines sont les bienvenues : un projet entièrement vibecodé a aussi besoin de tests réels et de retours de terrain.

## Documentation de référence

- [Installation officielle du Panel 1.x](https://docs.pterodactyl.io/v1/panel/getting-started)
- [Configuration du serveur web](https://docs.pterodactyl.io/v1/panel/webserver-configuration)
- [Installation officielle de Wings](https://docs.pterodactyl.io/v1/wings/installing)
- [Docker sur Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker sur Debian](https://docs.docker.com/engine/install/debian/)
