#!/usr/bin/env bash
# =====================================================================
#  restore.sh — Récupère une archive sur le serveur de sauvegarde et
#               la restaure sur le serveur de production.
#  Usage : ./restore.sh              -> menu pour choisir l'archive
#          ./restore.sh <archive>    -> restaure directement cette archive
# =====================================================================
# Les variables des commandes SSH sont volontairement développées côté client :
# shellcheck disable=SC2029
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERREUR : $*" >&2; exit 1; }

# --- Vérifications préalables ---------------------------------------
[[ $EUID -ne 0 ]] || die "Lance ce script SANS sudo (il le demandera lui-même)."
[[ -f "$CONFIG_FILE" ]] || die "Config absente : $CONFIG_FILE (cp config.example.conf config.conf)"
# shellcheck source=config.example.conf
source "$CONFIG_FILE"

command -v rsync >/dev/null || die "rsync n'est pas installé : sudo apt install rsync"
[[ -f "$SSH_KEY" ]] || die "Clé SSH introuvable : $SSH_KEY (voir README)"

# -n : ssh ne lit pas le clavier (sinon il « avale » les réponses aux questions suivantes)
SSH_OPTS=(-n -i "$SSH_KEY" -p "$BACKUP_PORT" -o BatchMode=yes -o ConnectTimeout=10)
SCP_OPTS=(-i "$SSH_KEY" -P "$BACKUP_PORT" -o BatchMode=yes -o ConnectTimeout=10)
REMOTE="$BACKUP_USER@$BACKUP_HOST"

# --- 1. Liste des archives disponibles sur le serveur ---------------
log "Récupération de la liste des archives sur $REMOTE..."
LISTING="$(ssh "${SSH_OPTS[@]}" "$REMOTE" \
    "cd '$REMOTE_DIR' 2>/dev/null && ls -1t -- wordpress_*.tar.gz 2>/dev/null || true")" \
    || die "Connexion SSH impossible"
[[ -n "$LISTING" ]] || die "Aucune archive trouvée dans $REMOTE:$REMOTE_DIR"
mapfile -t ARCHIVES <<< "$LISTING"

# --- 2. Sélection de l'archive --------------------------------------
CHOICE=""
if [[ $# -ge 1 ]]; then
    CHOICE="$1"
    found=0
    for a in "${ARCHIVES[@]}"; do
        if [[ "$a" == "$CHOICE" ]]; then found=1; fi
    done
    [[ $found -eq 1 ]] || die "Archive '$CHOICE' introuvable sur le serveur"
else
    echo
    echo "Archives disponibles (la plus récente en premier) :"
    PS3=$'\n'"Numéro de l'archive à restaurer : "
    select CHOICE in "${ARCHIVES[@]}"; do
        [[ -n "${CHOICE:-}" ]] && break
        echo "Choix invalide, recommence."
    done
    [[ -n "${CHOICE:-}" ]] || die "Aucune archive sélectionnée"
fi

# --- 3. Téléchargement et extraction dans un dossier temporaire -----
WORKDIR="$(mktemp -d)"
# Les fichiers extraits appartiennent à root/www-data : sudo peut être nécessaire
trap 'rm -rf "$WORKDIR" 2>/dev/null || sudo rm -rf "$WORKDIR"' EXIT
STAGING="$WORKDIR/extract"
mkdir "$STAGING"

log "Téléchargement de $CHOICE..."
scp -q "${SCP_OPTS[@]}" "$REMOTE:$REMOTE_DIR/$CHOICE" "$WORKDIR/" || die "Échec du téléchargement"

log "Extraction dans un dossier temporaire (vérifie aussi l'intégrité de l'archive)..."
sudo tar -xzpf "$WORKDIR/$CHOICE" -C "$STAGING" || die "Archive corrompue ou illisible"

# On ne restaure QUE les dossiers listés dans la config : tout autre
# contenu éventuel de l'archive est ignoré.
for p in "${BACKUP_PATHS[@]}"; do
    p="${p%/}"
    [[ -d "$STAGING/${p#/}" ]] || die "$p est absent de cette archive"
done

# --- 4. Confirmation ------------------------------------------------
echo
echo "  Archive : $CHOICE"
echo "  Cible   : ${BACKUP_PATHS[*]}"
echo "  /!\\ Le contenu actuel de ces dossiers sera REMPLACÉ."
read -rp "Confirmer la restauration ? (oui/non) " ans
if [[ "$ans" != "oui" ]]; then
    log "Restauration annulée."
    exit 0
fi

# --- 5. Filet de sécurité : snapshot de l'état actuel ---------------
CURRENT=()
for p in "${BACKUP_PATHS[@]}"; do
    p="${p%/}"
    if [[ -d "$p" ]]; then CURRENT+=("${p#/}"); fi
done
if [[ ${#CURRENT[@]} -gt 0 ]]; then
    SNAP="$HOME/pre-restore_$(date +%Y-%m-%d_%H-%M-%S).tar.gz"
    log "Snapshot de l'état actuel avant écrasement -> $SNAP"
    sudo tar -czpf "$SNAP" -C / "${CURRENT[@]}"
    sudo chown "$(id -u):$(id -g)" "$SNAP"
fi

# --- 6. Restauration des fichiers -----------------------------------
# rsync --delete : la cible devient identique à l'archive (les fichiers
# ajoutés depuis la sauvegarde sont supprimés). -a conserve droits et propriétaires.
for p in "${BACKUP_PATHS[@]}"; do
    p="${p%/}"
    log "Restauration de $p..."
    sudo mkdir -p "$p"
    sudo rsync -a --delete "$STAGING/${p#/}/" "$p/"
done

# --- 7. Restauration de la base (si présente dans l'archive) --------
if [[ -f "$STAGING/database.sql" ]]; then
    if [[ -n "${DB_NAME:-}" ]]; then
        read -rp "L'archive contient un dump SQL. Restaurer aussi la base '$DB_NAME' ? (oui/non) " ans
        if [[ "$ans" == "oui" ]]; then
            log "Import du dump dans '$DB_NAME'..."
            sudo cat "$STAGING/database.sql" | sudo mysql "$DB_NAME" \
                || die "Échec de l'import SQL"
        fi
    else
        log "Dump SQL présent mais DB_NAME vide dans la config : base non restaurée."
    fi
fi

log "Restauration terminée. Vérifie le site dans le navigateur."
