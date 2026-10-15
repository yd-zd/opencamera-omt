#!/usr/bin/env bash
# Host-side QA for the vendored OMT C++ — no device, no JVM, no emulator.
#
# Every test here is run twice: against the current tree (must pass) and against a copy with the
# safety gate deliberately disabled (must fail). A test that is green in both cases is not
# evidence of anything — it just means nobody wrote the assertion.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
SCRATCH=${SCRATCH:-/tmp/omt-qa}
mkdir -p "$SCRATCH"
# Prefer the clang that ships with the NDK: vmxcodec.h uses __declspec(align(64)), which only
# clang accepts (with -fdeclspec), and using the same compiler family as the APK build means the
# host QA cannot drift into a build the device would never have produced.
if [ -z "${CXX:-}" ]; then
  for c in "${ANDROID_HOME:-$HOME/android-sdk}"/ndk/*/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++ \
           "$(command -v clang++ 2>/dev/null)"; do
    [ -x "$c" ] && CXX="$c" && break
  done
fi
CXX=${CXX:-g++}
# OMTChannel.h uses std::string without including <string>: the NDK's libc++ provides it
# transitively, host libstdc++ does not. Fixed in the tree; -include keeps older copies buildable
# so an A/B compares behaviour rather than failing on a missing include.
# -fms-extensions -fdeclspec: vmxcodec.h writes __declspec(align(64)); the APK build passes the
# same flags (app/src/main/cpp/CMakeLists.txt), so the host build must too or it cannot compile.
# -fms-extensions: vmxcodec.h writes __declspec(align(64)). The APK build adds -fdeclspec too,
# but that is a clang-only flag (the NDK is clang); g++ rejects it, so pick the flags per compiler.
DECLEXT="-fms-extensions"
case "$($CXX --version 2>/dev/null | head -1)" in *clang*) DECLEXT="-fms-extensions -fdeclspec";; esac
# ASan only: the NDK clang ships no host libubsan for this target (linking it fails on
# __ubsan_vptr_type_cache). ASan is what catches the lifetime bugs these tests are about.
FLAGS="-std=c++17 -O1 -g -march=haswell -fsanitize=address -pthread -include string -include cstring $DECLEXT"
INC="-I$ROOT/libomt/cpp -I$ROOT/libvmx/src -I$ROOT/libomt"
VMX="$ROOT/libvmx/src/vmxcodec.cpp $ROOT/libvmx/src/vmxcodec_x86.cpp $ROOT/libvmx/src/vmxcodec_avx2.cpp"

rc=0

# build_and_run <binary-name> <test.cpp> <omt-source-dir> <expect pass|fail> [post-compile sed on a copy]
build_and_run() {
  local name=$1 test=$2 srcdir=$3 expect=$4
  rm -f "$SCRATCH/$name"
  # shellcheck disable=SC2086
  $CXX $FLAGS $INC "$test" "$srcdir/OMTChannel.cpp" "$srcdir/OMTAsyncPool.cpp" \
       "$srcdir/OMTSender.cpp" "$srcdir/OMTDiscovery.cpp" $VMX \
       -o "$SCRATCH/$name" 2>"$SCRATCH/$name.build.log"
  if [ $? -ne 0 ] || [ ! -x "$SCRATCH/$name" ]; then
    echo "  $name: BUILD FAILED (refusing to score an absent run)"
    sed 's/^/      /' "$SCRATCH/$name.build.log" | head -10
    rc=1; return
  fi
  score_run "$name" "$expect"
}

fresh_copy() { # <dir> — an isolated tree a mutant may deface
  local d="$SCRATCH/$1"; rm -rf "$d"; mkdir -p "$d"
  cp "$ROOT"/libomt/cpp/*.cpp "$ROOT"/libomt/cpp/*.h "$d"/
  echo "$d"
}

fresh_copy_vmx() { # <dir> — an isolated copy of the CODEC, for mutants that edit vmxcodec.cpp
  local d="$SCRATCH/$1"; rm -rf "$d"; mkdir -p "$d"
  cp "$ROOT"/libvmx/src/*.cpp "$ROOT"/libvmx/src/*.h "$d"/
  echo "$d"
}

# score_run <binary-name> <expect pass|fail> — run the freshly built scenario and check it produced
# the verdict we predicted for it.
score_run() {
  timeout 90 "$SCRATCH/$1" >"$SCRATCH/$1.run.log" 2>&1
  # The status must be captured in the SAME statement that reads $?: two earlier versions of this
  # line (`local got=pass; [ $? -ne 0 ]` and `local got; if [ $? ...`) each scored every run as a
  # pass, because the intervening `local` is itself a command and resets $? to 0. A harness that
  # cannot go red is not evidence.
  local status=$?
  local got=fail
  [ "$status" -eq 0 ] && got=pass
  if [ "$got" = "$2" ]; then
    echo "  $1: $got as expected"
  else
    echo "  $1: $got but expected $2  <-- PROBLEM"
    sed 's/^/      /' "$SCRATCH/$1.run.log" | tail -18
    rc=1
  fi
}

# build_and_run_vmx <name> <test.cpp> <omt-src-dir> <vmx-src-dir> <expect pass|fail>
# Same as build_and_run, but the codec comes from a copy too — for scenarios whose whole point is a
# mutated vmxcodec.cpp. (Headers still resolve to the tree; the mutants below only ever change .cpp.)
build_and_run_vmx() {
  local name=$1 test=$2 srcdir=$3 vmxdir=$4 expect=$5
  rm -f "$SCRATCH/$name"
  # shellcheck disable=SC2086
  $CXX $FLAGS $INC "$test" "$srcdir/OMTChannel.cpp" "$srcdir/OMTAsyncPool.cpp" \
       "$srcdir/OMTSender.cpp" "$srcdir/OMTDiscovery.cpp" \
       "$vmxdir/vmxcodec.cpp" "$vmxdir/vmxcodec_x86.cpp" "$vmxdir/vmxcodec_avx2.cpp" \
       -o "$SCRATCH/$name" 2>"$SCRATCH/$name.build.log"
  if [ $? -ne 0 ] || [ ! -x "$SCRATCH/$name" ]; then
    echo "  $name: BUILD FAILED (refusing to score an absent run)"
    sed 's/^/      /' "$SCRATCH/$name.build.log" | head -10
    rc=1; return
  fi
  score_run "$name" "$expect"
}

echo "== slow-subscriber: a stalled Wi-Fi viewer must not take the stream down =="
build_and_run ss-fixed "$ROOT/qa/slow-subscriber.cpp" "$ROOT/libomt/cpp" pass
OLD="$SCRATCH/pre-fix"; rm -rf "$OLD"; mkdir -p "$OLD"
for f in OMTChannel.cpp OMTAsyncPool.cpp OMTSender.cpp OMTDiscovery.cpp \
         OMTChannel.h OMTSender.h OMTDiscovery.h OMTConstants.h OMTProtocol.h OMTAsyncPool.h; do
  git show "master:libomt/cpp/$f" > "$OLD/$f" 2>/dev/null || { echo "  cannot extract $f from master"; rc=1; }
done
build_and_run ss-prefix "$ROOT/qa/slow-subscriber.cpp" "$OLD" fail

echo
echo "== colorspace-gate: refuse what the encoder cannot honour =="
build_and_run cs-fixed "$ROOT/qa/colorspace-gate.cpp" "$ROOT/libomt/cpp" pass

M1=$(fresh_copy mutant-gate)
python3 - "$M1/OMTSender.cpp" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    if (frame.colorSpace != ColorSpace::Undefined &&"
assert s.count(old) == 1, "gate not found to disable"
open(p, "w").write(s.replace(old, "    if (false && frame.colorSpace != ColorSpace::Undefined &&", 1))
PY
build_and_run cs-mutant-gate "$ROOT/qa/colorspace-gate.cpp" "$M1" fail

M2=$(fresh_copy mutant-count)
python3 - "$M2/OMTSender.cpp" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "        encodeFailures_++;"
assert s.count(old) == 1, "counter not found to disable"
open(p, "w").write(s.replace(old, "        ; // MUTANT: the failure goes uncounted", 1))
PY
build_and_run cs-mutant-count "$ROOT/qa/colorspace-gate.cpp" "$M2" fail

echo
echo "== drop-policy: when the ring is full, the newest frame must be the one that survives =="
build_and_run dp-fixed "$ROOT/qa/drop-policy.cpp" "$ROOT/libomt/cpp" pass

M3=$(fresh_copy mutant-keep-oldest)
python3 - "$M3/OMTChannel.cpp" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "            if (!pendingQueue_.empty()) { stale = pendingQueue_.front(); pendingQueue_.pop(); }"
assert s.count(old) == 1, "evict-oldest not found"
# the original policy: keep what is queued, drop the frame in hand
open(p, "w").write(s.replace(old, "            if (false) { stale = pendingQueue_.front(); pendingQueue_.pop(); }", 1))
PY
build_and_run dp-mutant-keep-oldest "$ROOT/qa/drop-policy.cpp" "$M3" fail

M4=$(fresh_copy mutant-blind-drops)
python3 - "$M4/OMTSender.cpp" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    const int64_t delta = total - drops_baseline_.exchange(total);"
assert s.count(old) == 1, "drop window not found"
# the state before this commit: the C entry point returned a hardcoded 0
open(p, "w").write(s.replace(old, "    const int64_t delta = 0; (void)total;", 1))
PY
build_and_run dp-mutant-blind "$ROOT/qa/drop-policy.cpp" "$M4" fail

echo
echo "== vmx-saveto-contract: failure is 0, never a positive error code that reads as a frame =="
build_and_run vs-fixed "$ROOT/qa/vmx-saveto-contract.cpp" "$ROOT/libomt/cpp" pass

# MV1: the failure contract reverted. VMX_SaveTo answers a null instance / null dst / zero length
# with VMX_ERR_INVALID_INSTANCE (5) and VMX_ERR_INVALID_PARAMETERS (6) again, and Sender::send() —
# which tests `encodedLen <= 0` — puts a 5-byte payload behind a real FrameHeader on the wire.
MV1=$(fresh_copy_vmx mutant-saveto-errcodes)
python3 - "$MV1/vmxcodec.cpp" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "\tif (!instance) return 0;\n\tif (!dst) return 0;\n\tif (maxLen <= 0) return 0;\n"
assert s.count(old) == 1, "VMX_SaveTo failure contract not found"
new = ("\tif (!instance) return VMX_ERR_INVALID_INSTANCE;\n"
       "\tif (!dst) return VMX_ERR_INVALID_PARAMETERS;\n"
       "\tif (!maxLen) return VMX_ERR_INVALID_PARAMETERS;\n")
open(p, "w").write(s.replace(old, new, 1))
PY
build_and_run_vmx vs-mutant-saveto-errcodes "$ROOT/qa/vmx-saveto-contract.cpp" "$ROOT/libomt/cpp" "$MV1" fail

# MV2: CHECKBUFF_SAVE back to the out-of-range pointer comparison. The negative-length probes in
# part C then pass the bounds check and hand memcpy (size_t)(-8) and (size_t)(-4): ASan, not an
# assertion. Both loops are probed because the macro is written out twice in VMX_SaveTo.
MV2=$(fresh_copy_vmx mutant-checkbuff)
python3 - "$MV2/vmxcodec.cpp" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "\tif (_need < 4 || _need > _remaining) return 0; \\\n"
assert s.count(old) == 1, "CHECKBUFF_SAVE remaining-bytes check not found"
open(p, "w").write(s.replace(old, "\tif ((b + checkNumBytes) > maxB) return 0; \\\n", 1))
PY
build_and_run_vmx vs-mutant-checkbuff "$ROOT/qa/vmx-saveto-contract.cpp" "$ROOT/libomt/cpp" "$MV2" fail

# MV4: the sender's own length gate disabled at the predicate. The codec bounds itself, so this is
# the belt being tested on its own — which is only possible because the predicate is pure.
MV4=$(fresh_copy mutant-saveto-predicate)
python3 - "$MV4/OMTSender.cpp" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    return encodedLen > 0 && static_cast<size_t>(encodedLen) <= capacity;"
assert s.count(old) == 1, "encodedLenAcceptable predicate not found"
open(p, "w").write(s.replace(old, "    return true;  // MUTANT: any length the codec returns is publishable", 1))
PY
build_and_run vs-mutant-predicate "$ROOT/qa/vmx-saveto-contract.cpp" "$MV4" fail

echo
if [ $rc -ne 0 ]; then echo "QA FAILED"; exit 1; fi
echo "QA PASSED (every gate has a scenario where disabling it turns the suite red)"
