#!/bin/bash
# ==============================================================================
# Build a KernelSU-Next (legacy / manual-hook) kernel for the Sony Xperia XZ2
# Compact (apollo, SDM845, kernel 4.9.337) and package it as an AnyKernel3 zip.
#
# Runs on Linux (GitHub Actions ubuntu-22.04 or any Debian-ish box).
#
# Inputs (env):
#   KERNEL_REPO   kernel source   (default upstream aoitsme/android_kernel_sony_sdm845)
#   KERNEL_REF    branch/tag      (default bpf)
#   KSU_REF       KernelSU-Next   (default legacy)
#   CLANG_VERSION AOSP clang      (default clang-r547379)
#   DEFCONFIG     defconfig       (default tama_apollo_defconfig)
#   BINUTILS      apt | los49     (default apt   - where ld/objcopy/ar come from)
#   LD_KIND       gnu | lld       (default gnu   - which linker to use)
#   MAKE_JOBS     -jN             (default nproc)
#
# NOTE: AOSP's gitiles archives of prebuilts/gcc/.../aarch64-linux-android-4.9
# are EMPTY now (0 bytes), which is what made the first CI run fail at the
# symlink step.  So binutils come from the distro package by default, with the
# LineageOS mirror of the old 4.9 prebuilt as an explicit alternative.
# ==============================================================================
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://github.com/aoitsme/android_kernel_sony_sdm845.git}"
KERNEL_REF="${KERNEL_REF:-bpf}"
KSU_REF="${KSU_REF:-legacy}"
CLANG_VERSION="${CLANG_VERSION:-clang-r547379}"
DEFCONFIG="${DEFCONFIG:-tama_apollo_defconfig}"
BINUTILS="${BINUTILS:-apt}"
LD_KIND="${LD_KIND:-gnu}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

CLANG_BASE="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main"
LOS49_URL="https://codeload.github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/tar.gz/refs/heads/lineage-19.1"

ROOT="$PWD"
TOOLS="$ROOT/toolchains"
KERNEL="$ROOT/kernel"
OUT="$ROOT/out"
mkdir -p "$TOOLS" "$OUT"

log() { echo ""; echo "==> $*"; }
die() { echo ""; echo "!! $*"; echo "!! (failure at STAGE: $(cat "$STAGE_FILE" 2>/dev/null))"; exit 1; }

# every phase writes its name here, so verify.sh can tell us exactly where a
# failed run stopped - that is what makes a pasted CI log self-diagnosing.
STAGE_FILE="$OUT/.stage"
stage() { echo "$*" > "$STAGE_FILE" 2>/dev/null; log "STAGE: $*"; }

# ------------------------------------------------------------------ clang
stage "clang-toolchain"
# a cache from an interrupted run can leave a half-extracted clang behind
if [ -x "$TOOLS/clang/bin/clang" ] && ! "$TOOLS/clang/bin/clang" --version >/dev/null 2>&1; then
  echo "cached clang is broken -> discarding and re-downloading"
  rm -rf "$TOOLS/clang"
fi
if [ ! -x "$TOOLS/clang/bin/clang" ]; then
  log "downloading $CLANG_VERSION"
  mkdir -p "$TOOLS/clang"
  curl -fL --retry 3 -o "$TOOLS/clang.tar.gz" "$CLANG_BASE/$CLANG_VERSION.tar.gz" \
    || die "clang download failed"
  tar -xzf "$TOOLS/clang.tar.gz" -C "$TOOLS/clang" || die "clang extract failed"
  rm -f "$TOOLS/clang.tar.gz"
fi

# --------------------------------------------------------------- binutils
stage "binutils"
CROSS_COMPILE=""
case "$BINUTILS" in
  apt)
    # binutils-aarch64-linux-gnu ships aarch64-linux-gnu-{ld,as,ar,nm,objcopy,...}
    if command -v aarch64-linux-gnu-ld >/dev/null 2>&1; then
      CROSS_COMPILE="aarch64-linux-gnu-"
    else
      log "aarch64-linux-gnu-ld missing, trying the LineageOS 4.9 prebuilt"
      BINUTILS=los49
    fi
    ;;
esac

if [ "$BINUTILS" = "los49" ] && [ -z "$CROSS_COMPILE" ]; then
  if [ ! -x "$TOOLS/gcc/bin/aarch64-linux-android-ld" ]; then
    log "downloading the LineageOS mirror of the AOSP gcc-4.9 aarch64 binutils"
    mkdir -p "$TOOLS/gcc"
    curl -fL --retry 3 -o "$TOOLS/gcc.tar.gz" "$LOS49_URL" || die "binutils download failed"
    SZ=$(stat -c %s "$TOOLS/gcc.tar.gz")
    [ "$SZ" -lt 1000000 ] && die "binutils archive looks empty ($SZ bytes)"
    tar -xzf "$TOOLS/gcc.tar.gz" -C "$TOOLS/gcc" --strip-components=1 || die "binutils extract failed"
    rm -f "$TOOLS/gcc.tar.gz"
  fi
  CROSS_COMPILE="aarch64-linux-android-"
fi

[ -n "$CROSS_COMPILE" ] || die "no usable binutils found"

export PATH="$TOOLS/clang/bin:$TOOLS/gcc/bin:$PATH"

# fail fast instead of dying 4 minutes in
log "toolchain"
echo "  CLANG_VERSION   = $CLANG_VERSION"
echo "  CROSS_COMPILE   = $CROSS_COMPILE"
echo "  BINUTILS        = $BINUTILS   LD_KIND = $LD_KIND"
for t in clang llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip \
         "${CROSS_COMPILE}ld" "${CROSS_COMPILE}as" "${CROSS_COMPILE}ar" \
         "${CROSS_COMPILE}nm" "${CROSS_COMPILE}objcopy"; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '  ok   %-38s %s\n' "$t" "$(command -v "$t")"
  else
    printf '  MISS %-38s\n' "$t"
  fi
done
command -v clang >/dev/null 2>&1 || die "clang not on PATH"
command -v "${CROSS_COMPILE}ld" >/dev/null 2>&1 || die "${CROSS_COMPILE}ld not found"
clang --version | head -n1
"${CROSS_COMPILE}ld" --version | head -n1

# ------------------------------------------------------------- kernel source
stage "kernel-clone"
if [ ! -d "$KERNEL/.git" ]; then
  log "cloning $KERNEL_REPO ($KERNEL_REF)"
  git clone --depth 1 --branch "$KERNEL_REF" "$KERNEL_REPO" "$KERNEL"
fi
cd "$KERNEL"
echo "kernel HEAD: $(git log --oneline -1)"
echo "Makefile version: $(sed -n '1,4p' Makefile | tr '\n' ' ')"

# ------------------------------------------------- KernelSU-Next integration
stage "kernelsu-setup"
log "integrating KernelSU-Next ($KSU_REF) via the official setup.sh"
git config user.email "ci@local"
git config user.name "ci"
if ! curl -fsSL "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" \
     | bash -s "$KSU_REF"; then
  echo "setup.sh from 'next' failed, falling back to the legacy branch copy"
  curl -fsSL "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/legacy/kernel/setup.sh" \
     | bash -s "$KSU_REF"
fi
test -e drivers/kernelsu || die "drivers/kernelsu symlink was not created"
echo "KernelSU-Next kernel dir: $(readlink -f drivers/kernelsu)"
grep -n "kernelsu" drivers/Makefile drivers/Kconfig

KSU_COMMIT="$(git -C "$KERNEL/KernelSU-Next" rev-parse --short HEAD 2>/dev/null || echo unknown)"
KSU_DESC="$(git -C "$KERNEL/KernelSU-Next" describe --tags --always 2>/dev/null || echo unknown)"
log "KernelSU-Next: $KSU_DESC ($KSU_COMMIT)"

# ------------------------------------------------------------------- patches
stage "patches"
log "applying the manual-hook patches"
git apply -v "$ROOT/patches/0001-kernelsu-next-manual-hooks.patch" \
  || die "the manual hook patch did not apply (kernel ref changed?)"
for f in fs/exec.c fs/open.c fs/read_write.c fs/stat.c kernel/reboot.c \
         drivers/input/input.c; do
  printf '  %-24s %s ksu_handle hit(s)\n' "$f" "$(grep -c ksu_handle "$f")"
done
grep -q ksu_handle_sys_reboot kernel/reboot.c \
  || die "kernel/reboot.c has no KSU hook - KernelSU-Next would abort the build"

log "enabling CONFIG_KSU in $DEFCONFIG"
DC="arch/arm64/configs/$DEFCONFIG"
[ -f "$DC" ] || die "$DC not found"
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
MAKE_ARGS="-j$MAKE_JOBS O=out ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=$CROSS_COMPILE KCFLAGS=-Wno-error"
if [ "$LD_KIND" = "lld" ]; then
  MAKE_ARGS="$MAKE_ARGS LD=ld.lld"
  command -v ld.lld >/dev/null 2>&1 || die "LD_KIND=lld but ld.lld is not available"
fi
echo "MAKE_ARGS = $MAKE_ARGS"

stage "make-defconfig"
log "defconfig"
make $MAKE_ARGS "$DEFCONFIG" || die "make $DEFCONFIG failed (see the log above)"

stage "make-Image.gz"
log "building Image.gz (expect 10-30 minutes)"
make $MAKE_ARGS Image.gz || die "make Image.gz failed (see the log above)"

test -f out/arch/arm64/boot/Image.gz || die "Image.gz was not produced"
grep -E '^CONFIG_(KSU|KSU_MANUAL_HOOK|KPROBES)=' out/.config || true
grep -q '^CONFIG_KSU=y' out/.config || die "CONFIG_KSU is not enabled in the final .config"

# --------------------------------------------------------------- packaging
stage "packaging"
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
  echo "binutils         : $BINUTILS / CROSS_COMPILE=$CROSS_COMPILE"
  echo "linker           : $LD_KIND"
  echo "defconfig        : $DEFCONFIG"
  echo "built at         : $(date -u)"
  echo "artifact         : $NAME"
  grep -E '^CONFIG_(KSU|KSU_MANUAL_HOOK|KPROBES|LOCALVERSION|MODVERSIONS|BPF_SYSCALL)=' "$KERNEL/out/.config" || true
} | tee "$OUT/build-info.txt"

log "done"
