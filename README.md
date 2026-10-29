# Evo Mac Deployment Scripts

This repository contains shell scripts to install, upgrade, or remove the **Evo macOS Agent** on Mac systems. It supports both **interactive** and **silent** operation modes, enabling easy integration into manual admin workflows or automated deployment systems (e.g., NinjaOne, Datto RMM, MDM, etc.).

The scripts follow the same steps and safety checks as the manual PKG installer and the agent's own uninstaller, so a scripted install or removal leaves a Mac in the same state as a manual one.

The Windows equivalent lives in [EvoWindowsAgentDeploymentScripts](https://github.com/evosecurity/EvoWindowsAgentDeploymentScripts).

---

## Table of Contents

- [Scripts in this repository](#scripts-in-this-repository)
- [Script: InstallEvoAgent.sh (NinjaOne and general use)](#script-installevoagentsh-ninjaone-and-general-use)
  - [Features](#features)
  - [Command-line options](#command-line-options)
  - [Environment variables](#environment-variables)
  - [Example usages](#example-usages)
- [Script: InstallEvoAgentDatto.sh (Datto RMM)](#script-installevoagentdattosh-datto-rmm)
  - [Datto component variables](#datto-component-variables)
  - [Datto example component script](#datto-example-component-script)
- [Provisioning](#provisioning)
- [SecureToken granting](#securetoken-granting)
- [Upgrades and local packages](#upgrades-and-local-packages)
- [Uninstall](#uninstall)
- [Exit codes](#exit-codes)
- [Verifying installation](#verifying-installation)
- [Testing locally](#testing-locally)
- [Notes](#notes)
- [Support](#support)
- [License](#license)

---

## Scripts in this repository

| Script | Use with |
|--------|----------|
| [`InstallEvoAgent.sh`](InstallEvoAgent.sh) | **NinjaOne**, manual installs, SSH — supports command-line flags and environment variables |
| [`InstallEvoAgentDatto.sh`](InstallEvoAgentDatto.sh) | **Datto RMM** — optimized for Datto component variables (no CLI arguments required) |

Both scripts share the same logic; they differ only in how they are driven (flags vs. component variables) and in output style.

Download the latest raw scripts:

- Ninja / general: `https://raw.githubusercontent.com/evosecurity/EvoMacAgentDeploymentScripts/main/InstallEvoAgent.sh`
- Datto RMM: `https://raw.githubusercontent.com/evosecurity/EvoMacAgentDeploymentScripts/main/InstallEvoAgentDatto.sh`

---

## Script: InstallEvoAgent.sh (NinjaOne and general use)

### Features

- Installs the Evo macOS Agent `.pkg` from the official Evo download catalog (release or beta channel)
- SHA-256 verification of downloaded packages
- Local `.pkg` files via `--pkg`, explicit package URLs via `--pkg-url`
- Deployment token provisioning (preferred since agent 2.5); an already-applied token is not re-sent, a new token re-enrolls
- Grants a SecureToken after install when admin credentials are provided
- Upgrade-safe: `--upgrade` installs only when the available version is newer than what is installed (catalog or local `.pkg`)
- Pre-flight checks that stop before anything is changed when an install cannot succeed
- Uninstall with the same safety checks as the agent's own uninstaller
- Distinct exit codes for every failure type, so RMM policies can react to them
- Environment variable equivalents for RMM custom fields (NinjaOne friendly)
- Integrated `--help`

Packages are resolved from:

`https://download.evosecurity.com/{release|beta}/macos/evo-login-plugin-macos-latest-info.json`

---

### Command-line options

| Option | Description |
|--------|-------------|
| *(none)* | Install the latest agent from the release catalog |
| `--upgrade` | Install only if the available version is newer than the installed version |
| `--beta` | Use the beta release channel |
| `--deployment-token TKN` | Deployment token from the Evo Admin portal (preferred since agent 2.5) |
| `--pkg PATH` | Install a local `.pkg` file; skips the catalog download |
| `--pkg-url URL` | Download and install from an explicit `.pkg` URL instead of the catalog (aliases: `--artifact-url`, `--dmg`) |
| `--securetoken-only` | Only grant a SecureToken on an already-installed agent (see [SecureToken](#securetoken-granting)) |
| `--uninstall` / `--remove` | Uninstall the Evo macOS Agent |
| `--help` | Show usage |

A new install needs something to provision the agent from: a deployment token, an existing `/Users/Shared/evo-config.json`, or MDM-managed `com.evosecurity.EvoLogin` preferences. If none is present, the script stops before installing anything (exit code 2), because the package would otherwise fail its fail-safe user check.

When upgrading without a token, the existing agent configuration is kept.

> **Legacy `.dmg` packages:** releases ship as a flat `.pkg`. A `.dmg` passed to `--pkg` / `--pkg-url` (or listed in the catalog) is still accepted — the `.pkg` inside it is installed — but this path is deprecated.

---

### Environment variables

These mirror the command-line options and are useful with NinjaOne custom fields:

| Variable | Description | CLI equivalent |
|----------|-------------|----------------|
| `EVO_DEPLOYMENT_TOKEN` | Deployment token from portal | `--deployment-token` |
| `ADMIN_USERNAME` | Existing admin that already holds a SecureToken | *(environment only)* |
| `ADMIN_PASSWORD` | That admin's password | *(environment only)* |
| `EVO_SECURETOKEN_WAIT_SECONDS` | How long to wait for the agent to be provisioned before the SecureToken grant gives up (default: `180`) | *(environment only)* |

`ADMIN_USERNAME` / `ADMIN_PASSWORD` deliberately have no command-line flags, so the password never appears in process listings or shell history.

---

### Example usages

#### Install with deployment token (preferred with agent 2.5+)

```bash
sudo ./InstallEvoAgent.sh --deployment-token "deptoken123abc"
```

#### Install with NinjaOne custom fields

Map Ninja custom fields to environment variables, then run with `-E` so variables survive `sudo`:

```bash
#!/bin/bash
export EVO_DEPLOYMENT_TOKEN="$evoDeploymentToken"
export ADMIN_USERNAME="$evoSecureTokenAdmin"          # optional, see SecureToken section
export ADMIN_PASSWORD="$evoSecureTokenAdminPassword"  # optional, use a secure/secret field
sudo -E /tmp/InstallEvoAgent.sh --upgrade
```

#### Upgrade (stdout goes to Ninja job output)

```bash
sudo ./InstallEvoAgent.sh --upgrade
```

#### Install from a local PKG

```bash
sudo ./InstallEvoAgent.sh --deployment-token "deptoken123abc" --pkg /tmp/EvoMacAgent-2.1.7.9.pkg
```

#### Grant a SecureToken on an installed agent

```bash
read -rs ADMIN_PASSWORD; export ADMIN_PASSWORD ADMIN_USERNAME=localadmin
sudo -E ./InstallEvoAgent.sh --securetoken-only
```

#### Uninstall

```bash
sudo ./InstallEvoAgent.sh --uninstall
```

---

## Script: InstallEvoAgentDatto.sh (Datto RMM)

Datto RMM runs component scripts as **root** with **component variables** injected as environment variables. Datto does not reliably pass command-line arguments, so use `InstallEvoAgentDatto.sh` and configure variables in the Datto component UI.

This script includes everything in `InstallEvoAgent.sh`, plus:

- Datto-specific environment variables (`EVO_UPGRADE_NOW`, `EVO_REMOVE_NOW`, `EVO_SECURETOKEN_NOW`, `EVO_PKG_PATH`)
- Plain-text output (no icon glyphs that can break Datto parsing)
- Trimming of stray whitespace Datto sometimes adds to variable values
- Catalog JSON parsing without Python / Xcode Command Line Tools (`plutil` with fallback)

### Datto component variables

Create these on the **Install Evo Agent [MAC]** component:

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `EVO_DEPLOYMENT_TOKEN` | String | *(empty)* | Deployment token from Evo Admin |
| `EVO_UPGRADE_NOW` | Boolean | `False` | Upgrade only if the available version is newer |
| `EVO_REMOVE_NOW` | Boolean | `False` | Uninstall the agent |
| `EVO_SECURETOKEN_NOW` | Boolean | `False` | Only grant a SecureToken on an installed agent |
| `EVO_PKG_PATH` | String | *(empty)* | Optional local `.pkg` path (skips catalog download) |
| `ADMIN_USERNAME` | String | *(empty)* | Existing SecureToken-holding admin (optional) |
| `ADMIN_PASSWORD` | String | *(empty)* | That admin's password (optional; store it as securely as Datto allows) |
| `EVO_SECURETOKEN_WAIT_SECONDS` | String | `180` | Wait for hidden-admin provisioning before the grant gives up |

For a normal install, set `EVO_DEPLOYMENT_TOKEN` and leave the `*_NOW` variables as `False`.

For upgrade: set `EVO_UPGRADE_NOW` = `True`.

For uninstall: set `EVO_REMOVE_NOW` = `True`.

For a SecureToken grant on an installed agent: set `ADMIN_USERNAME`, `ADMIN_PASSWORD` and `EVO_SECURETOKEN_NOW` = `True`.

There is no separate "use deployment token" flag. If `EVO_DEPLOYMENT_TOKEN` is set, the script uses it automatically.

### Datto example component script

Copy the contents of `InstallEvoAgentDatto.sh` into the component script window, then use a minimal runner:

```bash
#!/bin/bash
sudo -E /path/to/InstallEvoAgentDatto.sh
```

`-E` preserves `EVO_*` and `ADMIN_*` variables when dropping to root.

#### Install from a local PKG

Place the package on the Mac first (e.g. `/tmp/EvoMacAgent-2.1.7.9.pkg`), then set:

| Variable | Value |
|----------|--------|
| `EVO_DEPLOYMENT_TOKEN` | your token |
| `EVO_PKG_PATH` | `/tmp/EvoMacAgent-2.1.7.9.pkg` |

---

## Provisioning

**Re-running with the same token.** After a successful enrollment the script records a fingerprint (SHA-256) of the token in `/var/root/.evo/`. If a later run uses the same token while the agent is still enrolled and its configuration is intact, the token is not re-sent and the existing enrollment is kept. A different token re-enrolls the agent. The first run after updating to this script version re-enrolls once, because no fingerprint exists yet.

---

## SecureToken granting

When `ADMIN_USERNAME` and `ADMIN_PASSWORD` are both set, the script grants a SecureToken after a successful install, using the agent's `bootstrapSecureToken.sh`. The admin must be an existing local administrator that already holds a SecureToken.

- **Both or neither.** Setting only one of the two variables stops the script before anything is installed (exit code 2).
- **Waiting for the hidden admin.** The agent creates `_evoAdmin` shortly after it starts. Until it exists the grant is retried every 10 seconds, for up to `EVO_SECURETOKEN_WAIT_SECONDS` (default 180).
- **The daemon waits for the script.** Before installing, the script leaves a short-lived marker (`/Library/Application Support/Evo/.securetoken-deferred`) telling the agent that the deployment will grant the SecureToken, so the agent does not request one itself. The marker is removed as soon as the grant finishes, and expires on its own if the script is interrupted, after which the agent falls back to its normal behavior.
- **Failures fail the job.** A failed grant exits with a code from 12–19 (see [Exit codes](#exit-codes)). The agent itself stays installed; fix the cause and re-run with `--securetoken-only` / `EVO_SECURETOKEN_NOW=true`.
- **Credential handling.** The password is passed only through the environment of the grant step, is never written to disk or logged, and is removed from the script's environment afterwards.

Check the result on the Mac:

```bash
sysadminctl -secureTokenStatus _evoAdmin
```

---

## Upgrades and local packages

`--upgrade` / `EVO_UPGRADE_NOW=True` compares the installed agent version with the version that would be installed, and skips the install (exit code 0) when the installed version is the same or newer.

- **Catalog installs** use the version from the catalog.
- **Local packages** (`--pkg` / `EVO_PKG_PATH`) take the version from the file name, which must follow the `Agent-<version>.pkg` convention, e.g. `Agent-2.6.1.4.pkg` → `2.6.1.4`. Suffixes such as `-beta` or a Finder copy suffix ` (1)` are ignored. If the name contains no version, the package is installed without a version check.
- **Explicit URLs** (`--pkg-url`) have no known version and are always installed.

**Failed upgrades are rolled back.** If the package fails during an upgrade (for example because of an invalid token or a missing fail-safe user), it restores the previous installation and leaves it running; the script reports this with exit code 5 and prints the end of the installer log.

---

## Uninstall

`--uninstall` / `EVO_REMOVE_NOW=True` runs the agent's own uninstaller when it is present. If it is missing, fails, or leaves components behind, the script runs a built-in uninstall with the same steps as a second pass:

1. Unloads the agent for every logged-in user and stops the Helper daemon.
2. Has the Helper restore the login authorization rules (and removes PAM integration, scripts and the hidden admin). Without a working Helper, the `authenticate` and `system.login.console` rules are reset directly — but only when they still reference Evo, so other vendors' login components are left untouched.
3. **Refuses to delete the login plugins while the authorization rules still reference them**, because that would leave the Mac unable to log in. The manual recovery commands are printed instead.
4. Removes the plugins, apps, Helper, LaunchDaemon/LaunchAgent plists, the `_evoAdmin` account and `evo-config.json`.
5. Removes the files the deployment scripts themselves created (token fingerprint, SecureToken marker) and the package receipt.
6. Verifies that nothing is left and lists any remaining components (exit code 7).

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success, or nothing to do (already up to date, nothing to uninstall) |
| `1` | Usage error or not run as root |
| `2` | Pre-flight check failed — nothing was changed |
| `3` | Catalog, download, checksum or package problem — nothing was changed |
| `4` | Fresh install failed; the package removed its partial install |
| `5` | Upgrade failed; the package restored the previous installation |
| `6` | Installed, but deployment-token enrollment could not be confirmed |
| `7` | Uninstall finished with errors; manual cleanup may be required |
| `12` | SecureToken: the agent reports `ADMIN_USERNAME` / `ADMIN_PASSWORD` missing |
| `13` | SecureToken: the hidden admin was not provisioned within the wait time |
| `14` | SecureToken: `ADMIN_USERNAME` does not hold a SecureToken |
| `15` | SecureToken: grant failed (wrong password, etc.) |
| `19` | SecureToken: any other failure |

---

## Verifying installation

After install, on the Mac:

```bash
HELPER="/Library/PrivilegedHelperTools/com.evosecurity.EvoMacAgent.Helper.app/Contents/MacOS/Helper"
sudo "$HELPER" -is-enrolled && echo "Enrolled" || echo "Not enrolled"
grep -E "is-deployment-token|evoEnv|evoDir" /Users/Shared/evo-config.json
pkgutil --pkg-info com.evosecurity.EvoLogin
```

Installer logs:

```bash
cat ~/.evo/install.log                 # package pre/postinstall log (console user; /var/root/.evo/install.log if nobody was logged in)
sudo grep -i evo /var/log/install.log | tail -30
```

When an install fails, the script prints the end of the package log in its own output, so the reason is visible in the RMM job log.

The raw deployment token is **not** stored on disk. The script passes it to the package in a temporary file that is deleted when the script exits, whether the install succeeded or not; the agent uses Ed25519 keys in the keychain and `evo-config.json` instead. Confirm nothing is left behind:

```bash
ls /private/tmp/evo-seed.json /tmp/evo-deployment-token.txt 2>/dev/null || echo "No token files left"
```
---

## Notes

- **Root / admin required**: Scripts must run as root (`sudo`). RMM tools (NinjaOne, Datto) already execute as root.
- **Logout may be required**: macOS may report *"The install requires logging out now"* after installing login-window components. Plan for a logout or reboot.
- **No Xcode CLT required**: The scripts do not depend on Python or Xcode Command Line Tools.
- **Catalog vs local package**: By default, scripts download from the official Evo CDN. Use `--pkg` / `EVO_PKG_PATH` only when testing unreleased versions. Unsigned local builds install with a warning; release packages should show a Developer ID signature.
- **Datto StdOut**: Datto does not stream script output live. StdOut appears in the Activity Log after the job completes.
- **Component timeout**: Set a reasonable timeout on RMM jobs. Enrollment API calls can take time on slow networks, and a SecureToken grant may wait up to `EVO_SECURETOKEN_WAIT_SECONDS` for the hidden admin.

---

## Support

Please contact [support@evosecurity.com](mailto:support@evosecurity.com) for assistance.

---

## License

Copyright © Evo Security Technologies. All rights reserved.
