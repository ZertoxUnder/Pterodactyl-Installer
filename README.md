# Ptero Vibe Installer

Installateur Bash interactif pour **Pterodactyl Panel 1.x et Wings**.

> **100 % vibecodé avec l’IA.** Projet expérimental et non officiel : testez-le sur une VM vierge avant de l’utiliser sur un serveur réel.

## Fonctionnalités

- Panel seul, Wings seul ou les deux, avec installation des dépendances.
- Nginx ou Apache, domaine ou IPv4, SSL optionnel.
- Liaison automatique Panel/Wings, SMTP et UFW en option.
- Reprise après interruption, logs et diagnostics privés.

## Installation

**Debian 12/13 ou Ubuntu 22.04/24.04**, sur un serveur vierge avec systemd. Pour Wings : AMD64/ARM64 et un noyau compatible Docker.

Depuis un terminal Bash connecté en **root** :

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZertoxUnder/Pterodactyl-Installer/main/install.sh)
```

Si `curl` manque :

```bash
apt-get update && apt-get install -y curl ca-certificates
```

Répondez au menu. Sans domaine, saisissez votre IPv4 et choisissez le mode sans SSL : le Panel sera accessible sur `http://VOTRE_IP`.

## Reprendre une installation

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZertoxUnder/Pterodactyl-Installer/main/install.sh) --resume
```

La reprise nécessite l’état enregistré par ce script ; elle ne met pas à jour une installation terminée.

## À savoir

- HTTP n’est pas chiffré. Le mode Let’s Encrypt intégré nécessite un domaine configuré.
- Pour relier Wings à un Panel distant : HTTPS et clé Application API avec droits Locations/Nodes, ou collage manuel du YAML.
- Les identifiants et diagnostics se trouvent dans `/var/lib/pterodactyl-installer/`, sous permissions root uniquement.
- Sauvegardez le `.env` et son `APP_KEY`. Ne partagez pas les fichiers contenant des secrets.
- DNS, ports des jeux, allocations et sauvegardes restent à configurer. Docker peut contourner les règles UFW.
- Mises à jour et désinstallation non incluses. Les tests automatisés ne valident pas une installation Linux complète.

[Documentation Pterodactyl](https://docs.pterodactyl.io/v1/panel/getting-started)
