# RustDesk Build

Custom build scripts and patches for [RustDesk](https://rustdesk.com/) — an open-source remote desktop application written in Rust. Supports both Linux (Arch/makepkg) and Android (aarch64/armv7/x86_64) targets, with hardware codec (H.264/H.265) support via vcpkg + FFmpeg.

## Contents

| File | Purpose |
|------|---------|
| `PKGBUILD` | Arch Linux package build definition |
| `build.sh` | Standalone Linux build script (no makepkg required) |
| `build-android.sh` | Android APK build script |
| `server/docker-compose.yml` | Self-hosted server stack (hbbs + hbbr behind Tailscale) |
| `0000-disable-update-check@rustdesk.patch` | Disables the built-in update nag |
| `0002-screen_retriever@rustdesk.patch` | Screen retriever compatibility fix |
| `0003-mkvparser.cc-cstdint.patch` | C++17 `<cstdint>` include fix for mkvparser |
| `0005-bindgen-clang22@rustdesk.patch` | bindgen compatibility fix for Clang 22 |

## Current version

**RustDesk 1.4.7** — Flutter 3.24.5 · flutter\_rust\_bridge 1.80.1 · vcpkg `120deac3`

## Linux build

### Prerequisites

```
pacman -S --needed git cmake gcc curl wget yasm nasm zip make pkg-config clang \
    rust python python-yaml python-toml ninja patchelf \
    ffnvcodec-headers amf-headers
```

### Build with makepkg

```bash
makepkg -si
```

### Build without makepkg (standalone)

Downloads all sources automatically:

```bash
bash build.sh
```

The packaged bundle lands in `pkg/usr/lib/rustdesk/`.

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

```bash
cd server
TS_AUTHKEY=<your-tailscale-auth-key> docker compose up -d
```

Set the RustDesk client's ID/relay server to the Tailscale hostname (default: `rustdesk`).

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
