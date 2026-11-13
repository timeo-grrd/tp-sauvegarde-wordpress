# Sauvegarde sécurisée WordPress vers MinIO (triade CIA) — itération 2

Évolution de l'itération 1 (branche `main` : archive envoyée par SSH). Le dossier `/var/www` est haché, chiffré, envoyé dans un **bucket MinIO (S3)** avec ses métadonnées JSON et sa clé, puis **validé à partir du bucket** : hash de l'archive, déchiffrement, hash du dossier déchiffré. Le tout s'exécute automatiquement via **cron**.

| Fichier | Rôle |
|---|---|
| `backup.sh` | Pipeline complet, étapes 1 à 5, + rotation. Lancé par cron |
| `verify.sh` | Étape 5 seule, sur n'importe quelle sauvegarde du bucket |
| `restore.sh` | Bonus : restaure une sauvegarde validée sur `/var/www` et la base |
| `common.sh` | Fonctions partagées : hash, chiffrement, validation, tunnel |
| `config.example.conf` | Modèle de configuration |
| `wp-backup.cron` | Planification |

## Correspondance avec le cahier des charges

| Étape (barème) | Implémentation |
|---|---|
| **1. Hash initial** (0,5) | `hash_dir` : SHA-256 de la liste triée « empreinte + chemin » de chaque fichier de `/var/www`, calculé avant toute manipulation |
| **2. Clé + chiffrement** (1,5) | Clé de 256 bits, nouvelle à chaque sauvegarde, générée par OpenSSL ou **fournie par HashiCorp Vault** (voir plus bas). `tar -cz` envoyé directement dans `openssl enc -aes-256-cbc -pbkdf2` : aucune archive en clair sur le disque, et la clé est passée par fichier, jamais en argument (sinon elle serait visible dans `ps`) |
| **3. Hash archive + JSON** (0,5) | SHA-256 de l'archive chiffrée. `metadata.json` construit avec `jq` : horodatage, chemin source, hash initial, hash de l'archive chiffrée, paramètres de chiffrement |
| **4. Transfert vers MinIO** (1) | `rclone copy` des 3 fichiers dans `bucket/<sauvegarde>/`, à travers un rebond SSH chiffré (voir plus bas) |
| **5. Validation** (1,5) | `verify_backup` : retélécharge les 3 fichiers **depuis le bucket**, compare le hash de l'archive au JSON, déchiffre avec la clé, compare le hash du dossier déchiffré au hash initial. Toute différence arrête le script avec une erreur |

Exemple de sortie :

```
1/5 Hash initial du dossier /var/www...
    0e7cb4bd7ee0fd2f5dcc7c6a80865f66788c1fe83b319d0347b33495e36deb51
2/5 Génération d'une clé symétrique aléatoire (256 bits)...
    Compression et chiffrement AES-256 de /var/www...
3/5 Hash de l'archive chiffrée et métadonnées JSON...
    601eb8954dfcdd543eceb45c7887b203e92d22fc0b16887512fbbb8f4bef497a
4/5 Envoi de l'archive, du JSON et de la clé vers minio:backup-timeo/wordpress_.../
5/5 Récupération de wordpress_... depuis le bucket...
    a) Intégrité de l'archive chiffrée...
       601eb895... : conforme au JSON
    b) Déchiffrement avec la clé symétrique...
    c) Contrôle final : empreinte du dossier déchiffré...
       0e7cb4bd... : identique au hash initial de production
Sauvegarde terminée et validée
```

## Organisation du bucket

```
backup-timeo/
└── wordpress_tim-VirtualBox_2026-11-13_12-17-01/
    ├── archive.tar.gz.enc    archive chiffrée (/var/www + dump SQL)
    ├── metadata.json         métadonnées et hashs
    └── cle.key               clé symétrique (64 caractères hexadécimaux)
```

```json
{
  "sauvegarde": "wordpress_tim-VirtualBox_2026-11-13_12-17-01",
  "horodatage": "2026-11-13T12:17:01+01:00",
  "hote": "tim-VirtualBox",
  "chemin_source": "/var/www",
  "hash_initial":          { "algo": "sha256", "valeur": "0e7cb4bd…" },
  "hash_archive_chiffree": { "algo": "sha256", "valeur": "601eb895…" },
  "chiffrement": { "algo": "aes-256-cbc", "derivation": "pbkdf2-sha256",
                   "iterations": 200000, "fichier_cle": "cle.key" },
  "base_de_donnees_incluse": "wordpress"
}
```

## Gestion de la clé et HashiCorp Vault

`KEY_BACKEND` (dans `config.conf`) choisit d'où vient la clé et ce que contient `cle.key` dans le bucket :

| `KEY_BACKEND` | Origine de la clé | Contenu de `cle.key` dans le bucket | Qui peut déchiffrer ? |
|---|---|---|---|
| `fichier` | `openssl rand -hex 32` | la clé en clair | quiconque lit le bucket |
| `vault-kv` | `openssl rand -hex 32`, rangée dans Vault (moteur KV v2) | le chemin de la clé dans Vault | lecteur du bucket **et** détenteur d'un token Vault autorisé |
| `vault-transit` | **générée par Vault** (`transit/datakey`) | la clé **chiffrée par Vault** (`vault:v1:…`) | lecteur du bucket **et** détenteur d'un token Vault autorisé |

Le mode **`vault-transit`** est recommandé : c'est le chiffrement « en enveloppe ». La clé part bien dans le bucket, comme le demande le cahier des charges, mais sous une forme que seul Vault peut ouvrir. Une fuite du bucket ne suffit plus à lire les archives. Le JSON note la méthode utilisée, ce qui permet de relire les anciennes sauvegardes après un changement de mode. Exception volontaire : quand la config utilise Vault, une sauvegarde qui se présente avec une clé en clair est refusée. Sans ça, un attaquant capable d'écrire dans le bucket pourrait y déposer une fausse sauvegarde chiffrée avec sa propre clé et contourner Vault (attaque par rétrogradation).

Le token Vault est stocké dans `/etc/wp-backup/vault-token` (root, `600`) et transmis à `curl` par un fichier d'en-tête : il n'apparaît jamais dans les arguments d'une commande (`ps`) ni dans l'historique.

**Prérequis côté Vault :**
- `vault-transit` : `vault secrets enable transit` puis `vault write -f transit/keys/wp-backup-timeo`. Le token doit pouvoir appeler `transit/datakey/plaintext/wp-backup-timeo` et `transit/decrypt/wp-backup-timeo`.
- `vault-kv` : un moteur KV v2 monté sur `secret/`, avec le droit d'écrire et de lire dans `secret/data/wp-backup/timeo/*`.

## Installation

Prérequis : `sudo apt install -y rclone jq rsync openssl`

**1. Accès à MinIO (rclone)**, réservé à root :

```bash
sudo install -d -m 700 /etc/wp-backup
sudo nano /etc/wp-backup/rclone.conf
```
```ini
[minio]
type = s3
provider = Minio
access_key_id = IDENTIFIANT_MINIO
secret_access_key = MOT_DE_PASSE_MINIO
endpoint = http://10.1.60.10:9000
```
```bash
sudo chmod 600 /etc/wp-backup/rclone.conf
sudo rclone --config /etc/wp-backup/rclone.conf lsd minio:
```

**2. Configuration :**

```bash
sudo install -m 600 config.example.conf /etc/wp-backup/config.conf
sudo nano /etc/wp-backup/config.conf
```

**3. Déploiement des scripts et du cron :**

```bash
sudo install -d -m 755 /opt/wp-backup
sudo install -m 755 backup.sh verify.sh restore.sh /opt/wp-backup/
sudo install -m 644 common.sh /opt/wp-backup/
sudo install -m 644 wp-backup.cron /etc/cron.d/wp-backup
```

Le cron exécute la copie de `/opt/wp-backup`, qui appartient à root, et non le dépôt dans `/home/tim` : si root exécutait un fichier modifiable par `tim`, compromettre `tim` suffirait pour devenir root. Pour la même raison, les scripts refusent une configuration qui n'appartient pas à root ou qui n'est pas en `600`. Après chaque modification, relancer les commandes `install`.

## Canal sécurisé : rebond SSH

MinIO et Vault ne sont pas joignables en direct : il faut passer par une machine de rebond (bastion) en SSH. Si `TUNNEL_SSH` est renseigné, chaque script ouvre **une** connexion SSH vers le bastion, y fait passer le trafic S3 et le trafic Vault, chiffrés, puis la referme à la fin :

```
VM ──SSH chiffré──► bastion ──► MinIO  (TUNNEL_REMOTE,       entrée locale 127.0.0.1:19000)
                            └─► Vault  (TUNNEL_VAULT_REMOTE, entrée locale 127.0.0.1:18200)
```

C'est aussi ce qui répond à l'exigence de « canal sécurisé » : sans rebond, avec des adresses en `http://`, la clé et le token circuleraient en clair.

```bash
sudo ssh-keygen -t ed25519 -N "" -f /etc/wp-backup/ssh_key -C wp-backup
sudo ssh-copy-id -i /etc/wp-backup/ssh_key.pub -p PORT UTILISATEUR@BASTION
sudo ssh -p PORT -i /etc/wp-backup/ssh_key -o UserKnownHostsFile=/etc/wp-backup/known_hosts UTILISATEUR@BASTION exit
sudo chmod 600 /etc/wp-backup/known_hosts
```

Puis, dans `config.conf` :

```bash
TUNNEL_SSH="UTILISATEUR@BASTION"
TUNNEL_PORT="PORT"
TUNNEL_REMOTE="10.1.60.10:9000"        # MinIO, vu depuis le bastion
TUNNEL_VAULT_REMOTE="10.1.60.50:8200"  # Vault, vu depuis le bastion
```

Le rebond refuse un bastion dont l'empreinte n'est pas déjà dans `known_hosts` (`StrictHostKeyChecking=yes`). Les adresses `endpoint` de `rclone.conf` et `VAULT_ADDR` sont alors remplacées automatiquement par les entrées locales du tunnel.

## Utilisation

```bash
sudo /opt/wp-backup/backup.sh                 # sauvegarde complète (étapes 1 à 5)
sudo /opt/wp-backup/verify.sh                 # revalide la dernière sauvegarde
sudo /opt/wp-backup/verify.sh <sauvegarde>    # revalide une sauvegarde précise
sudo /opt/wp-backup/restore.sh                # restauration (menu)
sudo tail -f /var/log/wp-backup.log           # journal du cron
```

## Tests réalisés

| Test | Résultat |
|---|---|
| Sauvegarde complète, connexion directe | Étapes 1 à 5 OK |
| Sauvegarde, validation et restauration via rebond SSH, MinIO et Vault rendus injoignables en direct | OK : tout passe par le tunnel, fermé à la fin |
| Bastion à l'empreinte inconnue | Rebond refusé |
| Archive remplacée dans le bucket | Validation échoue (hash ≠ JSON) |
| Archive **et** hash du JSON remplacés | Validation échoue (déchiffrement impossible) |
| Mauvaise clé / clé absente | Validation échoue |
| Rotation avec `KEEP_ARCHIVES=3` | La sauvegarde la plus ancienne est supprimée du bucket, et sa clé de Vault en mode `vault-kv` |
| Article supprimé + fichier `intrus.php` ajouté, puis restauration | Article revenu, `intrus.php` supprimé, hash final = hash initial |
| Exécution dans l'environnement de cron | OK |
| Modes `fichier`, `vault-kv` et `vault-transit` | Sauvegarde et validation OK pour les trois |
| Anciennes sauvegardes `vault-kv` relues en mode `vault-transit` | OK (méthode lue dans le JSON) |
| Sauvegarde à clé en clair (`fichier`) présentée alors que la config utilise Vault | Refusée (anti-rétrogradation) |
| Mauvais token Vault, Vault éteint, enveloppe `cle.key` falsifiée | Refusés |
| Restauration en mode `vault-transit` | OK |
| Token visible dans `ps` pendant une sauvegarde | Jamais |
| Deux exécutions simultanées / config en `644` / lancement sans root | Refusés |

## Limites connues

- **En mode `fichier`, la clé est en clair dans le bucket**, à côté de l'archive : qui lit le bucket peut déchiffrer. Les modes `vault-kv` et `vault-transit` corrigent ce point. En contrepartie, **Vault devient indispensable pour restaurer** (Disponibilité) : s'il est perdu, ou si sa clé Transit est supprimée, les archives sont illisibles.
- **Vault est joint en `http://`** : sans TLS, le token et les clés circulent en clair sur le réseau.
- **Une sauvegarde entièrement falsifiée ne serait pas détectée.** Un attaquant capable d'écrire dans le bucket pourrait remplacer d'un coup l'archive, le JSON et la clé par un ensemble cohérent. La parade : signer le JSON avec un secret conservé hors du bucket (HMAC ou signature GPG).
- **AES-CBC n'authentifie pas les données** : c'est la comparaison des hashs qui détecte les modifications.
- **Sans rebond SSH, le transfert est en clair** si MinIO et Vault sont en `http://`.
- **Le hash du dossier** couvre le contenu et les noms des fichiers, pas les droits ni les dates.
- **Le cron ne rattrape pas une exécution manquée** si la VM est éteinte (`anacron` le ferait), et `/var/log/wp-backup.log` est à confier à `logrotate`.
- **Le cahier des charges cite l'outil `mc`**, dont le binaire n'est plus téléchargeable sur dl.min.io (erreur 410). `rclone` est un client S3 équivalent, disponible dans les dépôts Ubuntu.
