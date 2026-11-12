# Sauvegarde / restauration WordPress

Deux scripts Bash pour sauvegarder le répertoire web d'un serveur de production Ubuntu vers un serveur de sauvegarde distant (SSH), puis le restaurer.

| Script | Rôle |
|---|---|
| `backup.sh` | Archive les dossiers web (+ dump SQL optionnel) en `.tar.gz`, l'envoie en SSH, vérifie l'empreinte SHA-256, applique une rotation |
| `restore.sh` | Liste les archives du serveur de sauvegarde, en fait choisir une, la télécharge, fait un snapshot de l'état actuel puis restaure |
| `config.example.conf` | Modèle de configuration (à copier en `config.conf`, non versionné) |

## Architecture

```
 VM prod (VirtualBox, Ubuntu)                  Serveur de sauvegarde (Ubuntu)
 ┌──────────────────────────┐   SSH / scp      ┌──────────────────────────────┐
 │ /var/www  ──backup.sh──► ├─────────────────►│ ~/backups/wordpress/*.tar.gz │
 │ /var/www ◄──restore.sh── │◄─────────────────┤                              │
 └──────────────────────────┘                  └──────────────────────────────┘
```

Les deux scripts tournent sur la VM de production : c'est toujours elle qui initie la connexion.

## Prérequis

- Ubuntu avec `bash`, `tar`, `rsync`, `ssh` (`sudo apt install rsync openssh-client`)
- Un compte sur le serveur de sauvegarde
- Les droits `sudo` sur la VM de production

## Installation

### 1. Clé SSH dédiée (connexion sans mot de passe)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_backup -C "backup wordpress"
ssh-copy-id -i ~/.ssh/id_ed25519_backup.pub -p 22 UTILISATEUR@IP_SERVEUR
ssh -i ~/.ssh/id_ed25519_backup UTILISATEUR@IP_SERVEUR   # doit se connecter sans mot de passe
```

### 2. Configuration

```bash
cp config.example.conf config.conf
nano config.conf
chmod +x backup.sh restore.sh
```

### 3. Où est vraiment WordPress ?

Avec `apt install wordpress`, les fichiers sont dans `/usr/share/wordpress` et la config dans `/etc/wordpress`, pas dans `/var/www`. À vérifier :

```bash
ls -la /var/www/html                      # un lien symbolique vers /usr/share/wordpress ?
grep -ri wordpress /etc/apache2/sites-enabled/
```

Adapter `BACKUP_PATHS` dans `config.conf` en conséquence.

## Utilisation

```bash
./backup.sh                 # sauvegarde
./restore.sh                # restauration avec menu de choix
./restore.sh wordpress_vm_2026-11-12_14-00-00.tar.gz   # restauration directe
```

Les scripts se lancent **sans** `sudo` : ils l'appellent eux-mêmes pour les opérations qui le nécessitent (lecture/écriture des fichiers web), et utilisent la clé SSH de l'utilisateur pour le transfert.

## Sécurité

- `config.conf` (IP, utilisateur) n'est pas versionné.
- Le dossier distant est en `chmod 700` : les autres utilisateurs du serveur partagé ne peuvent pas lire les archives (qui contiennent les identifiants de la base).
- L'intégrité du transfert est vérifiée par comparaison SHA-256.
- La restauration n'écrit que dans les dossiers listés dans la config, et sauvegarde l'état actuel dans `~/pre-restore_*.tar.gz` avant d'écraser.

## Tests réalisés

1. Sauvegarde, puis vérification de la présence de l'archive sur le serveur.
2. Modification du site (création/suppression d'un fichier dans le dossier web).
3. Restauration, puis vérification que le site est revenu à l'état sauvegardé.
