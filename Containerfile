FROM ghcr.io/ublue-os/bazzite:stable

# ---------------------------------------------------------------------------
# Bazzite Custom Image — Desktop Alex
#
# Ersetzt 18 gelayerte Pakete durch ein gebautes Image. Grund: Layering
# verlangsamt jedes Update (Paketauflösung on-device) und erzeugt beim
# Commit lokale Layer, die /var/tmp füllen.
#
# Bereinigt gegenüber der alten Layer-Liste:
#   docker, grub2-efi-modules               → waren gar nicht installiert.
#   nodejs, npm                             → node liefert `nodejs24` aus dem
#                                             Basisimage (/usr/bin/node-24);
#                                             als Paketmanager dient pnpm.
#                                             `nodejs22-npm` unten liefert ein
#                                             eigenständiges npm-Binary dazu —
#                                             manche CLI-Installer (Ollamas
#                                             `ollama launch <tool>`) rufen
#                                             hart `npm`, nicht `pnpm`, auf.
#   ollama                                  → 941 MB tot; läuft seit
#                                             2026-09-02 nativ (ollama.service,
#                                             /usr/local/bin/ollama), nicht
#                                             mehr als Podman-Container.
#   warp-terminal, dpkg                     → nicht mehr benötigt
# ---------------------------------------------------------------------------

# --- 1. nct6687d: Lüftersteuerung ------------------------------------------
# Der Mainline-Treiber nct6683 bietet auf MSI-Boards mit Nuvoton NCT6687-R
# nur Lesezugriff (keine pwmN_enable). Dieses Modul gibt alle 8 Kanäle frei.
# Belegt am MPG B550 Gaming Carbon: pwm3 94→200 ergab 1175→2076 RPM.
#
# Die Kernel-Version wird zur Bauzeit ermittelt, nicht fest eingetragen —
# sonst bricht der Build bei jedem Kernel-Update von Bazzite.

RUN set -euxo pipefail; \
    KVER="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | head -1)"; \
    echo "Baue nct6687d gegen Kernel ${KVER}"; \
    \
    dnf install -y --setopt=install_weak_deps=False \
        gcc make git kernel-devel-"${KVER}"; \
    \
    git clone --depth 1 https://github.com/Fred78290/nct6687d.git /tmp/nct6687d; \
    # KVER überschreiben ist zwingend: im Container liefert `uname -r`
    # den Kernel des BAU-Hosts, nicht den des Images. Großschreibung ist
    # bindend — das Makefile kennt nur `KVER`, ein kleines `kver` wird
    # von Make stillschweigend ignoriert und fällt auf uname -r zurück.
    make -C /tmp/nct6687d KVER="${KVER}"; \
    \
    # Kbuild baut mit M=$(CURDIR) direkt ins Repo-Root, kein ${KVER}-Unterordner.
    install -Dm644 "/tmp/nct6687d/nct6687.ko" \
        "/usr/lib/modules/${KVER}/extra/nct6687.ko"; \
    depmod -a "${KVER}"; \
    \
    # Verifikation: Der Build gilt nur als erfolgreich, wenn depmod das
    # Modul auflösen kann. Sonst bricht der Image-Build hier ab, statt ein
    # kaputtes Image auszuliefern.
    modinfo -k "${KVER}" nct6687 >/dev/null; \
    \
    dnf remove -y gcc make git kernel-devel-"${KVER}"; \
    dnf clean all; \
    rm -rf /tmp/nct6687d

# nct6683 blockieren, nct6687 beim Boot laden.
# Reihenfolge zählt: Das Modul muss vor coolercontrold geladen sein, sonst
# inventarisiert der Daemon die PWMs als read-only und zeigt sie gesperrt.
RUN printf 'blacklist nct6683\n' > /usr/lib/modprobe.d/99-nct6687d.conf && \
    printf 'nct6687\n'           > /usr/lib/modules-load.d/99-nct6687d.conf

# --- 2. Die bisher gelayerten Pakete ---------------------------------------
# git ist im Basisimage vorhanden und steht hier bewusst nicht mehr drin.
#
# Zwei Pakete liegen nicht in den Standard-Repos:
#   coolercontrol → Terra (im Basisimage vorhanden, aber deaktiviert)
#   lazygit       → COPR dejan/lazygit (fehlt im Basisimage ganz)
# Ohne diese Repos bricht der Build mit "No match for argument" ab.

RUN dnf install -y --setopt=install_weak_deps=False \
        cmake \
        corectrl \
        dialog \
        libcurl-devel \
        liquidctl \
        nss-tools \
        pnpm \
        rocminfo \
    && dnf clean all

# coolercontrol aus Terra — Repo ist vorhanden, nur nicht aktiv.
# GPG-Key vorher importieren: sonst meldet dnf "Signing key not found" und
# installiert das Paket trotzdem — eine übergangene Signaturprüfung.
RUN rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-terra"$(rpm -E %fedora)" \
    && dnf install -y --enablerepo=terra --setopt=install_weak_deps=False \
        coolercontrol \
    && dnf clean all

# lazygit aus COPR. Das Repo wird nach der Installation wieder entfernt,
# damit es die Update-Auflösung des fertigen Images nicht belastet.
RUN dnf install -y dnf5-plugins \
    && dnf copr enable -y dejan/lazygit \
    && dnf install -y --setopt=install_weak_deps=False lazygit \
    && dnf copr disable -y dejan/lazygit \
    && dnf clean all

# --- 3. ROCm HIP-Entwicklung -----------------------------------------------
# Der Host hatte bisher nur die ROCm-Runtime, keine HIP-Header. Deshalb lief
# der llama.cpp-Build in der Distrobox `llama-rocm`, und die Binaries liefen
# ausschließlich dort. Mit HIP im Image entfällt dieser Umweg.

#
# gcc-c++ und libstdc++-devel sind zwingend, obwohl hipcc ein eigenes clang
# mitbringt: Der HIP-Wrapper zieht <cstdlib>, und clang findet die C++-Header
# nur über eine erkannte GCC-Toolchain. Ohne gcc-c++ bricht jede
# HIP-Kompilierung mit "'cstdlib' file not found" ab.
#
# Getestet im Image (gfx1101): kompiliert und linkt.
# Beim Linken muss `-lamdhip64` explizit gesetzt werden — hipcc fügt es hier
# nicht selbst hinzu, sonst: "undefined symbol: hipGetDeviceCount".
#
# hipblas-devel/rocblas-devel sind für llama.cpp zwingend und NICHT in
# rocm-hip-devel enthalten: mit HIP allein findet der HIP-Compiler zwar seine
# ABI, aber `cmake -DGGML_HIP=ON` bricht in ggml-hip/CMakeLists.txt an
# find_package(hipblas) ab ("Could not find hipblasConfig.cmake").
# Versionen müssen zur HIP-Version passen — Fedora 44 liefert beide als 7.1.x.
RUN dnf install -y --setopt=install_weak_deps=False \
        rocm-hip-devel \
        hipblas-devel \
        rocblas-devel \
        libstdc++-devel \
        gcc-c++ \
    && dnf clean all

# --- 4. npm -----------------------------------------------------------------
# node liefert nur `nodejs24` (/usr/bin/node-24), kein eigenständiges npm —
# als Paketmanager dient sonst pnpm. Manche CLI-Installer rufen aber hart
# `npm`, nicht `pnpm` (z.B. Ollamas `ollama launch <tool>`, das qwen/claude
# über einen npm-basierten Installer nachzieht). nodejs22-npm liefert ein
# eigenständiges npm-Binary dazu, ohne node24 als Standard zu verdrängen.
RUN dnf install -y --setopt=install_weak_deps=False \
        nodejs22-npm \
    && dnf clean all

# --- 4b. node24-full-i18n: Fix für den Qwen-Code-SIGSEGV -------------------
# Bazzite liefert nodejs24 als "small-icu"-Build ohne ICU-Laufzeitdaten.
# new Intl.Segmenter().segment() dereferenziert dort einen Null-Pointer in
# V8 (nativer SIGSEGV, nicht in JS abfangbar) — nodejs/node#51752, seit
# Feb 2024 offen, kein Upstream-Fix in Sicht. Qwen Code ruft genau das auf
# und crasht deshalb zuverlässig unter nodejs24.
#
# Ein Wechsel auf node22 behebt es NICHT zuverlässig (nur mit Wrapper
# getestet, nie sauber verifiziert) — siehe ~/.local/bin/qwen22, der als
# Workaround gilt aber nicht bestätigt fehlerfrei lief.
#
# Der eigentliche Fix ist eine Node-Variante mit vollen ICU-Daten statt
# eines Node-Versionswechsels: nodejs24-full-i18n liefert dasselbe
# /usr/bin/node-24-Binary, aber mit ICU-Daten zur Laufzeit → icu_small=false,
# Intl.Segmenter funktioniert ohne Crash. `dnf swap` statt `install`, weil
# beide Pakete dieselbe Datei installieren und sich sonst als Fileconflict
# gegenseitig blockieren.
RUN dnf swap -y --setopt=install_weak_deps=False \
        nodejs24 nodejs24-full-i18n \
    && dnf clean all

# --- 5. Aufräumen ----------------------------------------------------------
RUN rm -rf /var/log/* /var/cache/* /tmp/* && \
    ostree container commit
