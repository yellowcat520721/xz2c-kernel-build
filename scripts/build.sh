#!/bin/bash
# ==============================================================================
# Build a KernelSU-Next (legacy / manual-hook) kernel for the Sony Xperia XZ2
# Compact (apollo, SDM845, kernel 4.9.337) and package it as an AnyKernel3 zip.
#
# Runs on Linux (GitHub Actions ubuntu-22.04 or any Debian-ish box).
# Everything it needs besides this repo: network access to github.com and
# android.googlesource.com.
#
# Inputs (env):
#   KERNEL_REPO   kernel source (default upstream aoitsme/android_kernel_sony_sdm845)
#   KERNEL_REF    branch/tag/commit (default bpf)
#   KSU_REF       KernelSU-Next ref       (default legacy)
#   CLANG_VERSION AOSP clang prebuilt     (default clang-r547379)
#   DEFCONFIG     defconfig name          (default tama_apollo_defconfig)
#   MAKE_JOBS     parallel jobs           (default nproc)
# ==============================================================================
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://github.com/aoitsme/android_kernel_sony_sdm845.git}"
KERNEL_REF="${KERNEL_REF:-bpf}"
KSU_REF="${KSU_REF:-legacy}"
CLANG_VERSION="${CLANG_VERSION:-clang-r547379}"
DEFCONFIG="${DEFCONFIG:-tama_apollo_defconfig}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

# 4.9 kernels are happiest with 4.9-era binutils; the compiler is a modern AOSP clang
GCC_NAME="aarch64-linux-android-4.9"
GCC_REF="master"
CLANG_BASE="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main"
GCC_BASE="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/${GCC_NAME}/+archive/refs/heads/${GCC_REF}"

ROOT="$PWD"
TOOLS="$ROOT/toolchains"
KERNEL="$ROOT/kernel"
OUT="$ROOT/out"
mkdir -p "$TOOLS" "$OUT"

log() { echo ""; echo "==> $*"; }

# ----------------------------------------------------------------- toolchain
if [ ! -x "$TOOLS/clang/bin/clang" ]; then
  log "downloading $CLANG_VERSION"
  mkdir -p "$TOOLS/clang"
  curl -fL --retry 3 -o "$TOOLS/clang.tar.gz" "$CLANG_BASE/$CLANG_VERSION.tar.gz"
  tar -xzf "$TOOLS/clang.tar.gz" -C "$TOOLS/clang"
  rm -f "$TOOLS/clang.tar.gz"
fi
if [ ! -x "$TOOLS/gcc/bin/aarch64-linux-android-ld" ]; then
  log "downloading $GCC_NAME (binutils)"
  mkdir -p "$TOOLS/gcc"
  curl -fL --retry 3 -o "$TOOLS/gcc.tar.gz" "$GCC_BASE.tar.gz"
  tar -xzf "$TOOLS/gcc.tar.gz" -C "$TOOLS/gcc"
  rm -f "$TOOLS/gcc.tar.gz"
fi
# the kernel build uses CROSS_COMPILE=aarch64-linux-androidkernel-; older
# prebuilt snapshots only ship the -android- prefixed names.
for t in ld as ar nm objcopy objdump strip ranlib readelf; do
  if [ ! -e "$TOOLS/gcc/bin/aarch64-linux-androidkernel-$t" ]; then
    ln -sf "aarch64-linux-android-$t" "$TOOLS/gcc/bin/aarch64-linux-androidkernel-$t"
  fi
done

export PATH="$TOOLS/clang/bin:$TOOLS/gcc/bin:$PATH"
clang --version | head -n1
aarch64-linux-androidkernel-ld --version | head -n1

# ------------------------------------------------------------- kernel source
if [ ! -d "$KERNEL/.git" ]; then
  log "cloning $KERNEL_REPO ($KERNEL_REF)"
  git clone --depth 1 --branch "$KERNEL_REF" "$KERNEL_REPO" "$KERNEL"
fi
cd "$KERNEL"
echo "kernel HEAD: $(git log --oneline -1)"
echo "Makefile version: $(sed -n '1,4p' Makefile | tr '\n' ' ')"

# ------------------------------------------------- KernelSU-Next integration
log "integrating KernelSU-Next ($KSU_REF) via the official setup.sh"
git config user.email "ci@local"
git config user.name "ci"
if ! curl -fsSL "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" \
     | bash -s "$KSU_REF"; then
  echo "setup.sh from 'next' failed, falling back to the legacy branch copy"
  curl -fsSL "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/legacy/kernel/setup.sh" \
     | bash -s "$KSU_REF"
fi
test -e drivers/kernelsu || { echo "!! drivers/kernelsu symlink missing"; exit 1; }
echo "KernelSU-Next kernel dir: $(readlink -f drivers/kernelsu)"
grep -n "kernelsu" drivers/Makefile drivers/Kconfig

KSU_COMMIT="$(git -C "$KERNEL/KernelSU-Next" rev-parse --short HEAD 2>/dev/null || echo unknown)"
KSU_DESC="$(git -C "$KERNEL/KernelSU-Next" describe --tags --always 2>/dev/null || echo unknown)"
log "KernelSU-Next: $KSU_DESC ($KSU_COMMIT)"

# ------------------------------------------------------------------- patches
log "applying the manual-hook patches"
git apply -v "$ROOT/patches/0001-kernelsu-next-manual-hooks.patch"
for f in fs/exec.c fs/open.c fs/read_write.c fs/stat.c kernel/reboot.c \
         drivers/input/input.c; do
  printf '  %-24s %s ksu_handle hit(s)\n' "$f" "$(grep -c ksu_handle "$f")"
done
# KernelSU-Next's Kbuild aborts the build unless this string is present:
grep -q ksu_handle_sys_reboot kernel/reboot.c \
  || { echo "!! kernel/reboot.c has no KSU hook - the build would abort"; exit 1; }

log "enabling CONFIG_KSU in $DEFCONFIG"
DC="arch/arm64/configs/$DEFCONFIG"
[ -f "$DC" ] || { echo "!! $DC not found"; exit 1; }
if [ -n "$(tail -c 1 "$DC")" ]; then printf '\n' >> "$DC"; fi
if ! grep -q '^CONFIG_KSU=y' "$DC"; then
  cat >> "$DC" <<'EOF'

# KernelSU-Next (manual hooks; CONFIG_KPROBES is off on this kernel)
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
EOF
fi
tail -n 5 "$DC"

# --------------------------------------------------------------------- build
# plain string on purpose (keeps the script POSIX-lintable)
MAKE_ARGS="-j$MAKE_JOBS O=out ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-androidkernel- KCFLAGS=-Wno-error"

log "defconfig"
make $MAKE_ARGS "$DEFCONFIG"

log "building Image.gz (expect 10-30 minutes)"
make $MAKE_ARGS Image.gz

test -f out/arch/arm64/boot/Image.gz || { echo "!! Image.gz was not produced"; exit 1; }
grep -E '^CONFIG_(KSU|KSU_MANUAL_HOOK|KPROBES)=' out/.config || true
if ! grep -q '^CONFIG_KSU=y' out/.config; then
  echo "!! CONFIG_KSU is not enabled in the final .config"; exit 1
fi

# --------------------------------------------------------------- packaging
log "assembling Image.gz-dtb (built Image.gz + stock appended DTBs)"
cp out/arch/arm64/boot/Image.gz "$OUT/Image.gz"
cat out/arch/arm64/boot/Image.gz "$ROOT/files/dtbtail.bin" > "$OUT/Image.gz-dtb"
ls -l "$OUT/Image.gz" "$OUT/Image.gz-dtb"

log "fetching AnyKernel3"
rm -rf "$ROOT/ak3"
git clone --depth 1 https://github.com/osm0sis/AnyKernel3.git "$ROOT/ak3"
rm -rf "$ROOT/ak3/.git" "$ROOT/ak3/.github" "$ROOT/ak3/README.md"

cat > "$ROOT/ak3/anykernel.sh" <<'EOF'
### AnyKernel3 install script - Xperia XZ2 Compact (apollo)
properties() { '
kernel.string=KernelSU-Next legacy (4.9.337) for Xperia XZ2 Compact
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=apollo
device.name2=Xperia XZ2 Compact
device.name3=H8324
device.name4=H8314
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

### install
BLOCK=boot
IS_SLOT_DEVICE=1
RAMDISK_BACKUP_TIME=0

. tools/ak3-core.sh

dump_boot
write_boot
EOF

cp "$OUT/Image.gz-dtb" "$ROOT/ak3/Image.gz-dtb"
STAMP="$(date -u +%Y%m%d)"
NAME="kernelsu-next-apollo-4.9.337-${STAMP}.zip"
( cd "$ROOT/ak3" && zip -r9 "$OUT/$NAME" . -x '*.git*' >/dev/null )
ls -l "$OUT/$NAME"
unzip -l "$OUT/$NAME" | head -n 20

{
  echo "kernel repo      : $KERNEL_REPO"
  echo "kernel ref       : $KERNEL_REF"
  echo "kernel commit    : $(git -C "$KERNEL" log --oneline -1)"
  echo "KernelSU-Next    : $KSU_DESC ($KSU_COMMIT), ref=$KSU_REF"
  echo "clang            : $CLANG_VERSION ($(clang --version | head -n1))"
  echo "binutils         : $GCC_NAME"
  echo "defconfig        : $DEFCONFIG"
  echo "built at         : $(date -u)"
  echo "artifact         : $NAME"
  grep -E '^CONFIG_(KSU|KSU_MANUAL_HOOK|KPROBES|LOCALVERSION|MODVERSIONS|BPF_SYSCALL)=' "$KERNEL/out/.config" || true
} | tee "$OUT/build-info.txt"

log "done"
