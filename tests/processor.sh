#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317 # the overrides are read or called by the sourced install.sh functions
# Exercise the processor check against fake /proc/cpuinfo files.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'code=$?; if ((code)); then cat "$TEST_DIR/log" "$TEST_DIR/terminal" >&4 2> /dev/null; fi; rm -rf "$TEST_DIR"' EXIT
trap 'printf "Failed at line %s\n" "$LINENO" >&2' ERR
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$ROOT/install.sh")
exec 4>&1
exec 3> "$TEST_DIR/terminal"
exec > "$TEST_DIR/log" 2>&1

CPUINFO=$TEST_DIR/cpuinfo
OLD='fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 syscall nx lm rep_good nopl cpuid pni cx16 hypervisor lahf_lm'
NEW="$OLD ssse3 sse4_1 sse4_2 x2apic popcnt"

cpu() { printf 'processor\t: 0\nmodel name\t: %s\nflags\t\t: %s\nbogomips\t: 4000.00\n' "$1" "$2" > "$CPUINFO"; }
refused() { ! (require_processor) || { echo "accepted: $1"; exit 1; }; }
uname() { echo x86_64; }
expect_terminal() { grep -qF -- "$1" "$TEST_DIR/terminal" || { echo "expected on the terminal: $1"; exit 1; }; }

# A processor with every needed instruction passes.
cpu 'AMD EPYC Processor' "$NEW"
require_processor

# The plain QEMU processor type lacks four of them; the message names them and says what to ask the provider.
cpu 'QEMU Virtual CPU version 2.5+' "$OLD"
refused 'the QEMU processor type'
expect_terminal 'popcnt ssse3 sse4_1 sse4_2'
expect_terminal 'ask your provider'

# One missing instruction is enough, and a longer name that contains it does not count.
cpu 'Old CPU' "${NEW/ popcnt/ popcnt_extra}"
refused 'a processor without popcnt'

# A system that lists no flags is not refused.
printf 'processor\t: 0\n' > "$CPUINFO"
require_processor

# Only x86_64 has the requirement: arm64 lists no such flags and is never refused.
cpu 'arm' "$OLD"
uname() { echo aarch64; }
require_processor

echo 'processor: ok' >&4
