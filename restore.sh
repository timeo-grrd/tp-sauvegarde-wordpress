#!/usr/bin/env bash
# =====================================================================
#  restore.sh — Restaure une sauvegarde du bucket sur le site (bonus)
#
#   1. Choix de la sauvegarde dans le bucket
#   2. Validation complète (comme verify.sh) : hash de l'archive,
#      déchiffrement, hash du dossier déchiffré
#   3. Snapshot de l'état actuel, puis remplacement de /var/www
#   4. Restauration de la base (optionnelle) et vérification finale
#
#  Usage : sudo ./restore.sh                -> menu
#          sudo ./restore.sh <sauvegarde>   -> sauvegarde précise
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root
load_config

exec 9>/run/lock/wp-backup.lock
flock -n 9 || die "Une sauvegarde ou une restauration est déjà en cours"

WORKDIR="$(mktemp -d)"
trap 'close_tunnel; rm -rf "$WORKDIR"' EXIT
vault_init "$WORKDIR"
open_tunnel

# --- 1. Choix de la sauvegarde -----------------------------------------
log "Liste des sauvegardes dans $S3_TARGET..."
LISTE="$(rc lsf "$S3_TARGET" --dirs-only | sed 's:/$::' | grep '^wordpress_' | sort -r || true)"
[[ -n "$LISTE" ]] || die "Aucune sauvegarde dans $S3_TARGET (ou bucket inaccessible)"
mapfile -t SAUVEGARDES <<< "$LISTE"

CHOIX=""
if [[ $# -ge 1 ]]; then
    CHOIX="$1"
    printf '%s\n' "${SAUVEGARDES[@]}" | grep -qxF -- "$CHOIX" \
        || die "Sauvegarde '$CHOIX' absente du bucket"
else
    echo
    echo "Sauvegardes disponibles (la plus récente en premier) :"
    PS3=$'\n'"Numéro de la sauvegarde à restaurer : "
    select CHOIX in "${SAUVEGARDES[@]}"; do
        [[ -n "${CHOIX:-}" ]] && break
        echo "Choix invalide, recommence."
    done
    [[ -n "${CHOIX:-}" ]] || die "Aucune sauvegarde sélectionnée"
fi

# --- 2. Validation complète --------------------------------------------
DIR="$WORKDIR/sauvegarde"
verify_backup "$CHOIX" "$DIR"
SOURCE="$(jq -r '.chemin_source' "$DIR/metadata.json")"
HASH_INITIAL="$(jq -r '.hash_initial.valeur' "$DIR/metadata.json")"
[[ "$SOURCE" == "$SOURCE_DIR" ]] \
    || die "Cette sauvegarde concerne $SOURCE, la config indique $SOURCE_DIR"

# --- Confirmation ------------------------------------------------------
echo
echo "  Sauvegarde : $CHOIX"
echo "  Cible      : $SOURCE_DIR"
echo "  /!\\ Le contenu actuel de $SOURCE_DIR sera REMPLACÉ."
read -rp "Confirmer la restauration ? (oui/non) " ans
if [[ "$ans" != "oui" ]]; then
    log "Restauration annulée."
    exit 0
fi

# --- 3. Snapshot puis remplacement ------------------------------------
install -d -m 700 "$SNAPSHOT_DIR"
SNAP="$SNAPSHOT_DIR/pre-restore_$(date +%Y-%m-%d_%H-%M-%S).tar.gz"
log "Snapshot de l'état actuel -> $SNAP"
tar -czpf "$SNAP" -C / "${SOURCE_DIR#/}"

log "Restauration de $SOURCE_DIR..."
mkdir -p "$SOURCE_DIR"
rsync -a --delete "$DIR/extrait/${SOURCE_DIR#/}/" "$SOURCE_DIR/"

# --- 4. Base de données -----------------------------------------------
if [[ -f "$DIR/extrait/database.sql" ]]; then
    if [[ -n "${DB_NAME:-}" ]]; then
        read -rp "La sauvegarde contient un dump SQL. Restaurer aussi la base '$DB_NAME' ? (oui/non) " ans
        if [[ "$ans" == "oui" ]]; then
            log "Import du dump dans '$DB_NAME'..."
            mysql "$DB_NAME" < "$DIR/extrait/database.sql" || die "Échec de l'import SQL"
        fi
    else
        log "Dump SQL présent mais DB_NAME vide dans la config : base non restaurée."
    fi
fi

[[ "$(hash_dir "$SOURCE_DIR")" == "$HASH_INITIAL" ]] \
    || die "Après restauration, $SOURCE_DIR n'a pas l'empreinte attendue"
log "Restauration terminée et vérifiée (empreinte identique au hash initial)."
