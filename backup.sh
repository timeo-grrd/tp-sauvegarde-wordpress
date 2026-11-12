#!/usr/bin/env bash
# =====================================================================
#  backup.sh — Archive le site web (et la BDD si configurée) puis
#              l'envoie sur le serveur de sauvegarde via SSH.
#  Usage : ./backup.sh        (sans sudo : sudo est demandé si besoin)
# =====================================================================
# Les variables des commandes SSH sont volontairement développées côté client :
# shellcheck disable=SC2029
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERREUR : $*" >&2; exit 1; }

# --- Vérifications préalables ---------------------------------------
# Lancé avec sudo, SSH utiliserait les clés de root et non les tiennes.
[[ $EUID -ne 0 ]] || die "Lance ce script SANS sudo (il le demandera lui-même)."
[[ -f "$CONFIG_FILE" ]] || die "Config absente : $CONFIG_FILE (cp config.example.conf config.conf)"
# shellcheck source=config.example.conf
source "$CONFIG_FILE"

[[ -f "$SSH_KEY" ]] || die "Clé SSH introuvable : $SSH_KEY (voir README)"

# -n : ssh ne lit pas le clavier (sinon il « avale » les réponses aux questions suivantes)
SSH_OPTS=(-n -i "$SSH_KEY" -p "$BACKUP_PORT" -o BatchMode=yes -o ConnectTimeout=10)
SCP_OPTS=(-i "$SSH_KEY" -P "$BACKUP_PORT" -o BatchMode=yes -o ConnectTimeout=10)
REMOTE="$BACKUP_USER@$BACKUP_HOST"

# Chemins relatifs à / pour tar (on archive "var/www", pas "/var/www")
REL_PATHS=()
for p in "${BACKUP_PATHS[@]}"; do
    p="${p%/}"
    [[ -d "$p" ]] || die "Dossier à sauvegarder introuvable : $p"
    REL_PATHS+=("${p#/}")
done

# --- Préparation ----------------------------------------------------
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
ARCHIVE_NAME="wordpress_$(hostname)_${TIMESTAMP}.tar.gz"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
ARCHIVE="$WORKDIR/$ARCHIVE_NAME"

log "Test de la connexion SSH vers $REMOTE..."
ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p '$REMOTE_DIR' && chmod 700 '$REMOTE_DIR'" \
    || die "Connexion SSH impossible. La clé est-elle installée sur le serveur ? (voir README)"

# --- Dump de la base (optionnel) ------------------------------------
TAR_EXTRA=()
if [[ -n "${DB_NAME:-}" ]]; then
    log "Dump de la base '$DB_NAME'..."
    # Redirection volontairement faite par TON shell : le fichier t'appartient.
    # shellcheck disable=SC2024
    sudo mysqldump --single-transaction "$DB_NAME" > "$WORKDIR/database.sql" \
        || die "mysqldump a échoué (la base '$DB_NAME' existe-t-elle ?)"
    TAR_EXTRA=(-C "$WORKDIR" database.sql)
fi

# --- Archivage ------------------------------------------------------
# sudo : certains fichiers (wp-config, config BDD) ne sont lisibles que par root/www-data.
# -p conserve les permissions, tar conserve propriétaires et liens symboliques.
log "Création de l'archive $ARCHIVE_NAME (${BACKUP_PATHS[*]})..."
sudo tar -czpf "$ARCHIVE" -C / "${REL_PATHS[@]}" "${TAR_EXTRA[@]}" \
    || die "Échec de la création de l'archive"
sudo chown "$(id -u):$(id -g)" "$ARCHIVE"
log "Archive créée : $(du -h "$ARCHIVE" | cut -f1)"

# --- Transfert + vérification d'intégrité ---------------------------
LOCAL_SUM="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"

log "Transfert vers $REMOTE:$REMOTE_DIR/ ..."
scp -q "${SCP_OPTS[@]}" "$ARCHIVE" "$REMOTE:$REMOTE_DIR/" || die "Échec du transfert"

REMOTE_SUM="$(ssh "${SSH_OPTS[@]}" "$REMOTE" "sha256sum '$REMOTE_DIR/$ARCHIVE_NAME'" | cut -d' ' -f1)"
[[ "$LOCAL_SUM" == "$REMOTE_SUM" ]] \
    || die "Empreintes SHA-256 différentes : l'archive a été corrompue pendant le transfert"
log "Transfert vérifié (sha256 identique)."

# --- Rotation : on ne garde que les N archives les plus récentes ----
if [[ "${KEEP_ARCHIVES:-0}" -gt 0 ]]; then
    log "Rotation : conservation des $KEEP_ARCHIVES dernières archives..."
    ssh "${SSH_OPTS[@]}" "$REMOTE" \
        "cd '$REMOTE_DIR' && ls -1t wordpress_*.tar.gz | tail -n +$((KEEP_ARCHIVES + 1)) | xargs -r rm -f --"
fi

log "Sauvegarde terminée : $REMOTE:$REMOTE_DIR/$ARCHIVE_NAME"
