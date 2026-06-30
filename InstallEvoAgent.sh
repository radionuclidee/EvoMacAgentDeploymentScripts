#!/bin/bash
#
# Evo macOS Agent installer (RMM-friendly).
#
# Originally: simple download-DMG / install-pkg / uninstall script.
# Added for parity with the Windows InstallEvoAgent.ps1 / NinjaOne RMM:
#   * Deployment tokens (preferred provisioning since agent 2.5)
#   * --upgrade           install only if catalog version > installed
#   * --uninstall/--remove (kept --uninstall name; --remove alias)
#   * --beta              release channel switch
#   * --api-override-url  Evo API hostname override (staging / Proxmox labs)
#   * Catalog-driven DMG lookup (replaces hard-coded DMG URL)
#   * SHA-256 verification of the downloaded artifact
#   * Local artifact via --pkg PATH or --dmg URL
#
# Equivalent environment variables (Ninja RMM friendly):
#   EVO_DEPLOYMENT_TOKEN       like --deployment-token
#   EVO_OVERRIDE_API_HOSTNAME  like --api-override-url
#   EVO_DEPLOY_ENV / EVO_ENV   production | staging | local (default: production)
#
# Proxmox / staging tip: you may still need an /etc/hosts entry, e.g.
#   echo "10.0.0.42  evo.evosecurity.local" | sudo tee -a /etc/hosts
# so the agent can resolve the override hostname (same constraint as Windows).
#
# Ninja example job:
#   #!/bin/bash
#   export EVO_DEPLOYMENT_TOKEN="$evoDeploymentToken"
#   export EVO_OVERRIDE_API_HOSTNAME="$evoApiOverride"
#   sudo -E /tmp/InstallEvoAgent.sh --upgrade

CHANNEL="release"
DO_UPGRADE=false
ACTION="install"
ARTIFACT_URL=""
DMG_PATH="/tmp/EvoMacLogin.dmg"
PKG_TMP_PATH="/tmp/EvoMacLogin.pkg"
MOUNT_POINT="/Volumes/EvoMacLogin"
PKG_PATH_LOCAL=""
DEPLOYMENT_TOKEN="${EVO_DEPLOYMENT_TOKEN:-}"
DEPLOY_ENV="${EVO_DEPLOY_ENV:-${EVO_ENV:-production}}"
API_OVERRIDE_URL="${EVO_OVERRIDE_API_HOSTNAME:-}"
REMOTE_VERSION=""
REMOTE_NAME=""
REMOTE_SHA256=""

HELPER_INFO_PLIST="/Library/PrivilegedHelperTools/com.evosecurity.EvoMacAgent.Helper.app/Contents/Info.plist"
UNINSTALLER_SCRIPT="/Library/Application Support/Evo/Uninstaller.app/Contents/MacOS/uninstall-helper.sh"
API_OVERRIDE_DIR="/var/root/.evo"
API_OVERRIDE_JSON="${API_OVERRIDE_DIR}/evo-api-override.json"

# Install layout (must mirror the agent PKG payload)
EVO_PACKAGE_ID="com.evosecurity.EvoLogin"
EA_PLUGIN_PATH="/Library/Security/SecurityAgentPlugins/EvoAuth.bundle"
LP_PLUGIN_PATH="/Library/Security/SecurityAgentPlugins/EvoLogin.bundle"
LOGIN_CONFIGURATION_APP="/Applications/Evo Secure Login Configuration.app"
AGENT_APP="/Library/Application Support/Evo/EvoSecurityAgent.app"
HELPER_BUNDLE_ID="com.evosecurity.EvoMacAgent.Helper"
HELPER_APP="/Library/PrivilegedHelperTools/${HELPER_BUNDLE_ID}.app"
HELPER_EXEC="${HELPER_APP}/Contents/MacOS/Helper"
HELPER_DAEMON_PLIST="/Library/LaunchDaemons/${HELPER_BUNDLE_ID}.plist"
AGENT_BUNDLE_ID="com.evosecurity.EvoSecurityAgent"
AGENT_LAUNCHAGENT_PLIST="/Library/LaunchAgents/${AGENT_BUNDLE_ID}.plist"
UNINSTALLER_APP_DIR="/Library/Application Support/Evo/Uninstaller.app"

set -e

# --- Helpers ---

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo "❌ Run as root (use: sudo $0 ...)"
        exit 1
    fi
}

show_help() {
    cat <<'EOF'
Evo macOS Agent Installer
-------------------------

Install / upgrade:
  sudo ./InstallEvoAgent.sh                       # latest from catalog
  sudo ./InstallEvoAgent.sh --upgrade             # only if catalog version > installed
  sudo ./InstallEvoAgent.sh --beta                # use beta channel

Provisioning (preferred since agent 2.5):
  sudo ./InstallEvoAgent.sh --deployment-token TKN [--environment production|staging|local]

API hostname override (staging / Proxmox lab):
  sudo ./InstallEvoAgent.sh --api-override-url https://evo.evosecurity.local
  (Proxmox: usually also needs /etc/hosts mapping for evo.evosecurity.local)

Local artifacts:
  sudo ./InstallEvoAgent.sh --pkg /path/to.pkg    # install a local pkg, skip download
  sudo ./InstallEvoAgent.sh --dmg https://.../file.dmg   # explicit DMG URL

Uninstall:
  sudo ./InstallEvoAgent.sh --uninstall           # alias: --remove

Equivalent environment variables (handy for Ninja RMM):
  EVO_DEPLOYMENT_TOKEN, EVO_OVERRIDE_API_HOSTNAME, EVO_DEPLOY_ENV
EOF
}

# Compare dotted versions: returns 0 (true) iff $1 < $2
version_lt() {
    local IFS=.
    local -a a=($1) b=($2)
    local i max=$(( ${#a[@]} > ${#b[@]} ? ${#a[@]} : ${#b[@]} ))
    for (( i = 0; i < max; i++ )); do
        local x="${a[i]:-0}" y="${b[i]:-0}"
        if [ "$((10#$x))" -lt "$((10#$y))" ]; then return 0; fi
        if [ "$((10#$x))" -gt "$((10#$y))" ]; then return 1; fi
    done
    return 1
}

installed_helper_version() {
    if [ -f "$HELPER_INFO_PLIST" ]; then
        /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HELPER_INFO_PLIST" 2>/dev/null || true
    fi
}

fetch_latest_metadata() {
    local info_url="https://download.evosecurity.com/${CHANNEL}/macos/evo-login-plugin-macos-latest-info.json"
    echo "Fetching catalog: $info_url"
    local json
    json=$(curl -fsSL -H 'Cache-Control: no-cache' "$info_url") || {
        echo "❌ Failed to download catalog."
        exit 1
    }
    if ! command -v /usr/bin/python3 >/dev/null 2>&1; then
        echo "❌ /usr/bin/python3 is not available; cannot parse catalog."
        echo "   Either install Command Line Tools, or pass --dmg URL / --pkg PATH explicitly."
        exit 1
    fi
    local parsed
    parsed=$(echo "$json" | /usr/bin/python3 -c '
import json, sys
j = json.load(sys.stdin)
p = j["pkg"]
print(p["version"])
print(p["name"])
print(p.get("checksum", ""))
')
    REMOTE_VERSION=$(echo "$parsed" | sed -n '1p')
    REMOTE_NAME=$(echo "$parsed" | sed -n '2p')
    REMOTE_SHA256=$(echo "$parsed" | sed -n '3p')
    ARTIFACT_URL="https://download.evosecurity.com/${CHANNEL}/macos/${REMOTE_NAME}"
    echo "Catalog: version=${REMOTE_VERSION}, name=${REMOTE_NAME}"
}

artifact_type() {
    case "$1" in
        *.pkg|*.PKG) echo "pkg" ;;
        *.dmg|*.DMG) echo "dmg" ;;
        *) echo "" ;;
    esac
}

verify_sha256() {
    local file="$1" expected="$2"
    [ -n "$expected" ] || return 0
    local actual
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "❌ SHA-256 mismatch (expected $expected, got $actual)"
        exit 1
    fi
    echo "✅ SHA-256 verified."
}

prepare_api_override() {
    [ -n "$API_OVERRIDE_URL" ] || return 0
    local url="${API_OVERRIDE_URL%/}"
    case "$url" in
        http://*|https://*) ;;
        *) url="https://${url}" ;;
    esac
    mkdir -p "$API_OVERRIDE_DIR"
    printf '{"evoApiHostname":"%s"}\n' "$url" > "$API_OVERRIDE_JSON"
    chmod 600 "$API_OVERRIDE_JSON" || true
    export EVO_API_OVERRIDE="$url"
    echo "✅ API override written: $API_OVERRIDE_JSON ($url)"
}

write_deployment_payload() {
    [ -n "$DEPLOYMENT_TOKEN" ] || return 0
    rm -f /tmp/evo-deployment-token.txt /private/tmp/evo-seed.json 2>/dev/null || true
    if command -v /usr/bin/python3 >/dev/null 2>&1; then
        DEPLOYMENT_TOKEN="$DEPLOYMENT_TOKEN" DEPLOY_ENV="$DEPLOY_ENV" /usr/bin/python3 -c '
import json, os
with open("/private/tmp/evo-seed.json", "w") as f:
    json.dump({"deploymentToken": os.environ["DEPLOYMENT_TOKEN"], "evoEnv": os.environ.get("DEPLOY_ENV") or "production"}, f)
'
        chmod 600 /private/tmp/evo-seed.json || true
        echo "✅ Wrote /private/tmp/evo-seed.json (evoEnv=${DEPLOY_ENV})"
    else
        umask 077
        printf '%s' "$DEPLOYMENT_TOKEN" > /tmp/evo-deployment-token.txt
        chmod 600 /tmp/evo-deployment-token.txt || true
        echo "✅ Wrote /tmp/evo-deployment-token.txt"
    fi
}

# --- Functions (kept from the original, lightly augmented) ---

download_dmg() {
    echo "Downloading $(basename "$ARTIFACT_URL") to /tmp..."
    curl -L -o "$DMG_PATH" "$ARTIFACT_URL"

    if [ ! -f "$DMG_PATH" ]; then
        echo "❌ Failed to download DMG."
        exit 1
    fi

    echo "✅ DMG downloaded to $DMG_PATH"

    if [ -n "$REMOTE_SHA256" ]; then
        verify_sha256 "$DMG_PATH" "$REMOTE_SHA256"
    fi
}

download_pkg() {
    echo "Downloading $(basename "$ARTIFACT_URL") to /tmp..."
    curl -L -o "$PKG_TMP_PATH" "$ARTIFACT_URL"

    if [ ! -f "$PKG_TMP_PATH" ]; then
        echo "❌ Failed to download PKG."
        exit 1
    fi

    echo "✅ PKG downloaded to $PKG_TMP_PATH"

    if [ -n "$REMOTE_SHA256" ]; then
        verify_sha256 "$PKG_TMP_PATH" "$REMOTE_SHA256"
    fi
}

mount_dmg() {
    echo "Mounting DMG..."
    if hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet; then
        echo "DMG mounted at $MOUNT_POINT"
    else
        echo "❌ Failed to mount DMG at $DMG_PATH"
        exit 1
    fi
}

unmount_dmg() {
    echo "Unmounting DMG..."
    hdiutil detach "$MOUNT_POINT" -quiet || echo "⚠️ Could not unmount (may already be detached)"
}

install_app() {
    require_root

    if [ -z "$ARTIFACT_URL" ] && [ -z "$PKG_PATH_LOCAL" ]; then
        fetch_latest_metadata
    fi

    if $DO_UPGRADE; then
        local installed
        installed=$(installed_helper_version)
        if [ -n "$installed" ] && [ -n "$REMOTE_VERSION" ]; then
            if ! version_lt "$installed" "$REMOTE_VERSION"; then
                echo "✅ Already up to date (installed $installed >= catalog $REMOTE_VERSION). Skipping."
                exit 0
            fi
            echo "Upgrade: $installed -> $REMOTE_VERSION"
        elif [ -z "$installed" ]; then
            echo "No prior install detected; performing a fresh install."
        fi
    fi

    prepare_api_override
    write_deployment_payload
    export EVO_DEPLOY_ENV="$DEPLOY_ENV"

    if [ -n "$PKG_PATH_LOCAL" ]; then
        if [ ! -f "$PKG_PATH_LOCAL" ]; then
            echo "❌ Local PKG not found: $PKG_PATH_LOCAL"
            exit 1
        fi
        echo "Installing local PKG: $PKG_PATH_LOCAL"
        installer -pkg "$PKG_PATH_LOCAL" -target /
        echo "✅ Package installed successfully."
        return 0
    fi

    local kind
    kind=$(artifact_type "$ARTIFACT_URL")
    if [ -z "$kind" ]; then
        echo "⚠️ Could not infer artifact type from URL ($ARTIFACT_URL); defaulting to DMG."
        kind="dmg"
    fi

    echo "Installing EvoMacLogin..."

    if [ "$kind" = "pkg" ]; then
        download_pkg
        echo "Installing $(basename "$PKG_TMP_PATH")..."
        installer -pkg "$PKG_TMP_PATH" -target /
        echo "✅ Package installed successfully."
        echo "🧹 Cleaning up temporary files..."
        rm -f "$PKG_TMP_PATH" || true
        echo "✅ Installation complete."
        return 0
    fi

    download_dmg
    mount_dmg

    PKG_PATH=$(find "$MOUNT_POINT" -type f -name "*.pkg" | head -n 1)
    if [ -f "$PKG_PATH" ]; then
        echo "Found PKG: $(basename "$PKG_PATH"). Installing..."
        installer -pkg "$PKG_PATH" -target /
        echo "✅ Package installed successfully."
    else
        echo "❌ No .pkg found in DMG."
        ls -la "$MOUNT_POINT"
    fi

    unmount_dmg

    echo "🧹 Cleaning up temporary files..."
    rm -f "$DMG_PATH" || true
    echo "✅ Installation complete."
}

is_agent_installed() {
    [ -d "$HELPER_APP" ] && return 0
    [ -d "$AGENT_APP" ] && return 0
    [ -f "$HELPER_DAEMON_PLIST" ] && return 0
    if command -v pkgutil >/dev/null 2>&1; then
        pkgutil --pkg-info "$EVO_PACKAGE_ID" >/dev/null 2>&1 && return 0
    fi
    return 1
}

builtin_uninstall() {
    echo "Running built-in cleanup (no on-disk uninstaller present)..."

    if [ -d "$EA_PLUGIN_PATH" ]; then
        rm -rf "$EA_PLUGIN_PATH" && echo "  removed $EA_PLUGIN_PATH" || echo "⚠️  could not remove $EA_PLUGIN_PATH"
    fi
    if [ -d "$LP_PLUGIN_PATH" ]; then
        rm -rf "$LP_PLUGIN_PATH" && echo "  removed $LP_PLUGIN_PATH" || echo "⚠️  could not remove $LP_PLUGIN_PATH"
    fi
    if [ -d "$LOGIN_CONFIGURATION_APP" ]; then
        rm -rf "$LOGIN_CONFIGURATION_APP" && echo "  removed $LOGIN_CONFIGURATION_APP" || echo "⚠️  could not remove $LOGIN_CONFIGURATION_APP"
    fi

    local console_user console_uid
    console_user=$(stat -f "%Su" /dev/console 2>/dev/null || true)
    console_uid=$(id -u "$console_user" 2>/dev/null || true)
    if [ -n "$console_user" ] && [ "$console_user" != "root" ] && \
       [ "$console_user" != "_mbsetupuser" ] && [ -n "$console_uid" ] && \
       [ -f "$AGENT_LAUNCHAGENT_PLIST" ]; then
        if launchctl print "gui/$console_uid" 2>/dev/null | grep -q "$AGENT_BUNDLE_ID"; then
            echo "  unloading EvoSecurityAgent for gui/$console_uid"
            launchctl bootout "gui/$console_uid" "$AGENT_LAUNCHAGENT_PLIST" 2>/dev/null || \
                echo "⚠️  bootout returned non-zero (may already be unloaded)"
        fi
    fi

    if [ -d "$AGENT_APP" ]; then
        rm -rf "$AGENT_APP" && echo "  removed $AGENT_APP" || echo "⚠️  could not remove $AGENT_APP"
    fi

    if launchctl list 2>/dev/null | grep -q "$HELPER_BUNDLE_ID"; then
        echo "  unloading helper daemon $HELPER_BUNDLE_ID"
        launchctl unload -w "$HELPER_DAEMON_PLIST" 2>/dev/null || \
            echo "⚠️  helper unload returned non-zero"
    fi

    if [ -x "$HELPER_EXEC" ]; then
        echo "  running helper -uninstall (restores authorization DB)"
        "$HELPER_EXEC" -uninstall || echo "⚠️  helper -uninstall returned non-zero"
    fi
    if [ -d "$HELPER_APP" ]; then
        rm -rf "$HELPER_APP" && echo "  removed $HELPER_APP" || echo "⚠️  could not remove $HELPER_APP"
    fi
    if [ -f "$HELPER_DAEMON_PLIST" ]; then
        rm -f "$HELPER_DAEMON_PLIST" && echo "  removed $HELPER_DAEMON_PLIST" || echo "⚠️  could not remove $HELPER_DAEMON_PLIST"
    fi

    if [ -d "$UNINSTALLER_APP_DIR" ]; then
        rm -rf "$UNINSTALLER_APP_DIR" && echo "  removed $UNINSTALLER_APP_DIR" || true
    fi
    rmdir "/Library/Application Support/Evo" 2>/dev/null || true

    if command -v pkgutil >/dev/null 2>&1; then
        if pkgutil --pkg-info "$EVO_PACKAGE_ID" >/dev/null 2>&1; then
            pkgutil --forget "$EVO_PACKAGE_ID" >/dev/null 2>&1 && \
                echo "  pkgutil --forget $EVO_PACKAGE_ID"
        fi
    fi
}

uninstall_app() {
    require_root

    if ! is_agent_installed; then
        echo "Nothing to uninstall: no Evo agent components found on this system."
        exit 0
    fi

    if [ -x "$UNINSTALLER_SCRIPT" ]; then
        echo "Running installed uninstaller: $UNINSTALLER_SCRIPT"
        "$UNINSTALLER_SCRIPT"
        echo "✅ Uninstall complete."
        return 0
    fi

    builtin_uninstall
    echo "✅ Uninstall complete."
}

# --- Argv ---

while [ $# -gt 0 ]; do
    case "$1" in
        --upgrade) DO_UPGRADE=true; shift ;;
        --beta) CHANNEL="beta"; shift ;;
        --uninstall|--remove) ACTION="uninstall"; shift ;;
        --install) ACTION="install"; shift ;;
        --deployment-token)
            DEPLOYMENT_TOKEN="${2:-}"
            [ -n "$DEPLOYMENT_TOKEN" ] || { echo "❌ --deployment-token requires a value"; exit 1; }
            shift 2 ;;
        --api-override-url)
            API_OVERRIDE_URL="${2:-}"
            [ -n "$API_OVERRIDE_URL" ] || { echo "❌ --api-override-url requires a value"; exit 1; }
            shift 2 ;;
        --environment|--env)
            DEPLOY_ENV="${2:-}"
            [ -n "$DEPLOY_ENV" ] || { echo "❌ --environment requires a value"; exit 1; }
            shift 2 ;;
        --pkg)
            PKG_PATH_LOCAL="${2:-}"
            [ -n "$PKG_PATH_LOCAL" ] || { echo "❌ --pkg requires a path"; exit 1; }
            shift 2 ;;
        --dmg|--artifact-url)
            ARTIFACT_URL="${2:-}"
            [ -n "$ARTIFACT_URL" ] || { echo "❌ --dmg requires a URL"; exit 1; }
            shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *)
            echo "❌ Unknown option: $1 (use --help)"
            exit 1
            ;;
    esac
done

echo "=== EvoMacLogin Script ==="
echo "Running as: $(whoami)"
echo "Mode: ${ACTION}"
echo "Channel: ${CHANNEL}"
echo "-------------------------------------"

case "$ACTION" in
    uninstall) uninstall_app ;;
    *) install_app ;;
esac
