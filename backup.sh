#!/usr/bin/env bash
# =====================================================================
#  backup.sh — Sauvegarde sécurisée de /var/www vers MinIO (S3)
#  Respecte l'ordre du cahier des charges (triade CIA) :
#
#   1. Hash initial du dossier en clair                     (Intégrité)
#   2. Génération d'une clé symétrique + chiffrement        (Confidentialité)
#   3. Hash de l'archive chiffrée + métadonnées JSON        (Traçabilité)
#   4. Envoi archive + JSON + clé dans le bucket MinIO      (Disponibilité)
#   5. Validation depuis le bucket : hash archive, déchiffrement,
#      hash du dossier déchiffré = hash initial
#   + rotation des anciennes sauvegardes
#
#  Usage : sudo ./backup.sh        (ou par cron, en root)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root
load_config

# Une seule exécution à la fois (cron + lancement manuel simultanés)
exec 9>/run/lock/wp-backup.lock
flock -n 9 || die "Une sauvegarde est déjà en cours"

[[ -d "$SOURCE_DIR" ]] || die "Dossier à sauvegarder introuvable : $SOURCE_DIR"

NAME="wordpress_$(hostname)_$(date +%Y-%m-%d_%H-%M-%S)"
WORKDIR="$(mktemp -d)"
trap 'close_tunnel; rm -rf "$WORKDIR"' EXIT
OUT="$WORKDIR/envoi"          # les 3 fichiers à envoyer
mkdir "$OUT"
KEYFILE="$WORKDIR/cle.clair"  # clé en clair : ne quitte jamais la machine
ARCHIVE="$OUT/archive.tar.gz.enc"

log "Début de la sauvegarde $NAME"
vault_init "$WORKDIR"
open_tunnel
rc lsf "$S3_TARGET" --max-depth 1 >/dev/null \
    || die "Bucket $S3_TARGET inaccessible : vérifie rclone.conf, le réseau et le nom du bucket"

# --- 1. Hash initial ---------------------------------------------------
log "1/5 Hash initial du dossier $SOURCE_DIR..."
HASH_INITIAL="$(hash_dir "$SOURCE_DIR")"
log "    $HASH_INITIAL"

# --- 2. Clé symétrique + chiffrement -----------------------------------
# Clé de 256 bits, nouvelle à chaque sauvegarde : une clé qui fuit
# n'ouvre qu'une seule archive. Selon KEY_BACKEND, elle est générée par
# OpenSSL ou fournie par HashiCorp Vault (voir make_key dans common.sh).
case "$KEY_BACKEND" in
    fichier)       log "2/5 Génération d'une clé symétrique aléatoire (256 bits, OpenSSL)..." ;;
    vault-kv)      log "2/5 Génération d'une clé symétrique (256 bits) et dépôt dans Vault ($VAULT_KV_MOUNT/$VAULT_KV_PREFIX/$NAME)..." ;;
    vault-transit) log "2/5 Clé symétrique (256 bits) fournie par Vault Transit ($VAULT_TRANSIT_KEY)..." ;;
esac
make_key "$KEYFILE" "$OUT/cle.key" "$NAME"

TAR_EXTRA=()
if [[ -n "${DB_NAME:-}" ]]; then
    log "    Dump de la base '$DB_NAME' (ajouté à l'archive)..."
    mysqldump --single-transaction "$DB_NAME" > "$WORKDIR/database.sql" \
        || die "mysqldump a échoué (la base '$DB_NAME' existe-t-elle ?)"
    TAR_EXTRA=(-C "$WORKDIR" database.sql)
fi
# tar compresse et envoie directement dans openssl : aucune archive en
# clair n'est jamais écrite sur le disque.
log "    Compression et chiffrement AES-256 de $SOURCE_DIR..."
tar -czpf - -C / "${SOURCE_DIR#/}" "${TAR_EXTRA[@]}" \
    | encrypt "$KEYFILE" "$PBKDF2_ITER" > "$ARCHIVE" \
    || die "Échec de la compression ou du chiffrement"
log "    Archive chiffrée : $(du -h "$ARCHIVE" | cut -f1)"

# --- 3. Hash de l'archive chiffrée + JSON ------------------------------
log "3/5 Hash de l'archive chiffrée et métadonnées JSON..."
HASH_CHIFFRE="$(hash_file "$ARCHIVE")"
log "    $HASH_CHIFFRE"
jq -n \
    --arg sauvegarde "$NAME" \
    --arg horodatage "$(date --iso-8601=seconds)" \
    --arg hote "$(hostname)" \
    --arg source "$SOURCE_DIR" \
    --arg hash_initial "$HASH_INITIAL" \
    --arg hash_chiffre "$HASH_CHIFFRE" \
    --argjson iter "$PBKDF2_ITER" \
    --arg gestion "$KEY_BACKEND" \
    --arg transit "${VAULT_TRANSIT_KEY:-}" \
    --arg base "${DB_NAME:-}" \
    '{
        sauvegarde: $sauvegarde,
        horodatage: $horodatage,
        hote: $hote,
        chemin_source: $source,
        hash_initial:          { algo: "sha256", valeur: $hash_initial },
        hash_archive_chiffree: { algo: "sha256", valeur: $hash_chiffre },
        chiffrement: ({ algo: "aes-256-cbc", derivation: "pbkdf2-sha256",
                        iterations: $iter, fichier_cle: "cle.key", gestion_cle: $gestion }
                      + (if $gestion == "vault-transit" then { vault_transit_cle: $transit } else {} end)),
        base_de_donnees_incluse: $base
    }' > "$OUT/metadata.json"

# --- 4. Envoi vers MinIO ------------------------------------------------
log "4/5 Envoi de l'archive, du JSON et de la clé vers $S3_TARGET/$NAME/..."
rc copy "$OUT" "$S3_TARGET/$NAME" || die "Échec de l'envoi vers le bucket"
rm -rf "$OUT"   # plus aucune copie locale : la validation utilise le bucket

# --- 5. Validation depuis le bucket ------------------------------------
verify_backup "$NAME" "$WORKDIR/validation"

# --- Rotation : on garde les N dernières sauvegardes de CETTE machine --
if (( KEEP_ARCHIVES > 0 )); then
    mapfile -t ANCIENNES < <(rc lsf "$S3_TARGET" --dirs-only | sed 's:/$::' \
        | grep "^wordpress_$(hostname)_" | sort -r | tail -n +"$((KEEP_ARCHIVES + 1))")
    for a in "${ANCIENNES[@]}"; do
        log "Rotation : suppression de $a"
        delete_vault_key "$a"
        rc purge "$S3_TARGET/$a"
    done
fi

log "Sauvegarde terminée et validée : $S3_TARGET/$NAME/"
