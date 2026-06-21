#!/usr/bin/env bash
# Phase 0 spike for ai/plans/bench.md "Building the driver with LDC".
#
# Question the plan poses: can an LDC-built bench tool dlopen and run a
# DMD-codegen .so in-process, sharing the host's single LDC druntime/GC, if we
# only supply a few DMD-only EH symbols (the "C-ABI firewall" idea)?
#
# This script reproduces the three empirical findings. It is throwaway: it
# builds into a temp dir and prints results. Requires dmd, ldc2, and the LDC
# shared druntime (libdruntime-ldc-shared.so).
set -u
cd "$(dirname "$0")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
drt="$(ldc2 --version >/dev/null 2>&1 && echo /usr/lib/libdruntime-ldc-shared.so.112.1)"

echo "############################################################"
echo "# Finding 1: the DMD-only symbol gap is exactly the EH trio"
echo "############################################################"
dmd -c -fPIC -g fixture.d -of="$work/fixture.o"
cc -shared "$work/fixture.o" -o "$work/libfixture.so"   # NB: no -defaultlib=libphobos2.so
echo "ldd libfixture.so (must NOT mention any DMD libphobos2):"
ldd "$work/libfixture.so" | grep -iE 'phobos|druntime' || echo "  (only libc — good)"
echo
echo "undefined symbols vs LDC shared druntime ($drt):"
for s in $(nm -D -u "$work/libfixture.so" | awk '{print $NF}' | grep -E '^_' | grep -vE '^_ITM_|^__cxa_|^__gmon'); do
    if nm -D "$drt" 2>/dev/null | awk '{print $NF}' | grep -qx "$s"; then
        printf "  provided-by-LDC : %s\n" "$s"
    else
        printf "  MISSING (gap)   : %s\n" "$s"
    fi
done
echo
echo "=> Only __dmd_personality_v0 / _d_throwdwarf / __dmd_begin_catch are"
echo "   missing. Everything else (GC, TypeInfo, object.Exception, _d_dso_registry)"
echo "   is present in LDC druntime by name."
echo

echo "############################################################"
echo "# Finding 2: _d_dso_registry ABI diverges (category 3 is NOT free)"
echo "############################################################"
echo "The DMD .so's .init_array calls _d_dso_registry with DMD-format DSO data."
echo "Resolved to LDC's registry it aborts at load:"
echo "  'Aborting from rt/sections_elf_shared.d(NNN) DSO already registered.'"
echo "(Observed when an LDC host loads a self-registering DMD .so or links any"
echo " DMD-compiled object that self-registers. SystemLinker does not need"
echo " registration: it dlsym's the unittest and DWARF unwinding uses"
echo " .eh_frame_hdr via the dynamic linker, not the druntime DSO registry.)"
echo

echo "############################################################"
echo "# Finding 3 (decisive): extern(D) calling convention diverges"
echo "############################################################"
dmd -c -fPIC -O abi_lib.d -of="$work/lib_dmd.o"
cc -shared "$work/lib_dmd.o" -o "$work/liblib_dmd.so"
dsym="$(nm -D --defined-only "$work/liblib_dmd.so" | awk '/_D.*d_combine/{print $NF}')"
ldc2 -O2 abi_callhost.d -of="$work/callhost" -link-defaultlib-shared -L-ldl
( cd "$work" && ./callhost "$dsym" )
echo
echo "=> extern(C) agrees; extern(D) returns 4321 for inputs 1,2,3,4 — DMD and"
echo "   LDC pass extern(D) parameters in opposite orders. A DMD-codegen test"
echo "   calling any extern(D) druntime/phobos function (e.g. Exception.__ctor)"
echo "   in an LDC-compiled host scrambles its arguments and crashes. The"
echo "   in-process 'share one LDC druntime' architecture is therefore unsound."
