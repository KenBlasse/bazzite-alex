FROM ghcr.io/ublue-os/bazzite:stable

# ---------------------------------------------------------------------------
# Bazzite Custom Image — Desktop Alex
#
# Ersetzt 18 gelayerte Pakete durch ein gebautes Image. Grund: Layering
# verlangsamt jedes Update (Paketauflösung on-device) und erzeugt beim
# Commit lokale Layer, die /var/tmp füllen.
#
# Bereinigt gegenüber der alten Layer-Liste:
#   docker, nodejs, npm, grub2-efi-modules  → waren gar nicht installiert.
#                                             node liefert `nodejs24` aus dem
#                                             Basisimage (/usr/bin/node-24);
#                                             als Paketmanager dient pnpm.
#                                             `npm` als Kommando fehlt dadurch
#                                             — bei Bedarf nachziehen.
#   ollama                                  → 941 MB tot; auf :11434 antwortet
#                                             der Podman-Container
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
    # kver überschreiben ist zwingend: im Container liefert `uname -r`
    # den Kernel des BAU-Hosts, nicht den des Images.
    make -C /tmp/nct6687d kver="${KVER}"; \
    \
    install -Dm644 "/tmp/nct6687d/${KVER}/nct6687.ko" \
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

# --- 4. Aufräumen ----------------------------------------------------------
RUN rm -rf /var/log/* /var/cache/* /tmp/* && \
    ostree container commit
