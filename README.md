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
| **2. Clé + chiffrement** (1,5) | `openssl rand -hex 32` : clé de 256 bits, nouvelle à chaque sauvegarde (simule la fourniture d'un secret par Vault). `tar -cz` envoyé directement dans `openssl enc -aes-256-cbc -pbkdf2` : aucune archive en clair sur le disque, et la clé est passée par fichier, jamais en argument (sinon elle serait visible dans `ps`) |
| **3. Hash archive + JSON** (0,5) | SHA-256 de l'archive chiffrée. `metadata.json` construit avec `jq` : horodatage, chemin source, hash initial, hash de l'archive chiffrée, paramètres de chiffrement |
| **4. Transfert vers MinIO** (1) | `rclone copy` des 3 fichiers dans `bucket/<sauvegarde>/`. Canal sécurisé : tunnel SSH optionnel (voir plus bas) |
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

## Canal sécurisé : tunnel SSH (optionnel)

Avec un endpoint `http://`, le trafic S3 circule **en clair** sur le réseau, y compris `cle.key`. Quelqu'un qui écoute le réseau récupère alors l'archive et sa clé. Si `TUNNEL_SSH` est renseigné, le script ouvre un tunnel SSH chiffré vers le serveur de sauvegarde, y fait passer tout le trafic S3, puis le referme :

```
VM ──SSH chiffré (2223)──► serveur de sauvegarde ──► MinIO (localhost:9000)
```

```bash
sudo ssh-keygen -t ed25519 -N "" -f /etc/wp-backup/ssh_key -C wp-backup
sudo ssh-copy-id -i /etc/wp-backup/ssh_key.pub -p 2223 timeo@10.1.60.10
sudo ssh -p 2223 -i /etc/wp-backup/ssh_key -o UserKnownHostsFile=/etc/wp-backup/known_hosts timeo@10.1.60.10 exit
sudo chmod 600 /etc/wp-backup/known_hosts
```

Puis, dans `config.conf` : `TUNNEL_SSH="timeo@10.1.60.10"`. Le tunnel refuse un serveur dont l'empreinte n'est pas déjà dans `known_hosts` (`StrictHostKeyChecking=yes`).

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
| Sauvegarde complète via tunnel SSH, adresse directe rendue injoignable | OK : tout le trafic passe par le tunnel, fermé à la fin |
| Serveur SSH à l'empreinte inconnue | Tunnel refusé |
| Archive remplacée dans le bucket | Validation échoue (hash ≠ JSON) |
| Archive **et** hash du JSON remplacés | Validation échoue (déchiffrement impossible) |
| Mauvaise clé / clé absente | Validation échoue |
| Rotation avec `KEEP_ARCHIVES=3` | La sauvegarde la plus ancienne est supprimée |
| Article supprimé + fichier `intrus.php` ajouté, puis restauration | Article revenu, `intrus.php` supprimé, hash final = hash initial |
| Exécution dans l'environnement de cron | OK |
| Deux exécutions simultanées / config en `644` / lancement sans root | Refusés |

## Limites connues

- **La clé est stockée dans le bucket, à côté de l'archive** (exigence du cahier des charges). On privilégie la Disponibilité : la restauration reste possible même si la VM est perdue. Mais qui peut lire le bucket peut aussi déchiffrer. En production, la clé irait dans un coffre séparé (HashiCorp Vault), et seul son identifiant figurerait dans le JSON.
- **Une sauvegarde entièrement falsifiée ne serait pas détectée.** Un attaquant capable d'écrire dans le bucket pourrait remplacer d'un coup l'archive, le JSON et la clé par un ensemble cohérent. La parade : signer le JSON avec un secret conservé hors du bucket (HMAC ou signature GPG).
- **AES-CBC n'authentifie pas les données** : c'est la comparaison des hashs qui détecte les modifications.
- **Sans tunnel, le transfert est en clair** si MinIO est en `http://`.
- **Le hash du dossier** couvre le contenu et les noms des fichiers, pas les droits ni les dates.
- **Le cron ne rattrape pas une exécution manquée** si la VM est éteinte (`anacron` le ferait), et `/var/log/wp-backup.log` est à confier à `logrotate`.
- **Le cahier des charges cite l'outil `mc`**, dont le binaire n'est plus téléchargeable sur dl.min.io (erreur 410). `rclone` est un client S3 équivalent, disponible dans les dépôts Ubuntu.
