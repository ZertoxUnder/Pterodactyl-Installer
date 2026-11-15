# Ptero Vibe Installer

Installateur Bash interactif pour **Pterodactyl Panel 1.x et Wings**.

> **100 % vibecodé avec l’IA.** Projet expérimental et non officiel : testez-le sur une VM vierge avant de l’utiliser sur un serveur réel.

## Fonctionnalités

- Panel seul, Wings seul ou les deux, avec installation des dépendances.
- Nginx ou Apache, domaine ou IPv4, SSL optionnel.
- Liaison automatique Panel/Wings, SMTP et UFW en option.
- Mode rapide par défaut : peu de questions et mots de passe générés.
- MariaDB dédiée aux bases des jeux, ajoutée automatiquement au Panel en option.
- Ports prédéfinis et allocations automatiques : Minecraft, GMod/Source, Rust, FiveM, Valheim, Terraria, Factorio, Zomboid et ARK.
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

Choisissez le mode rapide : adresse, email et confirmations principales suffisent pour Panel + Wings. Nginx, le compte `admin`, les mots de passe et les ressources sont configurés automatiquement. Avec une IPv4, le Panel sera accessible sur `http://VOTRE_IP`, sans SSL. Le mode avancé conserve tous les réglages.

L’option **4** prépare les DB des jeux sur une machine avec Panel + Wings déjà configurés. Accès direct :

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZertoxUnder/Pterodactyl-Installer/main/install.sh) --configure-databases
```

Elle crée une instance MariaDB Docker séparée, un volume persistant et un hôte DB dans le Panel. Le port 3307 est lié à la passerelle privée du réseau Wings. Attribuez ensuite une limite de bases supérieure à 0 à vos serveurs dans le Panel.

**Pourquoi 3307 ?** Le Panel utilise déjà MariaDB sur 3306. La DB des jeux utilise 3307 côté machine pour séparer les instances ; dans son conteneur, elle reste sur 3306.

L’option **5** ajoute les ports à une installation existante (ou utilisez `--configure-ports` avec la commande curl). Par défaut : Minecraft Java `25565–25574/TCP`, Bedrock `19132–19141/UDP`, GMod/Source `27015–27024/UDP`, FiveM `30120–30124/TCP+UDP`, et les ports des autres jeux listés plus haut. Les allocations déjà présentes sont conservées ; aucun serveur de jeu n’est créé.

Les règles sont ajoutées si UFW est actif. Le pare-feu de l’hébergeur et le NAT restent à configurer. L’ajout automatique des allocations nécessite le Panel et Wings sur la même machine ; avec un Panel distant, un manifeste des ports est fourni.

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
