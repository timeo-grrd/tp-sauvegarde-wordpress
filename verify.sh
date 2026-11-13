#!/usr/bin/env bash
# =====================================================================
#  verify.sh — Étape 5 seule : valide une sauvegarde à partir du bucket
#  Télécharge archive + JSON + clé, vérifie le hash de l'archive,
#  la déchiffre et compare le hash du dossier au hash initial.
#  N'utilise que ce qui est dans MinIO : peut tourner sur n'importe
#  quelle machine qui a accès au bucket (ex. le serveur de sauvegarde).
#
#  Usage : sudo ./verify.sh                -> dernière sauvegarde
#          sudo ./verify.sh <sauvegarde>   -> sauvegarde précise
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root
load_config

WORKDIR="$(mktemp -d)"
trap 'close_tunnel; rm -rf "$WORKDIR"' EXIT
vault_init "$WORKDIR"
open_tunnel

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
    NAME="$(rc lsf "$S3_TARGET" --dirs-only | sed 's:/$::' | grep '^wordpress_' | sort -r | head -1)" \
        || die "Bucket inaccessible"
    [[ -n "$NAME" ]] || die "Aucune sauvegarde dans $S3_TARGET"
fi

verify_backup "$NAME" "$WORKDIR/validation"
log "Sauvegarde $NAME valide."
