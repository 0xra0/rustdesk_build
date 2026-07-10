# RustDesk Build

Custom build scripts and patches for [RustDesk](https://rustdesk.com/) — an open-source remote desktop application written in Rust. Supports Linux (x86_64) and Android (aarch64/armv7/x86_64) targets, with hardware codec (H.264/H.265) support via vcpkg + FFmpeg.

## Contents

| File | Purpose |
|------|---------|
| `build.sh` | Linux build script |
| `build-android.sh` | Android APK build script |
| `server/docker-compose.yml` | Self-hosted server stack (hbbs + hbbr behind Tailscale) |
| `server/.env.example` | Template for the server's `.env` |
| `server/id_ed25519.pub` | Server public key, used as the client's **Key** field |
| `0000-disable-update-check@rustdesk.patch` | Disables the built-in update nag |
| `0002-screen_retriever@rustdesk.patch` | Screen retriever compatibility fix |
| `0003-mkvparser.cc-cstdint.patch` | C++17 `<cstdint>` include fix for mkvparser |
| `0005-bindgen-clang22@rustdesk.patch` | bindgen compatibility fix for Clang 22 |

## Current version

**RustDesk 1.4.8** — Flutter 3.24.5 · flutter\_rust\_bridge 1.80.1 · vcpkg `120deac3`

## Download

Prebuilt artifacts are attached to the [latest release](https://github.com/0xra0/rustdesk_build/releases/latest):

| Asset | Target |
|-------|--------|
| `rustdesk-1.4.8-x86_64.zip` | Linux x86_64 |
| `rustdesk-1.4.8-aarch64.apk` | Android aarch64 |

The Linux zip contains a `usr/` tree and its `usr/bin/rustdesk` is an absolute symlink, so it must be extracted at the filesystem root:

```bash
sudo unzip -o rustdesk-1.4.8-x86_64.zip -d /
```

To run RustDesk as a background service:

```bash
sudo systemctl enable --now rustdesk
```

## Linux build

### Prerequisites

Dependencies are listed as Arch package names; translate them for other distributions.

```
pacman -S --needed git cmake gcc curl wget yasm nasm zip make pkg-config clang \
    rust python python-yaml python-toml ninja patchelf \
    ffnvcodec-headers amf-headers
```

### Build

`build.sh` downloads all sources automatically:

```bash
bash build.sh
```

The packaged bundle lands in `pkg/`, laid out as a `usr/` tree matching the release zip.

## Android build

Requires Android SDK, NDK r28c, JDK 17, Flutter 3.24.5, and Rust (via rustup).
Run the Linux `build.sh` first (or at least its prepare step) so the source tree is in place.

```bash
# default aarch64
bash build-android.sh

# specific ABI
bash build-android.sh armv7

# all ABIs
bash build-android.sh all
```

APKs are written to the script directory.

## Self-hosted server

The `server/` directory contains a Docker Compose stack that runs the RustDesk relay and rendezvous server behind [Tailscale](https://tailscale.com/), so no public ports need to be exposed.

Copy the environment template and fill in a [Tailscale auth key](https://login.tailscale.com/admin/settings/keys):

```bash
cd server
cp .env.example .env
$EDITOR .env
docker compose up -d
```

Then, in the RustDesk client:

- Set **ID/Relay Server** to the Tailscale hostname (`TS_HOSTNAME`, default `rustdesk`).
- Set **Key** to the contents of `server/id_ed25519.pub` — `hbbs` runs with `-k _`, so clients that don't present the key are rejected.

## Hardware codecs (H.264 / H.265)

The build includes `--hwcodec` and links vcpkg-built FFmpeg. Install a matching VA-API driver for your hardware:

| Hardware | Package |
|----------|---------|
| Intel (Broadwell+) | `intel-media-driver` |
| Intel (Haswell and older) | `libva-intel-driver` |
| AMD / NVIDIA | `libva-mesa-driver` |

Use `vainfo` (from `libva-utils`) to verify codec support before expecting hardware acceleration.

## License

RustDesk upstream is [AGPL-3.0](https://github.com/rustdesk/rustdesk/blob/master/LICENCE). The build scripts and patches in this repository are provided as-is with no additional restrictions.
