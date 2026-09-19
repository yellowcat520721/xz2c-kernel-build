#!/bin/bash
# Sanity-check the kernel that was just built: does it really contain
# KernelSU-Next and the manual hooks?
#
# IMPORTANT: this also prints WHERE a failed build stopped and the tail of the
# build log, so the CI output alone is enough to diagnose a failure.
set -uo pipefail

KERNEL="$PWD/kernel"
ROOT="$PWD"
FAIL=0

chk() { # chk <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  OK   $desc"
  else
    echo "  FAIL $desc"; FAIL=1
  fi
}

# ---------------------------------------------------------------- failure aid
echo "== where did the build stop? =="
if [ -f out/.stage ]; then
  echo "  last completed STAGE: $(cat out/.stage)"
else
  echo "  no out/.stage file at all -> the script died very early (toolchain?)"
fi
if [ -f build.log ]; then
  echo "  build.log size: $(wc -c < build.log) bytes, lines: $(wc -l < build.log)"
  echo "  --- last 40 lines of build.log ---"
  tail -n 40 build.log | sed 's/^/  | /'
  echo "  --- / ---"
fi
echo

echo "== config =="
grep -E '^CONFIG_(KSU|KSU_MANUAL_HOOK|KPROBES|BPF_SYSCALL|LOCALVERSION|MODVERSIONS)=' \
  "$KERNEL/out/.config" 2>/dev/null || echo "  (no $KERNEL/out/.config - the defconfig step never finished)"
chk "CONFIG_KSU=y"             grep -q '^CONFIG_KSU=y' "$KERNEL/out/.config"
chk "CONFIG_KSU_MANUAL_HOOK=y" grep -q '^CONFIG_KSU_MANUAL_HOOK=y' "$KERNEL/out/.config"
if grep -q '^CONFIG_KPROBES=y' "$KERNEL/out/.config" 2>/dev/null; then
  echo "  WARN CONFIG_KPROBES=y (manual-hook setups expect it off)"
fi

echo "== KernelSU hook mode (from the build log) =="
grep -m1 "Hook mode" build.log 2>/dev/null || echo "  (no 'Hook mode' line found)"

echo "== KernelSU integration =="
echo "  drivers/kernelsu -> $(readlink -f "$KERNEL/drivers/kernelsu" 2>/dev/null || echo MISSING)"
for f in fs/exec.c fs/open.c fs/read_write.c fs/stat.c kernel/reboot.c \
         drivers/input/input.c; do
  printf '  %-24s %s ksu_handle hit(s)\n' "$f" "$(grep -c ksu_handle "$KERNEL/$f" 2>/dev/null || echo 0)"
done

echo "== symbols in System.map =="
for s in ksu_handle_execveat ksu_handle_faccessat ksu_handle_stat \
         ksu_handle_sys_read ksu_handle_sys_reboot ksu_handle_input_handle_event; do
  if grep -qw "$s" "$KERNEL/out/System.map" 2>/dev/null; then
    echo "  OK   $s"
  else
    echo "  FAIL $s missing from System.map"; FAIL=1
  fi
done

echo "== KernelSU strings in vmlinux =="
if [ -f "$KERNEL/out/vmlinux" ]; then
  strings -a "$KERNEL/out/vmlinux" | grep -iE 'kernelsu|ksu_' | sort -u | head -n 15
  chk "vmlinux mentions kernelsu" grep -qi kernelsu "$KERNEL/out/vmlinux"
fi

echo "== artifact =="
ls -l out/Image.gz out/Image.gz-dtb out/*.zip 2>/dev/null || true
chk "Image.gz exists"     test -f out/Image.gz
chk "Image.gz-dtb exists" test -f out/Image.gz-dtb

if [ "$FAIL" != 0 ]; then
  echo
  echo "!! verification failed - the artifact is probably not usable"
  exit 1
fi
echo
echo "all checks passed"
