# Evo Mac Deployment Scripts

This repository contains shell scripts to install, upgrade, or remove the **Evo macOS Agent** on Mac systems. It supports both **interactive** and **silent** operation modes, enabling easy integration into manual admin workflows or automated deployment systems (e.g., NinjaOne, Datto RMM, MDM, etc.).

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
- [Provisioning and environments](#provisioning-and-environments)
- [Verifying installation](#verifying-installation)
- [Notes](#notes)
- [Support](#support)
- [License](#license)

---

## Scripts in this repository

| Script | Use with |
|--------|----------|
| [`InstallEvoAgent.sh`](InstallEvoAgent.sh) | **NinjaOne**, manual installs, SSH — supports command-line flags and environment variables |
| [`InstallEvoAgentDatto.sh`](InstallEvoAgentDatto.sh) | **Datto RMM** — optimized for Datto component variables (no CLI arguments required) |

Download the latest raw scripts:

- Ninja / general: `https://raw.githubusercontent.com/evosecurity/EvoMacAgentDeploymentScripts/main/InstallEvoAgent.sh`
- Datto RMM: `https://raw.githubusercontent.com/evosecurity/EvoMacAgentDeploymentScripts/main/InstallEvoAgentDatto.sh`

---

## Script: InstallEvoAgent.sh (NinjaOne and general use)

### Features

- Installs the Evo macOS Agent from the official Evo download catalog (release or beta channel)
- Automatically downloads the latest PKG from `https://download.evosecurity.com`
- SHA-256 verification of downloaded artifacts
- Supports local `.pkg` or `.dmg` files via `--pkg`
- Supports explicit download URLs via `--dmg`
- Deployment token provisioning (preferred since agent 2.5)
- API hostname override for staging / lab environments
- Upgrade-safe: `--upgrade` installs only when the catalog version is newer than what is installed
- Uninstall / remove support
- Environment variable equivalents for RMM custom fields (NinjaOne friendly)
- Integrated `--help`

Artifacts are resolved from:

`https://download.evosecurity.com/{release|beta}/macos/evo-login-plugin-macos-latest-info.json`

---

### Command-line options

| Option | Description |
|--------|-------------|
| *(none)* | Install latest agent from the release catalog |
| `--upgrade` | Install only if catalog version is newer than the installed version |
| `--beta` | Use the beta release channel |
| `--deployment-token TKN` | Deployment token from the Evo Admin portal (preferred since agent 2.5) |
| `--environment ENV` / `--env ENV` | Target environment: `production`, `staging`, or `local` (default: `production`) |
| `--api-override-url URL` | Override Evo API hostname (staging / Proxmox lab) |
| `--pkg PATH` | Install a local `.pkg` or `.dmg` file; skips catalog download |
| `--dmg URL` | Download and install from an explicit DMG or PKG URL |
| `--uninstall` / `--remove` | Uninstall the Evo macOS Agent |
| `--help` | Show usage |

`--deployment-token` is the only required option for a new install (except on upgrade or removal).

When upgrading, existing agent configuration is retained unless overridden.

---

### Environment variables

These mirror the command-line options and are useful with NinjaOne custom fields:

| Variable | Description | CLI equivalent |
|----------|-------------|----------------|
| `EVO_DEPLOYMENT_TOKEN` | Deployment token from portal | `--deployment-token` |
| `EVO_OVERRIDE_API_HOSTNAME` | API hostname override | `--api-override-url` |
| `EVO_DEPLOY_ENV` / `EVO_ENV` | `production`, `staging`, or `local` | `--environment` |

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
export EVO_OVERRIDE_API_HOSTNAME="$evoApiOverride"
sudo -E /tmp/InstallEvoAgent.sh --upgrade
```

#### Upgrade with logging context (stdout goes to Ninja job output)

```bash
sudo ./InstallEvoAgent.sh --upgrade
```

#### Staging / Proxmox lab

```bash
sudo ./InstallEvoAgent.sh \
  --deployment-token "deptoken123abc" \
  --environment local \
  --api-override-url evo.evosecurity.local
```

Lab Macs often also need a hosts entry:

```bash
echo "10.0.0.42  evo.evosecurity.local" | sudo tee -a /etc/hosts
```

#### Install from a local PKG

```bash
sudo ./InstallEvoAgent.sh --deployment-token "deptoken123abc" --pkg /tmp/evomacagent.pkg
```

#### Uninstall

```bash
sudo ./InstallEvoAgent.sh --uninstall
```

---

## Script: InstallEvoAgentDatto.sh (Datto RMM)

Datto RMM runs component scripts as **root** with **component variables** injected as environment variables. Datto does not reliably pass command-line arguments, so use `InstallEvoAgentDatto.sh` and configure variables in the Datto component UI.

This script includes everything in `InstallEvoAgent.sh`, plus:

- Datto-specific environment variables (`EVO_UPGRADE_NOW`, `EVO_REMOVE_NOW`, `EVO_PKG_PATH`)
- Plain-text output (no icon glyphs that can break Datto parsing)
- Catalog JSON parsing without Python / Xcode Command Line Tools (`plutil` with fallback)
- Post-install deployment token enrollment verification
- Local `.dmg` support via `EVO_PKG_PATH`

### Datto component variables

Create these on the **Install Evo Agent [MAC]** component:

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `EVO_DEPLOYMENT_TOKEN` | String | *(empty)* | Deployment token from Evo Admin |
| `EVO_UPGRADE_NOW` | Boolean | `False` | Upgrade only if catalog version is newer |
| `EVO_REMOVE_NOW` | Boolean | `False` | Uninstall the agent |
| `EVO_DEPLOY_ENV` | String | *(empty → production)* | `production`, `staging`, or `local` |
| `EVO_OVERRIDE_API_HOSTNAME` | String | *(empty)* | API hostname override for lab/staging |
| `EVO_PKG_PATH` | String | *(empty)* | Optional local `.pkg` or `.dmg` path (skips catalog download) |

For a normal install, set `EVO_DEPLOYMENT_TOKEN` and leave `EVO_UPGRADE_NOW` and `EVO_REMOVE_NOW` as `False`.

For upgrade: set `EVO_UPGRADE_NOW` = `True`.

For uninstall: set `EVO_REMOVE_NOW` = `True`.

There is no separate "use deployment token" flag. If `EVO_DEPLOYMENT_TOKEN` is set, the script uses it automatically.

### Datto example component script

Copy the contents of `InstallEvoAgentDatto.sh` into the component script window, then use a minimal runner:

```bash
#!/bin/bash
sudo -E /path/to/InstallEvoAgentDatto.sh
```

`-E` preserves `EVO_*` variables when dropping to root.

#### Lab install with a local DMG (testing)

Place the DMG on the Mac first (e.g. `/tmp/EvoMacAgent-2.0.7-1.dmg`), then set:

| Variable | Value |
|----------|--------|
| `EVO_DEPLOYMENT_TOKEN` | your token |
| `EVO_DEPLOY_ENV` | `staging` or `local` |
| `EVO_PKG_PATH` | `/tmp/EvoMacAgent-2.0.7-1.dmg` |

---

## Provisioning and environments

| Environment | Set via | API used during enrollment |
|-------------|---------|----------------------------|
| Production (default) | `EVO_DEPLOY_ENV=production` or omit | `https://api.evosecurity.com` |
| Staging | `EVO_DEPLOY_ENV=staging` | `https://staging.evosecurity.com` |
| Local / Proxmox lab | `EVO_DEPLOY_ENV=local` | `http://evo.evosecurity.local:5500` |

When using Evo Admin **RMM deployments**, ensure the deployment token scope matches the environment you pass to the script. A Development-scope token enrolled with `production` will fail silently or appear as "token didn't work."

---

## Verifying installation

After install, on the Mac:

```bash
HELPER="/Library/PrivilegedHelperTools/com.evosecurity.EvoMacAgent.Helper.app/Contents/MacOS/Helper"
sudo "$HELPER" -is-enrolled && echo "Enrolled" || echo "Not enrolled"
grep -E "is-deployment-token|evoEnv|evoDir" /Users/Shared/evo-config.json
```

Deployment token enrollment logs during PKG install:

```bash
sudo grep -iE "deployment token|evo-seed" /var/log/install.log | tail -30
```

The raw deployment token is **not** stored on disk after successful enrollment. The agent uses Ed25519 keys in the keychain and `evo-config.json` instead.

---

## Notes

- **Root / admin required**: Scripts must run as root (`sudo`). RMM tools (NinjaOne, Datto) already execute as root.
- **Logout may be required**: macOS may report *"The install requires logging out now"* after installing login-window components. Plan for a logout or reboot.
- **No Xcode CLT required**: `InstallEvoAgentDatto.sh` does not depend on Python or Xcode Command Line Tools for catalog parsing.
- **Catalog vs local artifact**: By default, scripts download from the official Evo CDN. Use `--pkg` / `EVO_PKG_PATH` only for lab builds or when testing unreleased versions.
- **Datto StdOut**: Datto does not stream script output live. StdOut appears in the Activity Log after the job completes.
- **Component timeout**: Set a reasonable timeout on Datto components; enrollment API calls can take time on slow networks.

---

## Support

Please contact [support@evosecurity.com](mailto:support@evosecurity.com) for assistance.

---

## License

Copyright © Evo Security Technologies. All rights reserved.
