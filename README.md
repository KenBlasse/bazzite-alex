# bazzite-alex

Custom [Bazzite](https://bazzite.gg/)-Image für meinen Desktop (MSI MPG B550 Gaming Carbon, Ryzen 7 5800X3D, Radeon RX 7800 XT / gfx1101).

Ersetzt 18 gelayerte Pakete durch ein gebautes Image. Layering verlangsamt jedes Update durch Paketauflösung auf dem Gerät und erzeugt lokale Commit-Layer, die `/var/tmp` füllen.

## Was drin ist

| Baustein | Warum |
|---|---|
| **nct6687d** | Der Mainline-Treiber `nct6683` gibt auf MSI-Boards mit Nuvoton NCT6687-R nur Lesezugriff. Dieses Modul entsperrt alle 8 PWM-Kanäle. |
| **ROCm HIP-Devel** | `rocm-hip-devel` + `hipblas-devel` + `rocblas-devel`, damit llama.cpp nativ auf dem Host baut statt in einer Distrobox. |
| **Werkzeuge** | cmake, corectrl, coolercontrol, dialog, lazygit, libcurl-devel, liquidctl, nss-tools, pnpm, rocminfo |
| **npm** | `nodejs22-npm` — eigenständiges npm-Binary neben `nodejs24` (das kein npm mitbringt). Manche CLI-Installer rufen hart `npm`, nicht `pnpm` (z.B. Ollamas `ollama launch <tool>`). |

Bewusst *nicht* enthalten: `docker`, `grub2-efi-modules` (waren nie installiert), `warp-terminal`, `dpkg`, `git` (im Basisimage vorhanden).

`ollama` lief früher als Podman-Container, läuft seit 2026-09-02 nativ (`ollama.service`,
`/usr/local/bin/ollama`, Installer-Binary — kein RPM-Layer nötig, daher hier nicht gelistet).

## Nutzung

Einmalig auf das Remote-Image wechseln:

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/kenblasse/bazzite-alex:latest
sudo systemctl reboot
```

Danach ist Updaten wieder normal — `rpm-ostree upgrade`, oder Bazaar.

## Build

GitHub Actions baut wöchentlich (So 03:17 UTC) gegen das aktuelle `bazzite:stable`, bei jedem Push aufs Containerfile, und auf Zuruf per `workflow_dispatch`.

Vor dem Push verifiziert der Workflow das Image: `nct6687` muss von `depmod` auflösbar sein, `hipblas-config.cmake` vorhanden, die modprobe-Regeln am Platz. Ein Build, der durchläuft aber das Kernelmodul verloren hat, wird nicht veröffentlicht.

Images werden keyless mit [cosign](https://github.com/sigstore/cosign) signiert.

## Fallstricke

- **Der Kernel wird zur Bauzeit ermittelt**, nicht fest eingetragen — sonst bricht der Build bei jedem Kernel-Update von Bazzite. Beim `make` muss `kver=` überschrieben werden, weil `uname -r` im Container den Kernel des Bau-Hosts liefert.
- **`gcc-c++` ist für HIP zwingend**, obwohl hipcc ein eigenes clang mitbringt: clang findet die C++-Header nur über eine erkannte GCC-Toolchain.
- **Beim Linken gegen HIP `-lamdhip64` explizit setzen**, sonst `undefined symbol: hipGetDeviceCount`.
- **`hipblas-devel` ist nicht Teil von `rocm-hip-devel`.** Ohne es bricht `cmake -DGGML_HIP=ON` an `find_package(hipblas)` ab.
