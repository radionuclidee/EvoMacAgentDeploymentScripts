#!/bin/bash
#
# Evo macOS Agent deployment script (RMM-friendly) - Datto RMM variant.
#
# Kept in step with the manual PKG installer (preinstall / postinstall), the
# manual uninstaller (uninstall-helper.sh) and bootstrapSecureToken.sh.
#
#   * Deployment tokens (preferred provisioning since agent 2.5)
#   * --upgrade            install only if catalog version > installed
#   * --uninstall/--remove same steps and safety checks as the manual uninstaller
#   * --securetoken-only   grant the Evo hidden admin a SecureToken on an installed agent
#   * --beta               release channel switch
#   * --api-override-url --beacon-override-url   Evo API hostname override (staging / Proxmox labs)
#   * Catalog-driven .pkg lookup with SHA-256 verification
#   * Local .pkg via --pkg PATH, or a .pkg URL via --pkg-url
#     (legacy .dmg artifacts are still accepted, but .pkg is the supported format)
#
# Environment variables (set them as Datto component variables):
#   EVO_DEPLOYMENT_TOKEN          like --deployment-token
#   EVO_OVERRIDE_API_HOSTNAME     like --api-override-url
#   EVO_OVERRIDE_BEACON_HOSTNAME  like --beacon-override-url
#   EVO_DEPLOY_ENV / EVO_ENV      production | staging | local (default: production)
#   EVO_UPGRADE_NOW=true          like --upgrade
#   EVO_REMOVE_NOW=true           like --uninstall / --remove
#   EVO_SECURETOKEN_NOW=true      like --securetoken-only
#   EVO_PKG_PATH                  local .pkg on disk (skips catalog download; legacy .dmg accepted)
#   ADMIN_USERNAME                existing admin that already holds a SecureToken
#   ADMIN_PASSWORD                that admin's password
#                                 When both are set, the Evo hidden admin is granted a
#                                 SecureToken after a successful install. Environment only:
#                                 there is deliberately no command-line flag for these.
#   EVO_SECURETOKEN_WAIT_SECONDS  how long to keep retrying while the hidden admin is not
#                                 provisioned yet (default: 180)
#
# Exit codes:
#   0   success, or nothing to do
#   1   usage error / not run as root
#   2   pre-flight check failed (nothing was changed)
#   3   catalog / download / artifact problem (nothing was changed)
#   4   fresh install failed (the package removes its partial install)
#   5   upgrade failed (the package restores the previous installation)
#   6   installed, but deployment-token enrollment could not be confirmed
#   7   uninstall finished with errors; manual cleanup may be required
#   12  SecureToken: Helper reports ADMIN_USERNAME / ADMIN_PASSWORD missing
#   13  SecureToken: hidden admin not provisioned within EVO_SECURETOKEN_WAIT_SECONDS
#   14  SecureToken: ADMIN_USERNAME does not hold a SecureToken
#   15  SecureToken: grant failed (wrong password, etc.)
#   19  SecureToken: any other failure
#
# Proxmox / staging tip: you may still need an /etc/hosts entry, e.g.
#   echo "10.0.0.42  evo.evosecurity.local" | sudo tee -a /etc/hosts
# so the agent can resolve the override hostname (same constraint as Windows).
#
# Datto: set the variables in the component UI and run with no arguments:
#   sudo -E ./InstallEvoAgentDatto.sh

# --- Output helpers ---

log_ok()   { echo "OK: $*"; }
log_warn() { echo "Warning: $*"; }
log_err()  { echo "Error: $*"; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_true() {
    case "${1:-}" in
        [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]) return 0 ;;
    esac
    return 1
}

# --- Settings ---

CHANNEL="release"
DO_UPGRADE=false
if is_true "${EVO_UPGRADE_NOW:-}"; then DO_UPGRADE=true; fi
ACTION="install"
if is_true "${EVO_SECURETOKEN_NOW:-}"; then ACTION="securetoken"; fi
if is_true "${EVO_REMOVE_NOW:-}"; then ACTION="uninstall"; fi

ARTIFACT_URL=""
# Filled by ensure_work_dir() under a root-only mktemp.
WORK_DIR=""
DMG_PATH=""
PKG_TMP_PATH=""
MOUNT_POINT="/Volumes/EvoMacLogin"
# Trim stray whitespace: Datto sometimes injects it into component variables.
PKG_PATH_LOCAL="$(trim "${EVO_PKG_PATH:-}")"
DEPLOYMENT_TOKEN="$(trim "${EVO_DEPLOYMENT_TOKEN:-}")"
DEPLOY_ENV="$(trim "${EVO_DEPLOY_ENV:-${EVO_ENV:-}}")"
DEPLOY_ENV="${DEPLOY_ENV:-production}"
API_OVERRIDE_URL="$(trim "${EVO_OVERRIDE_API_HOSTNAME:-}")"
BEACON_OVERRIDE_URL="$(trim "${EVO_OVERRIDE_BEACON_HOSTNAME:-}")"
# The username is trimmed; the password is used exactly as given.
if [ -n "${ADMIN_USERNAME:-}" ]; then ADMIN_USERNAME="$(trim "$ADMIN_USERNAME")"; fi
SECURETOKEN_WAIT="$(trim "${EVO_SECURETOKEN_WAIT_SECONDS:-180}")"
SECURETOKEN_POLL=10

REMOTE_VERSION=""
REMOTE_NAME=""
REMOTE_SHA256=""
REQUIRE_ARTIFACT_CHECKSUM=false
IS_UPGRADE="no"
TOKEN_SENT=false
DMG_MOUNTED=false
DOWNLOADED_FILE=""
CATALOG_FILE=""
CLEAN_TOKEN_FILES=false
UNINSTALL_OK=true

# Install layout (must mirror the agent PKG payload)
EVO_SUPPORT_DIR="/Library/Application Support/Evo"
EVO_PACKAGE_ID="com.evosecurity.EvoLogin"
EA_PLUGIN_PATH="/Library/Security/SecurityAgentPlugins/EvoAuth.bundle"
LP_PLUGIN_PATH="/Library/Security/SecurityAgentPlugins/EvoLogin.bundle"
LOGIN_CONFIGURATION_APP="/Applications/Evo Secure Login Configuration.app"
AGENT_APP="${EVO_SUPPORT_DIR}/EvoSecurityAgent.app"
HELPER_BUNDLE_ID="com.evosecurity.EvoMacAgent.Helper"
HELPER_APP="/Library/PrivilegedHelperTools/${HELPER_BUNDLE_ID}.app"
HELPER_EXEC="${HELPER_APP}/Contents/MacOS/Helper"
HELPER_INFO_PLIST="${HELPER_APP}/Contents/Info.plist"
HELPER_DAEMON_PLIST="/Library/LaunchDaemons/${HELPER_BUNDLE_ID}.plist"
AGENT_BUNDLE_ID="com.evosecurity.EvoSecurityAgent"
AGENT_LAUNCHAGENT_PLIST="/Library/LaunchAgents/${AGENT_BUNDLE_ID}.plist"
UNINSTALLER_APP_DIR="${EVO_SUPPORT_DIR}/Uninstaller.app"
UNINSTALLER_SCRIPT="${UNINSTALLER_APP_DIR}/Contents/MacOS/uninstall-helper.sh"
SECURETOKEN_SCRIPT="${EVO_SUPPORT_DIR}/Scripts/bootstrapSecureToken.sh"
INSTALL_STATE_DIR="${EVO_SUPPORT_DIR}/.evo-install-state"
SECURETOKEN_MARKER="${EVO_SUPPORT_DIR}/.securetoken-deferred"
SECURETOKEN_MARKER_INSTALL_ALLOWANCE=600
SECURETOKEN_MARKER_WRITTEN=false
EVO_CONFIG="/Users/Shared/evo-config.json"
MANAGED_PREFS_PLIST="/Library/Managed Preferences/com.evosecurity.EvoLogin.plist"
AUTHORIZATION_PLIST="/System/Library/Security/authorization.plist"
HIDDEN_ADMIN="_evoAdmin"

# Files owned by this deployment script (not part of the PKG payload)
ROOT_EVO_DIR="/var/root/.evo"
API_OVERRIDE_JSON="${ROOT_EVO_DIR}/evo-api-override.json"
API_OVERRIDE_JSON_SYSTEM="${EVO_SUPPORT_DIR}/evo-api-override.json"
TOKEN_FINGERPRINT_FILE="${ROOT_EVO_DIR}/evo-deployment-token.sha256"
SEED_FILE="/private/tmp/evo-seed.json"
# Written by the manual installer UI. postinstall gives it top priority and ignores
# evoEnv on that path, so this script never writes it and always removes leftovers.
LEGACY_TOKEN_FILE="/tmp/evo-deployment-token.txt"

EXIT_USAGE=1
EXIT_PREFLIGHT=2
EXIT_ARTIFACT=3
EXIT_INSTALL_FAILED=4
EXIT_UPGRADE_FAILED=5
EXIT_ENROLL=6
EXIT_UNINSTALL=7
EXIT_ST_MISSING_CREDS=12
EXIT_ST_NOT_PROVISIONED=13
EXIT_ST_NO_TOKEN_HOLDER=14
EXIT_ST_GRANT_FAILED=15
EXIT_ST_OTHER=19

set -e

# --- Cleanup on every exit path ---

on_exit() {
    local rc=$?
    if $DMG_MOUNTED; then
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null \
            || hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
        DMG_MOUNTED=false
    fi
    if [ -n "$WORK_DIR" ] && [[ "$WORK_DIR" == /private/var/tmp/evo-dl.* ]]; then
        rm -rf "$WORK_DIR" 2>/dev/null || true
        WORK_DIR=""
        DOWNLOADED_FILE=""
        CATALOG_FILE=""
    else
        if [ -n "$DOWNLOADED_FILE" ]; then rm -f "$DOWNLOADED_FILE" 2>/dev/null || true; fi
        if [ -n "$CATALOG_FILE" ]; then rm -f "$CATALOG_FILE" 2>/dev/null || true; fi
    fi
    # Never leave a deployment token on disk. postinstall reads these only while it runs.
    if $CLEAN_TOKEN_FILES; then rm -f "$SEED_FILE" "$LEGACY_TOKEN_FILE" 2>/dev/null || true; fi
    if $SECURETOKEN_MARKER_WRITTEN; then rm -f "$SECURETOKEN_MARKER" 2>/dev/null || true; fi
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- General helpers ---

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log_err "Run as root (use: sudo -E $0 ...)"
        exit "$EXIT_USAGE"
    fi
}

show_help() {
    cat <<'EOF'
Evo macOS Agent deployment script (Datto RMM)
---------------------------------------------

Install / upgrade:
  sudo ./InstallEvoAgentDatto.sh                       # latest from catalog
  sudo ./InstallEvoAgentDatto.sh --upgrade             # only if catalog version > installed
  sudo ./InstallEvoAgentDatto.sh --beta                # use beta channel

Provisioning (preferred since agent 2.5):
  sudo ./InstallEvoAgentDatto.sh --deployment-token TKN [--environment production|staging|local]
  A token that is already applied (same token and environment, agent enrolled) is not
  re-sent; a different token re-enrolls the agent.

SecureToken for the Evo hidden admin (credentials from the environment only):
  sudo ADMIN_USERNAME=admin ADMIN_PASSWORD=... ./InstallEvoAgentDatto.sh [--upgrade]
  sudo ADMIN_USERNAME=admin ADMIN_PASSWORD=... ./InstallEvoAgentDatto.sh --securetoken-only

API hostname override (staging / Proxmox lab):
  sudo ./InstallEvoAgent.sh --api-override-url https://evo.evosecurity.local --beacon-override-url https://beacon-api.evosecurity.local
  (Proxmox: may also need /etc/hosts mapping for evo.evosecurity.local and beacon-api.evosecurity.local)

Local package (main scenario for testing):
  sudo ./InstallEvoAgentDatto.sh --pkg /path/to/EvoLogin.pkg       # install a local pkg, skip download
  sudo ./InstallEvoAgentDatto.sh --pkg-url https://.../file.pkg    # explicit pkg URL instead of the catalog
  (Legacy: a .dmg containing the pkg is still accepted by --pkg / --pkg-url.)

Uninstall:
  sudo ./InstallEvoAgentDatto.sh --uninstall           # alias: --remove

Environment variables (Datto component variables):
  EVO_DEPLOYMENT_TOKEN, EVO_OVERRIDE_API_HOSTNAME, EVO_DEPLOY_ENV
Environment variables (handy for Ninja RMM):
  EVO_DEPLOYMENT_TOKEN, EVO_OVERRIDE_API_HOSTNAME, EVO_OVERRIDE_BEACON_HOSTNAME,
  EVO_DEPLOY_ENV ADMIN_USERNAME, ADMIN_PASSWORD, EVO_SECURETOKEN_WAIT_SECONDS (default 180)

Datto: set variables in the component UI and run with no arguments:
  sudo -E ./InstallEvoAgentDatto.sh

Exit codes: 0 ok | 1 usage | 2 pre-flight | 3 download/artifact | 4 install failed
            5 upgrade failed (previous version restored) | 6 enrollment not confirmed
            7 uninstall errors | 12-19 SecureToken grant failures
EOF
}

# Compare dotted versions: returns 0 (true) iff $1 < $2.
# Non-numeric suffixes ("2.6.0-beta1") are ignored per component.
version_lt() {
    local -a a b
    local i x y
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    local max=$(( ${#a[@]} > ${#b[@]} ? ${#a[@]} : ${#b[@]} ))
    for (( i = 0; i < max; i++ )); do
        x="${a[i]:-0}"; y="${b[i]:-0}"
        x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
        x="${x:-0}"; y="${y:-0}"
        if (( 10#$x < 10#$y )); then return 0; fi
        if (( 10#$x > 10#$y )); then return 1; fi
    done
    return 1
}

installed_helper_version() {
    if [ -f "$HELPER_INFO_PLIST" ]; then
        /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HELPER_INFO_PLIST" 2>/dev/null || true
    fi
}

# Escape a string for use inside JSON double quotes (no python3 / CLT required).
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

has_existing_config() {
    # Same test postinstall uses to decide whether to keep the on-disk configuration.
    [ -s "$EVO_CONFIG" ] && /usr/bin/plutil -convert xml1 -o /dev/null "$EVO_CONFIG" >/dev/null 2>&1
}

has_mdm_preferences() {
    [ -f "$MANAGED_PREFS_PLIST" ] && return 0
    defaults read com.evosecurity.EvoLogin >/dev/null 2>&1
}

agent_is_enrolled() {
    [ -x "$HELPER_EXEC" ] && "$HELPER_EXEC" -is-enrolled >/dev/null 2>&1
}

# --- Catalog / download ---

parse_catalog_json() {
    local catalog_file="$1"
    local pkg_block

    # plutil: no extra "-" before the file path (- means stdin and breaks parsing).
    if REMOTE_VERSION=$(plutil -extract pkg.version raw -o - "$catalog_file" 2>/dev/null) && \
       REMOTE_NAME=$(plutil -extract pkg.name raw -o - "$catalog_file" 2>/dev/null); then
        REMOTE_SHA256=$(plutil -extract pkg.checksum raw -o - "$catalog_file" 2>/dev/null || true)
        return 0
    fi

    # Fallback: awk/sed only (no python3 / CLT). Handles the known catalog shape.
    pkg_block=$(awk '/"pkg"[[:space:]]*:/{flag=1; next} flag{print; if (/^[[:space:]]*\}/) exit}' "$catalog_file")
    REMOTE_VERSION=$(printf '%s\n' "$pkg_block" | sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    REMOTE_NAME=$(printf '%s\n' "$pkg_block" | sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    REMOTE_SHA256=$(printf '%s\n' "$pkg_block" | sed -n 's/^[[:space:]]*"checksum"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

    [ -n "$REMOTE_VERSION" ] && [ -n "$REMOTE_NAME" ]
}

ensure_work_dir() {
    if [ -n "$WORK_DIR" ]; then
        return 0
    fi
    WORK_DIR=$(mktemp -d /private/var/tmp/evo-dl.XXXXXX) || {
        log_err "Could not create a private download directory."
        exit "$EXIT_ARTIFACT"
    }
    chmod 700 "$WORK_DIR"
    PKG_TMP_PATH="$WORK_DIR/EvoMacLogin.pkg"
    DMG_PATH="$WORK_DIR/EvoMacLogin.dmg"
}

fetch_latest_metadata() {
    local info_url="https://download.evosecurity.com/${CHANNEL}/macos/evo-login-plugin-macos-latest-info.json"
    echo "Fetching catalog: $info_url"
    ensure_work_dir
    CATALOG_FILE="$WORK_DIR/evo-catalog.json"
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --retry 3 --retry-delay 5 -H 'Cache-Control: no-cache' \
            -o "$CATALOG_FILE" "$info_url"; then
        log_err "Failed to download catalog."
        exit "$EXIT_ARTIFACT"
    fi

    if ! parse_catalog_json "$CATALOG_FILE"; then
        log_err "Failed to parse catalog JSON."
        echo "   Pass --pkg PATH (or EVO_PKG_PATH) or --pkg-url URL explicitly."
        exit "$EXIT_ARTIFACT"
    fi
    rm -f "$CATALOG_FILE"
    CATALOG_FILE=""

    case "$REMOTE_NAME" in
        ''|*/*|*..*|*\?*|*'#'*|*$'\n'*)
            log_err "Catalog artifact name is missing or unsafe: '${REMOTE_NAME}'"
            exit "$EXIT_ARTIFACT"
            ;;
    esac
    if [ -z "$REMOTE_SHA256" ]; then
        log_err "Catalog entry for ${REMOTE_NAME} has no checksum; refusing to download."
        exit "$EXIT_ARTIFACT"
    fi

    ARTIFACT_URL="https://download.evosecurity.com/${CHANNEL}/macos/${REMOTE_NAME}"
    REQUIRE_ARTIFACT_CHECKSUM=true
    echo "Catalog: version=${REMOTE_VERSION}, name=${REMOTE_NAME}"
    if [ "$(artifact_type "$REMOTE_NAME")" != "pkg" ]; then
        log_warn "Catalog artifact is not a .pkg (${REMOTE_NAME}); using the legacy DMG path."
    fi
}

artifact_type() {
    case "$1" in
        *.pkg|*.PKG) echo "pkg" ;;
        *.dmg|*.DMG) echo "dmg" ;;
        *) echo "" ;;
    esac
}

local_artifact_version() {
    local name re='-([0-9]+(\.[0-9]+)+)'
    name=$(basename "$1")
    name="${name%.[Pp][Kk][Gg]}"
    if [[ "$name" =~ $re ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

verify_sha256() {
    local file="$1" expected="$2" required="${3:-false}" actual
    if [ -z "$expected" ]; then
        if [ "$required" = "true" ]; then
            log_err "No checksum available for this artifact; refusing to continue."
            exit "$EXIT_ARTIFACT"
        fi
        log_warn "No checksum available for this artifact; skipping SHA-256 verification."
        return 0
    fi
    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        log_err "SHA-256 mismatch (expected $expected, got $actual)"
        exit "$EXIT_ARTIFACT"
    fi
    log_ok "SHA-256 verified."
}

download_artifact() {
    local dest="$1"
    echo "Downloading $(basename "$ARTIFACT_URL") to $dest..."
    case "$ARTIFACT_URL" in
        https://*) ;;
        *)
            log_err "Refusing non-HTTPS artifact URL: $ARTIFACT_URL"
            exit "$EXIT_ARTIFACT"
            ;;
    esac
    rm -f "$dest"
    DOWNLOADED_FILE="$dest"
    if ! curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --retry 3 --retry-delay 5 -o "$dest" "$ARTIFACT_URL" || [ ! -s "$dest" ]; then
        log_err "Failed to download $ARTIFACT_URL"
        exit "$EXIT_ARTIFACT"
    fi
    log_ok "Downloaded to $dest"
    verify_sha256 "$dest" "$REMOTE_SHA256" "$REQUIRE_ARTIFACT_CHECKSUM"
}

# --- Pre-flight ---

securetoken_requested() {
    [ -n "${ADMIN_USERNAME:-}" ] || [ -n "${ADMIN_PASSWORD:-}" ]
}

check_securetoken_settings() {
    securetoken_requested || return 0
    if [ -z "${ADMIN_USERNAME:-}" ] || [ -z "${ADMIN_PASSWORD:-}" ]; then
        log_err "Only one of ADMIN_USERNAME / ADMIN_PASSWORD is set."
        echo "   Set both to grant the Evo hidden admin a SecureToken, or neither to skip that step."
        exit "$EXIT_PREFLIGHT"
    fi
    case "$SECURETOKEN_WAIT" in
        ''|*[!0-9]*)
            log_err "EVO_SECURETOKEN_WAIT_SECONDS must be a whole number of seconds (got '$SECURETOKEN_WAIT')."
            exit "$EXIT_PREFLIGHT"
            ;;
    esac
}

write_securetoken_marker() {
    securetoken_requested || return 0
    local expiry tmp
    expiry=$(( $(date +%s) + $1 ))
    mkdir -p "$EVO_SUPPORT_DIR"
    
    if ! tmp=$(mktemp "${EVO_SUPPORT_DIR}/.securetoken-deferred.XXXXXX"); then
        log_warn "Could not create the SecureToken deferral marker"
        return
    fi
    if printf '%s\n' "$expiry" > "$tmp" && chown root:wheel "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$SECURETOKEN_MARKER"; then
        SECURETOKEN_MARKER_WRITTEN=true
        echo "SecureToken deferral marker set"
    else
        rm -f "$tmp" 2>/dev/null || true
        log_warn "Could not write the SecureToken deferral marker"
    fi
}

remove_securetoken_marker() {
    $SECURETOKEN_MARKER_WRITTEN || return 0
    rm -f "$SECURETOKEN_MARKER" 2>/dev/null || true
        SECURETOKEN_MARKER_WRITTEN=false
}

# postinstall aborts the whole install (PAM exit code 12) when /usr/local has a
# user-writable ancestor, typically Homebrew on Intel. This is only an early hint;
# the Helper makes the real decision.
warn_if_pam_blocked() {
    local d owner perms
    for d in /usr/local /usr/local/lib /usr/local/lib/pam; do
        [ -e "$d" ] || continue
        owner=$(stat -f '%u' "$d" 2>/dev/null) || continue
        perms=$(stat -f '%Lp' "$d" 2>/dev/null) || continue
        if [ "$owner" != "0" ] || [ $(( 8#$perms & 8#022 )) -ne 0 ]; then
            log_warn "$d is not root-owned or is group/world-writable (Homebrew?)."
            echo "   The package's PAM step may refuse to install and fail the whole installation."
        fi
    done
}

preflight_install() {
    check_securetoken_settings
    if [ -z "$DEPLOYMENT_TOKEN" ] && ! has_existing_config && ! has_mdm_preferences; then
        log_err "Nothing to provision the agent from: no deployment token, no existing $EVO_CONFIG,"
        echo "   and no MDM-managed com.evosecurity.EvoLogin preferences. The package would fail its"
        echo "   fail-safe user check and abort. Set EVO_DEPLOYMENT_TOKEN on the Datto component"
        echo "   (or select a Deployment Token in the Evo Admin deployment) and retry."
        exit "$EXIT_PREFLIGHT"
    fi
    warn_if_pam_blocked
}

detect_existing_install() {
    # Same test preinstall uses to decide between upgrade (backup + rollback) and fresh install.
    if [ -f "$HELPER_DAEMON_PLIST" ] || [ -f "$HELPER_EXEC" ]; then
        IS_UPGRADE="yes"
    else
        IS_UPGRADE="no"
    fi
}

# --- Provisioning payload ---

prepare_api_override() {
    if [ -z "$API_OVERRIDE_URL" ] && [ -z "$BEACON_OVERRIDE_URL" ]; then
        if [ -f "$API_OVERRIDE_JSON_SYSTEM" ]; then
            log_warn "An API hostname override from an earlier run is still present ($API_OVERRIDE_JSON_SYSTEM);"
            echo "   postinstall will apply it again. Uninstall the agent to clear it."
        fi
        return 0
    fi
    local api="" beacon="" json=""
    if [ -n "$API_OVERRIDE_URL" ]; then
        api="${API_OVERRIDE_URL%/}"
        case "$api" in
            http://*|https://*) ;;
            *) api="https://${api}" ;;
        esac
        json="\"evoApiHostname\":\"$(json_escape "$api")\""
    fi
    if [ -n "$BEACON_OVERRIDE_URL" ]; then
        beacon="${BEACON_OVERRIDE_URL%/}"
        case "$beacon" in
            http://*|https://*) ;;
            *) beacon="https://${beacon}" ;;
        esac
        json="${json:+$json,}\"beaconServiceHostname\":\"$(json_escape "$beacon")\""
    fi
    
    mkdir -p "$ROOT_EVO_DIR" "$EVO_SUPPORT_DIR"
    (
        umask 077
        printf '{%s}\n' "$json" > "$API_OVERRIDE_JSON"
        printf '{%s}\n' "$json" > "$API_OVERRIDE_JSON_SYSTEM"
    )
    chmod 600 "$API_OVERRIDE_JSON" "$API_OVERRIDE_JSON_SYSTEM" || true
    if [ -n "$api" ]; then export EVO_API_OVERRIDE="$api"; fi
    log_ok "Override written: $API_OVERRIDE_JSON_SYSTEM (api=${api:-unchanged}, beacon=${beacon:-unchanged})"
}

token_fingerprint() {
    printf '%s\n%s' "$DEPLOY_ENV" "$DEPLOYMENT_TOKEN" | shasum -a 256 | awk '{print $1}'
}

# True when this exact token + environment was applied by an earlier run of this
# script and the agent is still enrolled with a valid configuration.
token_already_applied() {
    [ -f "$TOKEN_FINGERPRINT_FILE" ] || return 1
    has_existing_config || return 1
    agent_is_enrolled || return 1
    [ "$(cat "$TOKEN_FINGERPRINT_FILE" 2>/dev/null)" = "$(token_fingerprint)" ]
}

record_token_fingerprint() {
    mkdir -p "$ROOT_EVO_DIR"
    if ! ( umask 077; token_fingerprint > "$TOKEN_FINGERPRINT_FILE" ); then
        log_warn "Could not record the deployment token fingerprint; the next run will re-enroll."
    fi
}

prepare_deployment_payload() {
    # A leftover legacy token file would take priority over the seed file in postinstall.
    rm -f "$LEGACY_TOKEN_FILE" 2>/dev/null || true
    TOKEN_SENT=false

    if [ -z "$DEPLOYMENT_TOKEN" ]; then
        rm -f "$SEED_FILE" 2>/dev/null || true
        log_warn "EVO_DEPLOYMENT_TOKEN is not set; the package will keep the existing configuration or use MDM-managed preferences."
        return 0
    fi

    if token_already_applied; then
        rm -f "$SEED_FILE" 2>/dev/null || true
        log_ok "This deployment token (evoEnv=${DEPLOY_ENV}) is already applied and the agent is enrolled; keeping the current enrollment."
        echo "   Supply a different token to re-enroll."
        return 0
    fi

    local escaped_token escaped_env seed_tmp
    escaped_token=$(json_escape "$DEPLOYMENT_TOKEN")
    escaped_env=$(json_escape "$DEPLOY_ENV")
    # Write via mktemp + mv so a pre-existing symlink at SEED_FILE is replaced, not followed.
    seed_tmp=$(mktemp /private/tmp/evo-seed.XXXXXX) || {
        log_err "Could not create a temporary seed file."
        exit "$EXIT_ARTIFACT"
    }
    (
        umask 077
        printf '{"deploymentToken":"%s","evoEnv":"%s"}\n' "$escaped_token" "$escaped_env" > "$seed_tmp"
    )
    chmod 600 "$seed_tmp" || true
    mv -f "$seed_tmp" "$SEED_FILE"
    TOKEN_SENT=true
    log_ok "Wrote $SEED_FILE (evoEnv=${DEPLOY_ENV}, token length=${#DEPLOYMENT_TOKEN})"
}

# --- Install ---

show_install_log_tail() {
    local console_user user_home log shown=false
    local -a candidates=()
    console_user=$(stat -f "%Su" /dev/console 2>/dev/null || true)
    if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ "$console_user" != "_mbsetupuser" ]; then
        user_home=$(dscl . -read "/Users/$console_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        if [ -n "$user_home" ]; then candidates+=("$user_home/.evo/install.log"); fi
    fi
    candidates+=("$ROOT_EVO_DIR/install.log")
    for log in "${candidates[@]}"; do
        [ -f "$log" ] || continue
        echo "----- last 40 lines of $log -----"
        tail -n 40 "$log" || true
        echo "-----"
        shown=true
    done
    if ! $shown; then
        echo "   (no Evo installer log found; see /var/log/install.log)"
    fi
}

# Informational only: local dev builds are often unsigned, and installer(8) run as
# root installs them anyway. Production releases should show a Developer ID signature.
report_pkg_signature() {
    local pkg="$1" sig
    if sig=$(pkgutil --check-signature "$pkg" 2>/dev/null); then
        echo "Package signature: $(printf '%s\n' "$sig" | sed -n 's/^ *Status: *//p' | head -n 1)"
    else
        log_warn "$(basename "$pkg") is not signed (expected for local dev builds, not for releases)."
    fi
}

run_installer() {
    local pkg="$1" rc=0 now
    echo "Installing $(basename "$pkg")..."
    installer -pkg "$pkg" -target / || rc=$?
    if [ "$rc" -eq 0 ]; then
        log_ok "Package installed successfully."
        return 0
    fi

    log_err "installer exited with code $rc."
    show_install_log_tail
    if [ "$IS_UPGRADE" = "yes" ]; then
        now=$(installed_helper_version)
        log_err "Upgrade failed. The package rolls a failed upgrade back to the previous installation"
        echo "   and leaves it running (installed Helper version now: ${now:-unknown}). See the log above."
        exit "$EXIT_UPGRADE_FAILED"
    fi
    log_err "Installation failed. The package removes partially-installed components after a failed"
    echo "   fresh install. See the log above."
    exit "$EXIT_INSTALL_FAILED"
}

unmount_dmg() {
    $DMG_MOUNTED || return 0
    echo "Unmounting DMG..."
    hdiutil detach "$MOUNT_POINT" -quiet \
        || hdiutil detach "$MOUNT_POINT" -force -quiet \
        || log_warn "Could not unmount $MOUNT_POINT"
    DMG_MOUNTED=false
}

install_artifact_file() {
    local path="$1" kind inner_pkg
    kind=$(artifact_type "$path")
    case "$kind" in
        pkg)
            report_pkg_signature "$path"
            run_installer "$path"
            ;;
        dmg)
            # Legacy: releases now ship as a flat .pkg. Kept for older artifacts only.
            log_warn "DMG artifacts are deprecated; installing the .pkg found inside $(basename "$path")."
            if mount | grep -q " on ${MOUNT_POINT} "; then
                hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
            fi
            echo "Mounting $(basename "$path")..."
            if ! hdiutil attach "$path" -mountpoint "$MOUNT_POINT" -nobrowse -quiet; then
                log_err "Failed to mount DMG at $path"
                exit "$EXIT_ARTIFACT"
            fi
            DMG_MOUNTED=true
            echo "DMG mounted at $MOUNT_POINT"
            inner_pkg=$(find "$MOUNT_POINT" -type f -name "*.pkg" | head -n 1)
            if [ -z "$inner_pkg" ] || [ ! -f "$inner_pkg" ]; then
                log_err "No .pkg found in DMG."
                ls -la "$MOUNT_POINT" || true
                exit "$EXIT_ARTIFACT"
            fi
            echo "Found PKG: $(basename "$inner_pkg")"
            report_pkg_signature "$inner_pkg"
            run_installer "$inner_pkg"
            unmount_dmg
            ;;
        *)
            log_err "Artifact must be a .pkg file (or a legacy .dmg): $path"
            exit "$EXIT_ARTIFACT"
            ;;
    esac
}

# postinstall enrolls with the token and rolls back / fails on a bad token, so after a
# successful install this is a confirmation; the direct enrollment is a last resort.
confirm_enrollment() {
    [ -n "$DEPLOYMENT_TOKEN" ] || return 0
    if [ ! -x "$HELPER_EXEC" ]; then
        log_err "Helper not found at $HELPER_EXEC after install; cannot confirm enrollment."
        exit "$EXIT_ENROLL"
    fi
    if agent_is_enrolled; then
        if $TOKEN_SENT; then record_token_fingerprint; fi
        log_ok "Agent is enrolled (deployment token mode)."
        return 0
    fi

    log_warn "Agent is not enrolled after install; running Helper deployment-token enrollment directly..."
    echo "Environment: ${DEPLOY_ENV}"
    local rc=0
    "$HELPER_EXEC" -deployment-token "$DEPLOYMENT_TOKEN" -environment "$DEPLOY_ENV" || rc=$?
    if [ "$rc" -eq 0 ] && agent_is_enrolled; then
        record_token_fingerprint
        log_ok "Deployment token enrollment succeeded."
    else
        log_err "Deployment token enrollment failed (exit $rc)."
        echo "   Check token validity, Evo environment (EVO_DEPLOY_ENV), and network/API access."
        exit "$EXIT_ENROLL"
    fi
}

install_app() {
    require_root
    CLEAN_TOKEN_FILES=true
    detect_existing_install

    local artifact="" kind installed
    if [ -n "$PKG_PATH_LOCAL" ]; then
        if [ ! -f "$PKG_PATH_LOCAL" ]; then
            log_err "Local package not found: $PKG_PATH_LOCAL"
            exit "$EXIT_ARTIFACT"
        fi
        artifact="$PKG_PATH_LOCAL"
        REMOTE_VERSION=$(local_artifact_version "$artifact")
        echo "Local artifact version: ${REMOTE_VERSION:-unknown}"
    elif [ -z "$ARTIFACT_URL" ]; then
        fetch_latest_metadata
    fi

    # Version comparison before preflight so an already-current --upgrade run exits 0
    # even when this machine has no token / config / MDM prefs to provision from.
    if $DO_UPGRADE; then
        installed=$(installed_helper_version)
        if [ -z "$installed" ]; then
            echo "No prior install detected; performing a fresh install."
        elif [ -z "$REMOTE_VERSION" ]; then
            echo "Installed version $installed; package version unknown (local pkg / explicit URL), installing it anyway."
        elif ! version_lt "$installed" "$REMOTE_VERSION"; then
            log_ok "Already up to date (installed $installed >= catalog $REMOTE_VERSION). Skipping."
            exit 0
        else
            echo "Upgrade: $installed -> $REMOTE_VERSION"
        fi
    fi

    preflight_install

    if [ -z "$artifact" ]; then
        kind=$(artifact_type "$ARTIFACT_URL")
        if [ -z "$kind" ]; then
            log_warn "Could not infer artifact type from URL ($ARTIFACT_URL); treating it as a .pkg."
            kind="pkg"
        fi
        ensure_work_dir
        if [ "$kind" = "pkg" ]; then artifact="$PKG_TMP_PATH"; else artifact="$DMG_PATH"; fi
        download_artifact "$artifact"
    fi

    echo "Existing installation: ${IS_UPGRADE} ($( [ "$IS_UPGRADE" = "yes" ] && echo "upgrade, the package rolls back on failure" || echo "fresh install" ))"
    prepare_api_override
    prepare_deployment_payload
    write_securetoken_marker $(( SECURETOKEN_MARKER_INSTALL_ALLOWANCE + SECURETOKEN_WAIT + 60 ))
    export EVO_DEPLOY_ENV="$DEPLOY_ENV"

    install_artifact_file "$artifact"
    confirm_enrollment
    run_securetoken_bootstrap
    log_ok "Installation complete."
}

# --- SecureToken (bootstrapSecureToken.sh) ---

run_securetoken_bootstrap() {
    securetoken_requested || return 0

    local -a runner
    if [ -f "$SECURETOKEN_SCRIPT" ]; then
        runner=(/bin/bash "$SECURETOKEN_SCRIPT")
    elif [ -x "$HELPER_EXEC" ]; then
        log_warn "$SECURETOKEN_SCRIPT not found; calling the Helper directly."
        runner=("$HELPER_EXEC" -setupSecureToken)
    else
        log_err "Evo Helper not found at $HELPER_EXEC; cannot grant a SecureToken. Is the agent installed?"
        exit "$EXIT_ST_OTHER"
    fi

    # Credentials reach the child through its environment only, never its argv.
    export ADMIN_USERNAME ADMIN_PASSWORD

    echo "Granting the Evo hidden admin a SecureToken (holder: ${ADMIN_USERNAME})."
    echo "Waiting up to ${SECURETOKEN_WAIT}s for the hidden admin to be provisioned if needed..."
    local deadline attempt=0 rc=0
    deadline=$(( $(date +%s) + SECURETOKEN_WAIT ))
    write_securetoken_marker $(( SECURETOKEN_WAIT + 60 ))

    while :; do
        attempt=$(( attempt + 1 ))
        rc=0
        "${runner[@]}" || rc=$?
        [ "$rc" -eq 3 ] || break
        if [ "$(date +%s)" -ge "$deadline" ]; then break; fi
        echo "Hidden admin not provisioned yet (attempt ${attempt}); retrying in ${SECURETOKEN_POLL}s..."
        sleep "$SECURETOKEN_POLL"
    done
    unset ADMIN_PASSWORD
    remove_securetoken_marker

    case "$rc" in
        0)
            log_ok "SecureToken step finished (granted, already present, or not required on this volume)."
            return 0
            ;;
        2)
            log_err "SecureToken: the Helper reports ADMIN_USERNAME / ADMIN_PASSWORD missing."
            exit "$EXIT_ST_MISSING_CREDS"
            ;;
        3)
            log_err "SecureToken: the Evo hidden admin was not provisioned within ${SECURETOKEN_WAIT}s."
            echo "   The agent is installed; rerun with --securetoken-only (EVO_SECURETOKEN_NOW=true) later,"
            echo "   or raise EVO_SECURETOKEN_WAIT_SECONDS."
            exit "$EXIT_ST_NOT_PROVISIONED"
            ;;
        4)
            log_err "SecureToken: '${ADMIN_USERNAME}' does not hold a SecureToken; choose an admin that does."
            exit "$EXIT_ST_NO_TOKEN_HOLDER"
            ;;
        5)
            log_err "SecureToken: grant failed; verify ADMIN_PASSWORD is correct for '${ADMIN_USERNAME}'."
            exit "$EXIT_ST_GRANT_FAILED"
            ;;
        *)
            log_err "SecureToken: grant step exited with unexpected status ${rc} (see output above)."
            exit "$EXIT_ST_OTHER"
            ;;
    esac
}

securetoken_only() {
    require_root
    if ! securetoken_requested; then
        log_err "SecureToken mode needs ADMIN_USERNAME and ADMIN_PASSWORD in the environment."
        exit "$EXIT_PREFLIGHT"
    fi
    check_securetoken_settings
    if [ ! -x "$HELPER_EXEC" ]; then
        log_err "The Evo agent is not installed ($HELPER_EXEC is missing)."
        exit "$EXIT_PREFLIGHT"
    fi
    run_securetoken_bootstrap
}

# --- Uninstall (built-in pass mirrors uninstall-helper.sh, non-upgrade mode) ---

u_info()  { echo "  $*"; }
u_error() { log_err "$*"; UNINSTALL_OK=false; }

# Extracts a rule or right's stock definition from authorization.plist and writes
# it back with `security authorizationdb write`.
reset_from_authorization_plist() {
    local name="$1" tmp
    tmp=$(mktemp "/tmp/evo-authrule.XXXXXX") || return 1
    if /usr/libexec/PlistBuddy -x -c "Print :rights:${name}" "$AUTHORIZATION_PLIST" > "$tmp" 2>/dev/null \
       || /usr/libexec/PlistBuddy -x -c "Print :rules:${name}" "$AUTHORIZATION_PLIST" > "$tmp" 2>/dev/null; then
        if security authorizationdb write "$name" < "$tmp"; then
            rm -f "$tmp"
            return 0
        fi
    fi
    rm -f "$tmp"
    return 1
}

# Restores system.login.console (login) and authenticate to their system defaults.
reset_auth_rules() {
    local rule
    for rule in authenticate system.login.console; do
        u_info "Resetting '$rule' authorization rule to system default..."
        if security authorizationdb reset "$rule" 2>/dev/null; then
            u_info "Reset '$rule' via authorizationdb reset"
            continue
        fi
        u_info "authorizationdb reset did not handle '$rule'; writing stock definition from $AUTHORIZATION_PLIST"
        if ! reset_from_authorization_plist "$rule"; then
            u_error "Could not reset '$rule' authorization rule by any method"
        fi
    done
}

# Returns 0 if the authorization database no longer references our mechanisms.
authdb_is_clean() {
    if security authorizationdb read authenticate 2>/dev/null | grep -q "EvoAuth"; then return 1; fi
    if security authorizationdb read system.login.console 2>/dev/null | grep -q "EvoLogin"; then return 1; fi
    return 0
}

active_gui_uids() {
    local uids
    uids=$(launchctl print system 2>/dev/null \
        | sed -n 's|.*gui/\([0-9][0-9]*\).*|\1|p' \
        | sort -un)
    if [ -z "$uids" ]; then
        # stderr: this function's stdout is captured as the UID list.
        u_info "Could not enumerate GUI domains from launchd; falling back to the local user list" >&2
        uids=$(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 { print $2 }')
    fi
    echo "$uids"
}

unload_agent_for_uid() {
    local uid="$1" name
    name=$(id -un "$uid" 2>/dev/null || echo "?")

    if ! launchctl print "gui/$uid/$AGENT_BUNDLE_ID" >/dev/null 2>&1; then
        return 0
    fi
    u_info "Unloading EvoSecurityAgent for uid $uid ($name)..."
    if launchctl bootout "gui/$uid/$AGENT_BUNDLE_ID" 2>&1; then
        u_info "Unloaded for uid $uid via service target"
        return 0
    fi
    if [ -f "$AGENT_LAUNCHAGENT_PLIST" ] && launchctl bootout "gui/$uid" "$AGENT_LAUNCHAGENT_PLIST" 2>&1; then
        u_info "Unloaded for uid $uid via plist path"
        return 0
    fi
    if launchctl asuser "$uid" launchctl bootout "gui/$uid/$AGENT_BUNDLE_ID" 2>&1; then
        u_info "Unloaded for uid $uid via asuser"
        return 0
    fi
    u_error "Could not unload EvoSecurityAgent for uid $uid ($name)"
    return 1
}

remove_path() {
    local description="$1" path="$2"
    if [ -e "$path" ]; then
        if rm -rf "$path"; then
            u_info "removed $path"
        else
            u_error "Could not remove $description ($path)"
        fi
    else
        u_info "$description not found; skipping"
    fi
}

builtin_uninstall() {
    echo "Running built-in uninstall (same steps as uninstall-helper.sh)..."

    local uids uid helper_rc safe_to_delete_plugins=true
    uids=$(active_gui_uids)
    if [ -n "$uids" ]; then
        for uid in $uids; do
            unload_agent_for_uid "$uid" || true
        done
    else
        u_info "No active GUI sessions. Skipping EvoSecurityAgent unload."
    fi

    remove_path "EvoSecurityAgent LaunchAgent plist" "$AGENT_LAUNCHAGENT_PLIST"

    if launchctl print "system/$HELPER_BUNDLE_ID" >/dev/null 2>&1; then
        u_info "Evo Helper daemon is loaded. Unloading..."
        launchctl bootout "system/$HELPER_BUNDLE_ID" 2>&1 \
            || launchctl unload -w "$HELPER_DAEMON_PLIST" 2>&1 \
            || u_error "Could not unload Evo Helper daemon"
    else
        u_info "Evo Helper daemon is not loaded. Unloading skipped"
    fi

    # The Helper restores the authorization DB and removes the PAM integration,
    # Scripts and the hidden admin. Without it, restore the auth DB directly - but
    # only when it still references Evo, so other vendors' login mechanisms on an
    # already-clean DB are left untouched.
    if [ -x "$HELPER_EXEC" ]; then
        u_info "Performing cleanup with the helper tool"
        helper_rc=0
        "$HELPER_EXEC" -uninstall || helper_rc=$?
        if [ "$helper_rc" -ne 0 ]; then
            u_error "Helper-based cleanup reported failure (exit $helper_rc)"
            if authdb_is_clean; then
                u_info "Authorization database has no Evo references; no direct reset needed."
            else
                u_info "Falling back to direct authorization database restoration"
                reset_auth_rules
            fi
        fi
    elif authdb_is_clean; then
        u_info "Helper tool not found; authorization database has no Evo references, leaving it as is."
    else
        u_info "Helper tool not found; restoring the authorization database directly."
        reset_auth_rules
    fi

    if ! authdb_is_clean; then
        u_error "Authorization database still references our mechanisms after cleanup; retrying direct reset"
        reset_auth_rules
        if ! authdb_is_clean; then
            u_error "Authorization database STILL references our mechanisms."
            u_error "REFUSING to delete SecurityAgent plugins: removing them now would leave this Mac unable to log in."
            u_error "Manual recovery: security authorizationdb reset system.login.console && security authorizationdb reset authenticate"
            safe_to_delete_plugins=false
        else
            u_info "Authorization database clean after retry."
        fi
    else
        u_info "Authorization database clean; safe to remove plugins."
    fi

    if $safe_to_delete_plugins; then
        remove_path "Evo Auth Plugin" "$EA_PLUGIN_PATH"
        remove_path "Evo Login Plugin" "$LP_PLUGIN_PATH"
    else
        u_info "Leaving SecurityAgent plugins in place (see errors above)."
    fi

    remove_path "Evo Secure Login Configuration" "$LOGIN_CONFIGURATION_APP"
    remove_path "EvoSecurityAgent" "$AGENT_APP"
    remove_path "Evo Helper Agent" "$HELPER_APP"
    remove_path "Evo helper daemon plist" "$HELPER_DAEMON_PLIST"

    if dscl . -read "/Users/$HIDDEN_ADMIN" >/dev/null 2>&1; then
        u_info "Removing residual hidden admin account ($HIDDEN_ADMIN)..."
        dscl . -delete /Groups/admin GroupMembership "$HIDDEN_ADMIN" 2>/dev/null || true
        dscl . -delete "/Users/$HIDDEN_ADMIN" || u_error "Could not remove residual $HIDDEN_ADMIN account"
    fi

    if [ -f "$EVO_CONFIG" ]; then
        u_info "Removing residual configuration file $EVO_CONFIG..."
        rm -f "$EVO_CONFIG" || u_error "Could not remove residual evo-config.json"
    fi

    if [ -d "$UNINSTALLER_APP_DIR" ]; then
        rm -rf "$UNINSTALLER_APP_DIR" && u_info "removed $UNINSTALLER_APP_DIR" || true
    fi
}

# Prints every Evo component still present; returns 1 if anything is left.
report_residue() {
    local left=0 p
    if security authorizationdb read authenticate 2>/dev/null | grep -q "EvoAuth"; then
        echo "  - 'authenticate' rule still references EvoAuth"; left=1
    fi
    if security authorizationdb read system.login.console 2>/dev/null | grep -q "EvoLogin"; then
        echo "  - 'system.login.console' rule still references EvoLogin"; left=1
    fi
    if dscl . -read "/Users/$HIDDEN_ADMIN" >/dev/null 2>&1; then
        echo "  - $HIDDEN_ADMIN account still exists"; left=1
    fi
    for p in "$EVO_CONFIG" "$EA_PLUGIN_PATH" "$LP_PLUGIN_PATH" "$LOGIN_CONFIGURATION_APP" \
             "$AGENT_APP" "$HELPER_APP" "$HELPER_DAEMON_PLIST" "$AGENT_LAUNCHAGENT_PLIST" \
             "$UNINSTALLER_APP_DIR"; do
        if [ -e "$p" ]; then echo "  - still present: $p"; left=1; fi
    done
    return "$left"
}

is_agent_installed() {
    local p
    for p in "$HELPER_APP" "$AGENT_APP" "$HELPER_DAEMON_PLIST" "$AGENT_LAUNCHAGENT_PLIST" \
             "$EA_PLUGIN_PATH" "$LP_PLUGIN_PATH" "$LOGIN_CONFIGURATION_APP" \
             "$UNINSTALLER_APP_DIR" "$EVO_CONFIG"; do
        if [ -e "$p" ]; then return 0; fi
    done
    if dscl . -read "/Users/$HIDDEN_ADMIN" >/dev/null 2>&1; then return 0; fi
    if ! authdb_is_clean; then return 0; fi
    return 1
}

# Files this deployment script itself creates; the package uninstaller doesn't know them.
remove_deployment_leftovers() {
    local f
    for f in "$API_OVERRIDE_JSON" "$API_OVERRIDE_JSON_SYSTEM" "$TOKEN_FINGERPRINT_FILE" \
             "$SEED_FILE" "$LEGACY_TOKEN_FILE" "$SECURETOKEN_MARKER"; do
        if [ -e "$f" ]; then
            if rm -f "$f"; then u_info "removed $f"; else log_warn "could not remove $f"; fi
        fi
    done
    rm -rf "$INSTALL_STATE_DIR" 2>/dev/null || true
    rmdir "$EVO_SUPPORT_DIR" 2>/dev/null || true
}

forget_package_receipt() {
    if pkgutil --pkg-info "$EVO_PACKAGE_ID" >/dev/null 2>&1; then
        if pkgutil --forget "$EVO_PACKAGE_ID" >/dev/null 2>&1; then
            u_info "pkgutil --forget $EVO_PACKAGE_ID"
        else
            log_warn "could not forget package receipt $EVO_PACKAGE_ID"
        fi
    fi
}

uninstall_app() {
    require_root
    CLEAN_TOKEN_FILES=true

    if ! is_agent_installed; then
        echo "Nothing to uninstall: no Evo agent components found on this system."
        remove_deployment_leftovers
        forget_package_receipt
        exit 0
    fi

    local rc=0 residue
    if [ -f "$UNINSTALLER_SCRIPT" ]; then
        echo "Running installed uninstaller: $UNINSTALLER_SCRIPT"
        /bin/bash "$UNINSTALLER_SCRIPT" || rc=$?
        if [ "$rc" -ne 0 ]; then
            log_warn "Installed uninstaller exited with code $rc."
        fi
        if [ "$rc" -ne 0 ] || ! report_residue >/dev/null; then
            log_warn "Evo components remain after the installed uninstaller; running the built-in uninstall as a second pass."
            builtin_uninstall
        fi
    else
        echo "No on-disk uninstaller at $UNINSTALLER_SCRIPT."
        builtin_uninstall
    fi

    remove_deployment_leftovers

    echo "Verifying..."
    if residue=$(report_residue); then
        forget_package_receipt
        if $UNINSTALL_OK; then
            log_ok "Uninstall verification passed; Mac is in a clean state."
            exit 0
        fi
        log_err "Uninstall reached a clean state, but some steps reported errors (see above)."
        exit "$EXIT_UNINSTALL"
    fi

    log_err "Uninstall verification FAILED. Remaining Evo components:"
    echo "$residue"
    echo "   Additional manual cleanup may be required."
    exit "$EXIT_UNINSTALL"
}

# --- Argv ---

while [ $# -gt 0 ]; do
    case "$1" in
        --upgrade) DO_UPGRADE=true; shift ;;
        --beta) CHANNEL="beta"; shift ;;
        --uninstall|--remove) ACTION="uninstall"; shift ;;
        --install) ACTION="install"; shift ;;
        --securetoken-only) ACTION="securetoken"; shift ;;
        --deployment-token)
            DEPLOYMENT_TOKEN="$(trim "${2:-}")"
            [ -n "$DEPLOYMENT_TOKEN" ] || { log_err "--deployment-token requires a value"; exit "$EXIT_USAGE"; }
            shift 2 ;;
        --api-override-url)
            API_OVERRIDE_URL="$(trim "${2:-}")"
            [ -n "$API_OVERRIDE_URL" ] || { log_err "--api-override-url requires a value"; exit "$EXIT_USAGE"; }
            shift 2 ;;
        --beacon-override-url)
            BEACON_OVERRIDE_URL="$(trim "${2:-}")"
            [ -n "$BEACON_OVERRIDE_URL" ] || { log_err "--beacon-override-url requires a value"; exit "$EXIT_USAGE"; }
            shift 2 ;;
        --environment|--env)
            DEPLOY_ENV="$(trim "${2:-}")"
            [ -n "$DEPLOY_ENV" ] || { log_err "--environment requires a value"; exit "$EXIT_USAGE"; }
            shift 2 ;;
        --pkg)
            PKG_PATH_LOCAL="$(trim "${2:-}")"
            [ -n "$PKG_PATH_LOCAL" ] || { log_err "--pkg requires a path to a .pkg"; exit "$EXIT_USAGE"; }
            shift 2 ;;
        --pkg-url|--artifact-url|--dmg)
            ARTIFACT_URL="$(trim "${2:-}")"
            [ -n "$ARTIFACT_URL" ] || { log_err "$1 requires a URL"; exit "$EXIT_USAGE"; }
            shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *)
            log_err "Unknown option: $1 (use --help)"
            exit "$EXIT_USAGE"
            ;;
    esac
done

echo "=== Evo macOS Agent deployment ==="
echo "Running as: $(whoami)"
echo "Mode: ${ACTION}"
if [ "$ACTION" = "install" ]; then
    echo "Channel: ${CHANNEL}"
    echo "Upgrade only: ${DO_UPGRADE}"
    if [ -n "$PKG_PATH_LOCAL" ]; then echo "Local artifact: ${PKG_PATH_LOCAL}"; fi
    if [ -n "$DEPLOYMENT_TOKEN" ]; then echo "Deployment token: provided (evoEnv=${DEPLOY_ENV})"; fi
    if [ -n "$API_OVERRIDE_URL" ]; then echo "API override: ${API_OVERRIDE_URL}"; fi
    if [ -n "$BEACON_OVERRIDE_URL" ]; then echo "Beacon override: ${BEACON_OVERRIDE_URL}"; fi
    if securetoken_requested; then echo "SecureToken grant: requested (holder: ${ADMIN_USERNAME:-<missing>})"; fi
fi
echo "-------------------------------------"

case "$ACTION" in
    uninstall) uninstall_app ;;
    securetoken) securetoken_only ;;
    *) install_app ;;
esac
