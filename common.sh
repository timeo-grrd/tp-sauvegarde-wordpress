# shellcheck shell=bash
# =====================================================================
#  common.sh — fonctions partagées par backup.sh, verify.sh et restore.sh
#  Ce fichier est « sourcé », pas exécuté. Il garantit que les
#  empreintes sont calculées EXACTEMENT de la même façon partout.
# =====================================================================

# cron fournit un PATH minimal : on fixe le nôtre
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Tout fichier créé par les scripts (clé, JSON, archives) : lisible par root seul
umask 077

CONFIG_FILE="${WP_BACKUP_CONFIG:-/etc/wp-backup/config.conf}"

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERREUR : $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "À lancer en root : sudo $0"
}

# Un fichier lu par un script qui tourne en root ne doit être modifiable
# que par root, sinon n'importe qui pourrait y glisser des commandes.
check_secure_file() {
    local f="$1" perms
    [[ -f "$f" ]] || die "Fichier introuvable : $f"
    [[ "$(stat -c %u "$f")" -eq 0 ]] || die "$f doit appartenir à root (sudo chown root:root $f)"
    perms="$(stat -c %a "$f")"
    [[ "$perms" =~ ^[4-7]00$ ]] || die "$f est en $perms, il doit être en 600 (sudo chmod 600 $f)"
}

load_config() {
    check_secure_file "$CONFIG_FILE"
    # shellcheck source=config.example.conf
    source "$CONFIG_FILE"
    : "${SOURCE_DIR:?SOURCE_DIR manquant dans $CONFIG_FILE}"
    : "${S3_TARGET:?S3_TARGET manquant dans $CONFIG_FILE}"
    : "${RCLONE_CONFIG_FILE:?RCLONE_CONFIG_FILE manquant dans $CONFIG_FILE}"
    SOURCE_DIR="${SOURCE_DIR%/}"
    KEEP_ARCHIVES="${KEEP_ARCHIVES:-0}"
    PBKDF2_ITER="${PBKDF2_ITER:-200000}"
    SNAPSHOT_DIR="${SNAPSHOT_DIR:-/var/backups/wp-backup}"
    check_secure_file "$RCLONE_CONFIG_FILE"

    local c
    for c in tar gzip openssl rclone jq sha256sum flock rsync; do
        command -v "$c" >/dev/null || die "Commande manquante : $c (sudo apt install $c)"
    done
    if [[ -n "${DB_NAME:-}" ]]; then
        command -v mysqldump >/dev/null || die "mysqldump introuvable alors que DB_NAME est défini"
    fi
    KEY_BACKEND="${KEY_BACKEND:-fichier}"
    case "$KEY_BACKEND" in
        fichier|vault-kv|vault-transit) ;;
        *) die "KEY_BACKEND doit valoir fichier, vault-kv ou vault-transit (pas '$KEY_BACKEND')" ;;
    esac
    if [[ "$KEY_BACKEND" != fichier ]]; then
        : "${VAULT_ADDR:?VAULT_ADDR manquant dans $CONFIG_FILE}"
        : "${VAULT_TOKEN_FILE:?VAULT_TOKEN_FILE manquant dans $CONFIG_FILE}"
        command -v curl >/dev/null || die "Commande manquante : curl"
    fi
    if [[ -n "${VAULT_ADDR:-}" ]]; then
        check_secure_file "${VAULT_TOKEN_FILE:?VAULT_TOKEN_FILE manquant dans $CONFIG_FILE}"
    fi
    if [[ -n "${TUNNEL_SSH:-}" ]]; then
        : "${TUNNEL_KEY:?TUNNEL_KEY manquant dans $CONFIG_FILE}"
        : "${TUNNEL_KNOWN_HOSTS:?TUNNEL_KNOWN_HOSTS manquant dans $CONFIG_FILE}"
        check_secure_file "$TUNNEL_KEY"
        check_secure_file "$TUNNEL_KNOWN_HOSTS"
    fi
}

# --- Canal sécurisé : rebond SSH (optionnel) ----------------------------
# Si TUNNEL_SSH est défini, on ouvre une connexion SSH vers la machine de
# rebond (bastion) et on y fait passer, chiffrés :
#   127.0.0.1:TUNNEL_LOCAL_PORT       -> bastion -> MinIO (TUNNEL_REMOTE)
#   127.0.0.1:TUNNEL_VAULT_LOCAL_PORT -> bastion -> Vault (TUNNEL_VAULT_REMOTE)
TUNNEL_SOCK=""
open_tunnel() {
    [[ -n "${TUNNEL_SSH:-}" ]] || return 0
    local renvois=(-L "127.0.0.1:${TUNNEL_LOCAL_PORT:-19000}:${TUNNEL_REMOTE:-localhost:9000}")
    if [[ -n "${TUNNEL_VAULT_REMOTE:-}" ]]; then
        renvois+=(-L "127.0.0.1:${TUNNEL_VAULT_LOCAL_PORT:-18200}:$TUNNEL_VAULT_REMOTE")
    fi
    TUNNEL_SOCK="$(mktemp -u /run/wp-backup-ssh.XXXXXX)"
    log "Ouverture du rebond SSH via $TUNNEL_SSH (port ${TUNNEL_PORT:-22})..."
    # StrictHostKeyChecking=yes : on refuse un serveur dont l'empreinte
    # n'est pas déjà connue (protection contre l'interception).
    ssh -f -N -M -S "$TUNNEL_SOCK" -p "${TUNNEL_PORT:-22}" -i "$TUNNEL_KEY" \
        -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$TUNNEL_KNOWN_HOSTS" \
        "${renvois[@]}" "$TUNNEL_SSH" </dev/null \
        || die "Impossible d'ouvrir le rebond SSH via $TUNNEL_SSH"
}
close_tunnel() {
    [[ -n "$TUNNEL_SOCK" && -S "$TUNNEL_SOCK" ]] || return 0
    ssh -S "$TUNNEL_SOCK" -O exit "$TUNNEL_SSH" 2>/dev/null || true
}

# rclone avec notre config. </dev/null : rclone ne doit jamais lire le
# clavier (sinon il « avale » les réponses aux questions de restore.sh).
# Avec un tunnel, on remplace l'adresse de MinIO par l'entrée du tunnel
# (une variable RCLONE_CONFIG_<REMOTE>_ENDPOINT l'emporte sur rclone.conf).
rc() {
    local env_endpoint=()
    if [[ -n "${TUNNEL_SSH:-}" ]]; then
        local remote="${S3_TARGET%%:*}"
        remote="${remote^^}"
        env_endpoint=("RCLONE_CONFIG_${remote//-/_}_ENDPOINT=http://127.0.0.1:${TUNNEL_LOCAL_PORT:-19000}")
    fi
    env "${env_endpoint[@]}" rclone --config "$RCLONE_CONFIG_FILE" "$@" </dev/null
}

# --- Empreintes ---------------------------------------------------------
# Empreinte SHA-256 d'un DOSSIER : on calcule l'empreinte de chaque
# fichier, on trie la liste « empreinte  ./chemin » puis on hache cette
# liste. Le résultat change si un fichier est modifié, ajouté, supprimé
# ou renommé. Les chemins sont relatifs : le dossier peut être comparé
# à une copie extraite ailleurs (/tmp/...). Les droits, propriétaires et
# dates ne sont PAS pris en compte.
hash_dir() {
    ( cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum ) \
        | sha256sum | cut -d' ' -f1
}

hash_file() { sha256sum "$1" | cut -d' ' -f1; }

# --- Chiffrement symétrique AES-256-CBC ---------------------------------
# La clé est passée par FICHIER (-pass file:) et jamais en argument : un
# argument est visible par tous les utilisateurs de la machine via `ps`.
encrypt() {  # encrypt <fichier_clé> <itérations>  (stdin -> stdout)
    openssl enc -aes-256-cbc -salt -pbkdf2 -md sha256 -iter "$2" -pass "file:$1"
}
decrypt() {  # decrypt <fichier_clé> <itérations> <archive>  (-> stdout)
    openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 -iter "$2" -pass "file:$1" -in "$3"
}

# --- Gestion de la clé symétrique ---------------------------------------
# KEY_BACKEND choisit d'où vient la clé et ce qui part dans le bucket
# (toujours dans un fichier cle.key) :
#   fichier       : clé générée par OpenSSL, envoyée telle quelle
#   vault-kv      : clé générée par OpenSSL, rangée dans Vault (moteur KV) ;
#                   cle.key ne contient que son emplacement dans Vault
#   vault-transit : clé générée PAR Vault (moteur Transit) ; cle.key
#                   contient la clé chiffrée par Vault (« enveloppe »),
#                   illisible sans un token Vault autorisé

# Le token Vault est écrit dans un fichier d'en-tête HTTP lu par curl
# (-H @fichier) : il n'apparaît jamais dans les arguments d'une commande.
VAULT_HEADER=""
VAULT_URL=""
vault_init() {  # vault_init <dossier_de_travail>
    [[ -n "${VAULT_ADDR:-}" ]] || return 0
    # Avec le rebond SSH, Vault est joint par l'entrée locale du tunnel
    if [[ -n "${TUNNEL_SSH:-}" && -n "${TUNNEL_VAULT_REMOTE:-}" ]]; then
        VAULT_URL="http://127.0.0.1:${TUNNEL_VAULT_LOCAL_PORT:-18200}"
    else
        VAULT_URL="${VAULT_ADDR%/}"
    fi
    VAULT_HEADER="$1/vault-header"
    printf 'X-Vault-Token: %s\n' "$(tr -d '[:space:]' < "$VAULT_TOKEN_FILE")" > "$VAULT_HEADER"
}

# vault_api <GET|POST> <chemin_api>   (pour POST, le corps JSON est lu sur stdin)
vault_api() {
    [[ -n "$VAULT_HEADER" ]] || die "Vault n'est pas configuré (VAULT_ADDR / VAULT_TOKEN_FILE)"
    local corps=()
    [[ "$1" == POST ]] && corps=(-H "Content-Type: application/json" --data-binary @-)
    curl -sS -m 15 --fail-with-body -H "@$VAULT_HEADER" -X "$1" "${corps[@]}" \
        "$VAULT_URL/v1/$2"
}

# make_key <clé_en_clair> <cle.key_pour_le_bucket> <nom_sauvegarde>
make_key() {
    local clair="$1" sortie="$2" nom="$3" rep
    case "$KEY_BACKEND" in
        fichier)
            openssl rand -hex 32 | tr -d '\n' > "$clair"
            cp "$clair" "$sortie"
            ;;
        vault-kv)
            openssl rand -hex 32 | tr -d '\n' > "$clair"
            jq -n --rawfile cle "$clair" '{data: {cle: $cle}}' \
                | vault_api POST "$VAULT_KV_MOUNT/data/$VAULT_KV_PREFIX/$nom" >/dev/null \
                || die "Impossible d'enregistrer la clé dans Vault ($VAULT_KV_MOUNT/$VAULT_KV_PREFIX/$nom)"
            printf '%s/%s/%s' "$VAULT_KV_MOUNT" "$VAULT_KV_PREFIX" "$nom" > "$sortie"
            ;;
        vault-transit)
            rep="$clair.reponse"
            echo '{"bits": 256}' \
                | vault_api POST "$VAULT_TRANSIT_MOUNT/datakey/plaintext/$VAULT_TRANSIT_KEY" > "$rep" \
                || die "Vault n'a pas fourni de clé ($VAULT_TRANSIT_MOUNT/datakey/$VAULT_TRANSIT_KEY)"
            jq -jer '.data.plaintext' "$rep" > "$clair" || die "Réponse de Vault invalide"
            jq -jer '.data.ciphertext' "$rep" > "$sortie" || die "Réponse de Vault invalide"
            rm -f "$rep"
            ;;
    esac
}

# fetch_key <metadata.json> <cle.key_du_bucket> <clé_en_clair>
# Retrouve la clé en clair d'après la méthode notée dans le JSON.
fetch_key() {
    local json="$1" entree="$2" clair="$3" gestion chemin cle_transit
    gestion="$(jq -r '.chiffrement.gestion_cle // "fichier"' "$json")"
    case "$gestion" in
        fichier)
            # Anti-rétrogradation : si on utilise Vault, on refuse une
            # sauvegarde qui prétend porter sa clé en clair (un attaquant
            # pourrait en déposer une avec SA clé pour contourner Vault).
            [[ "$KEY_BACKEND" == fichier ]] \
                || die "Sauvegarde à clé en clair refusée alors que KEY_BACKEND=$KEY_BACKEND (substitution possible). Pour la lire volontairement : KEY_BACKEND=fichier"
            cp "$entree" "$clair"
            ;;
        vault-kv)
            chemin="$(cat "$entree")"
            vault_api GET "${chemin%%/*}/data/${chemin#*/}" | jq -jer '.data.data.cle' > "$clair" \
                || die "Clé introuvable dans Vault ($chemin)"
            ;;
        vault-transit)
            cle_transit="$(jq -r '.chiffrement.vault_transit_cle' "$json")"
            jq -n --rawfile c "$entree" '{ciphertext: $c}' \
                | vault_api POST "${VAULT_TRANSIT_MOUNT:-transit}/decrypt/$cle_transit" \
                | jq -jer '.data.plaintext' > "$clair" \
                || die "Vault a refusé de déchiffrer la clé (token, droits ou cle.key modifié ?)"
            ;;
        *)
            die "Méthode de gestion de clé inconnue dans le JSON : $gestion"
            ;;
    esac
}

# delete_vault_key <nom_sauvegarde>
# Lors de la rotation : supprime de Vault la clé d'une sauvegarde en mode
# vault-kv, pour ne pas laisser de clés orphelines dans le coffre. (En
# vault-transit, la clé n'existe que chiffrée dans le bucket : rien à faire.)
delete_vault_key() {
    local nom="$1" meta chemin
    meta="$(rc cat "$S3_TARGET/$nom/metadata.json" 2>/dev/null)" || return 0
    [[ "$(jq -r '.chiffrement.gestion_cle // "fichier"' <<<"$meta")" == vault-kv ]] || return 0
    chemin="$(rc cat "$S3_TARGET/$nom/cle.key" 2>/dev/null)" || return 0
    if vault_api DELETE "${chemin%%/*}/metadata/${chemin#*/}" >/dev/null; then
        log "    Clé supprimée de Vault ($chemin)"
    else
        log "    AVERTISSEMENT : clé non supprimée de Vault ($chemin)"
    fi
}

# --- Étape 5 : validation à partir du bucket UNIQUEMENT -----------------
# verify_backup <nom_sauvegarde> <dossier_de_travail>
# Télécharge archive + JSON + clé depuis MinIO, puis :
#   a) compare l'empreinte de l'archive chiffrée à celle du JSON ;
#   b) déchiffre l'archive avec la clé ;
#   c) compare l'empreinte du dossier déchiffré à l'empreinte initiale.
# Le contenu déchiffré reste dans <dossier>/extrait (utilisé par restore.sh).
verify_backup() {
    local name="$1" dir="$2" f iter hash_chiffre hash_initial source hash_final
    mkdir -p "$dir/extrait"

    log "5/5 Récupération de $name depuis le bucket..."
    rc copy "$S3_TARGET/$name" "$dir" || die "Échec du téléchargement de $name"
    for f in archive.tar.gz.enc metadata.json cle.key; do
        [[ -f "$dir/$f" ]] || die "$f absent de la sauvegarde $name"
    done

    hash_chiffre="$(jq -er '.hash_archive_chiffree.valeur' "$dir/metadata.json")" || die "JSON invalide"
    hash_initial="$(jq -er '.hash_initial.valeur' "$dir/metadata.json")" || die "JSON invalide"
    source="$(jq -er '.chemin_source' "$dir/metadata.json")" || die "JSON invalide"
    iter="$(jq -er '.chiffrement.iterations' "$dir/metadata.json")" || die "JSON invalide"

    log "    a) Intégrité de l'archive chiffrée..."
    [[ "$(hash_file "$dir/archive.tar.gz.enc")" == "$hash_chiffre" ]] \
        || die "Empreinte de l'archive différente de celle du JSON : archive corrompue ou modifiée"
    log "       $hash_chiffre : conforme au JSON"

    log "    b) Déchiffrement avec la clé symétrique ($(jq -r '.chiffrement.gestion_cle // "fichier"' "$dir/metadata.json"))..."
    fetch_key "$dir/metadata.json" "$dir/cle.key" "$dir/cle.clair"
    decrypt "$dir/cle.clair" "$iter" "$dir/archive.tar.gz.enc" | tar -xzpf - -C "$dir/extrait" \
        || die "Déchiffrement impossible (mauvaise clé ou archive abîmée)"

    log "    c) Contrôle final : empreinte du dossier déchiffré..."
    [[ -d "$dir/extrait/${source#/}" ]] || die "$source absent de l'archive"
    hash_final="$(hash_dir "$dir/extrait/${source#/}")"
    [[ "$hash_final" == "$hash_initial" ]] \
        || die "Le dossier déchiffré ($hash_final) ne correspond pas au hash initial ($hash_initial)"
    log "       $hash_final : identique au hash initial de production"
}
