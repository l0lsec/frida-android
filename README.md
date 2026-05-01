# frida-android

Manage `frida-server` on a rooted Android device/emulator via ADB.

Automatically downloads the `frida-server` build that matches the host's installed `frida` CLI version, pushes it to the device, and starts it as root. Also exposes status, stop, restart, and uninstall commands.

## Usage

```
./frida_android.sh <command>
```

| Command     | Description |
|-------------|-------------|
| `start`     | Ensure frida-server is installed at the matching version and launch it (aliases: `on`, `up`) |
| `stop`      | Kill `frida-server` on the device (aliases: `off`, `down`) |
| `restart`   | Stop, then start |
| `status`    | Show device/host versions, running pid, port, connectivity (alias: `st`) |
| `install`   | Download + push `frida-server`, do not start |
| `uninstall` | Stop and remove the on-device binary |

## Environment

| Variable          | Default                              | Description |
|-------------------|--------------------------------------|-------------|
| `FRIDA_VERSION`   | host `frida --version`, then latest  | Force a specific frida-server version |
| `FRIDA_PORT`      | `27042`                              | Listen port for frida-server |
| `FRIDA_REMOTE`    | `/data/local/tmp/frida-server`       | On-device install path |
| `FRIDA_CACHE_DIR` | `$HOME/.cache/frida-android-server`  | Host cache directory for downloaded binaries |

## Requirements

- `adb` in PATH with a connected device/emulator
- Rooted Android device with `su` available (Magisk, userdebug, etc.)
- `curl` and `xz` on the host
- `python3` on the host (only needed when falling back to GitHub for the latest version)
- `frida` / `frida-tools` on the host (recommended) so versions match automatically and `status` can verify connectivity

## Version resolution

1. `FRIDA_VERSION` env var if set
2. Output of `frida --version` (host CLI)
3. Latest GitHub release tag from `https://api.github.com/repos/frida/frida/releases/latest`

Downloaded binaries are cached, so subsequent runs are offline as long as the version doesn't change.

## Examples

```bash
# First run: downloads matching frida-server, pushes, and starts it
./frida_android.sh start

# Confirm everything is up
./frida_android.sh status

# Talk to it from the host
frida-ps -U

# Pin a specific version
FRIDA_VERSION=16.7.11 ./frida_android.sh restart

# Use a non-default port
FRIDA_PORT=27045 ./frida_android.sh start

# Tear down completely
./frida_android.sh uninstall
```

## Optional: put it on your PATH

```bash
ln -s "$PWD/frida_android.sh" ~/bin/frida_android
```
