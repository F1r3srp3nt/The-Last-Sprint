#!/bin/bash
# Checks that this Mac can build (and, with --tests, test) this Swift package, and says exactly how to
# fix anything missing. It only reads: it never installs tools, accepts licences or changes the selected
# developer directory (xcode-select). Identical copies live in distil/scripts and relay/scripts.
#
# Usage: bash scripts/check-prereqs.sh            # build and package the app
#        bash scripts/check-prereqs.sh --tests    # also run the XCTest suites
# Honours DEVELOPER_DIR, like swift and xcrun do, so one command can use a different Xcode:
#        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/check-prereqs.sh --tests
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WANT_TESTS=0
[[ "${1:-}" == "--tests" ]] && WANT_TESTS=1

failures=0
ok()   { printf '  ok    %s\n' "$1"; }
note() { printf '  note  %s\n' "$1"; }
fail() {
  failures=$((failures + 1))
  printf '  FAIL  %s\n' "$1"; shift
  for line in "$@"; do printf '        %s\n' "$line"; done
}
# ver_ge A B: true when version A >= B (compares up to three numeric parts).
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); m = split(b, y, ".");
    for (i = 1; i <= 3; i++) { p = (i <= n ? x[i] : 0) + 0; q = (i <= m ? y[i] : 0) + 0;
      if (p > q) exit 0; if (p < q) exit 1 } exit 0 }'
}

manifest="$ROOT/Package.swift"
tools_version="$(sed -nE '1s#^// *swift-tools-version: *([0-9.]+).*#\1#p' "$manifest" 2>/dev/null)"
min_macos="$(sed -nE 's/.*\.macOS\(\.v([0-9]+)(_([0-9]+))?\).*/\1.\3/p' "$manifest" 2>/dev/null | head -1)"
min_macos="${min_macos%.}"; [[ "$min_macos" == *.* ]] || min_macos="${min_macos:-14}.0"
tools_version="${tools_version:-5.9}"

echo "Prerequisites for $(basename "$ROOT")/ ($([[ $WANT_TESTS == 1 ]] && echo "build, package and test" || echo "build and package"))"

# --- Linux: only the core libraries and their tests build; the apps need macOS. ---
if [[ "$(uname -s)" != Darwin ]]; then
  note "$(uname -s): the core libraries and tests build here; the macOS app needs a Mac."
  if command -v swift >/dev/null 2>&1; then
    v="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)*).*/\1/p' | head -1)"
    if ver_ge "${v:-0}" "$tools_version"; then ok "Swift $v (needs $tools_version or later)"
    else fail "Swift ${v:-unknown} is older than this package's tools version $tools_version." "Fix: install Swift $tools_version or later from swift.org."; fi
  else
    fail "swift was not found on PATH." "Fix: install a Swift toolchain from swift.org and add its usr/bin to PATH."
  fi
  [[ $failures -eq 0 ]] && echo "Ready." || echo "Not ready: $failures problem(s) above."
  exit $(( failures > 0 ))
fi

# --- macOS version ---
os="$(sw_vers -productVersion 2>/dev/null)"
if ver_ge "${os:-0}" "$min_macos"; then ok "macOS $os (needs $min_macos or later)"
else fail "macOS ${os:-unknown} is older than $min_macos, which the app requires." "Fix: update macOS to $min_macos or later (System Settings › General › Software Update)."; fi

# --- Selected developer directory (DEVELOPER_DIR wins over xcode-select, as for swift itself) ---
if [[ -n "${DEVELOPER_DIR:-}" ]]; then dev="$DEVELOPER_DIR"; source_of_dev="DEVELOPER_DIR"
else dev="$(xcode-select -p 2>/dev/null)"; source_of_dev="xcode-select"; fi
xcodes="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -3 | tr '\n' ' ')"
first_xcode="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
kind="none"
if [[ -z "$dev" || ! -d "$dev" ]]; then
  fail "No developer tools are selected (${source_of_dev}: ${dev:-none})." \
       "Fix: install Xcode from the App Store, or run: xcode-select --install"
elif [[ "$dev" == *.app/Contents/Developer ]]; then
  kind="xcode"
  xv="$(DEVELOPER_DIR="$dev" xcodebuild -version 2>/dev/null | head -1)"
  ok "Developer directory ($source_of_dev): $dev (${xv:-Xcode})"
else
  kind="clt"
  if [[ $WANT_TESTS == 1 ]]; then
    note "Developer directory ($source_of_dev): $dev (Command Line Tools)."
  else
    ok "Developer directory ($source_of_dev): $dev (Command Line Tools; enough to build the app)"
  fi
fi

# --- Xcode licence and first-launch components (full Xcode only) ---
if [[ "$kind" == xcode ]]; then
  if DEVELOPER_DIR="$dev" xcodebuild -license check >/dev/null 2>&1; then ok "Xcode licence accepted"
  else fail "The Xcode licence has not been accepted, so swift and xcrun refuse to run." "Fix: sudo xcodebuild -license accept   (or open Xcode once and agree)"; fi
  if DEVELOPER_DIR="$dev" xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then ok "Xcode first-launch components installed"
  else fail "Xcode's first-launch components are not installed." "Fix: xcodebuild -runFirstLaunch   (or open Xcode once and let it install components)"; fi
fi

# --- Swift compiler ---
if [[ "$kind" != none ]]; then
  if v_out="$(DEVELOPER_DIR="$dev" swift --version 2>&1)"; then
    v="$(printf '%s' "$v_out" | sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)*).*/\1/p' | head -1)"
    if ver_ge "${v:-0}" "$tools_version"; then ok "Swift $v (this package needs $tools_version or later)"
    else fail "Swift ${v:-unknown} is older than this package's tools version $tools_version." "Fix: install Xcode 15 or later (Swift 5.9+) and select it (see below)."; fi
  else
    fail "swift did not run: $(printf '%s' "$v_out" | head -1)" "Fix: see the licence and developer-directory items above."
  fi

  # --- macOS SDK ---
  sdk_ver="$(DEVELOPER_DIR="$dev" xcrun --sdk macosx --show-sdk-version 2>/dev/null)"
  sdk_path="$(DEVELOPER_DIR="$dev" xcrun --sdk macosx --show-sdk-path 2>/dev/null)"
  if [[ -n "$sdk_path" && -d "$sdk_path" ]] && ver_ge "${sdk_ver:-0}" "$min_macos"; then
    ok "macOS SDK $sdk_ver (needs $min_macos or later)"
  elif [[ -n "$sdk_path" && -d "$sdk_path" ]]; then
    fail "The macOS SDK is $sdk_ver; the app needs the $min_macos SDK (Xcode 15 or later)." "Fix: update Xcode or the Command Line Tools (Software Update), then re-run this check."
  else
    fail "No macOS SDK was found for $dev." "Fix: xcode-select --install   (Command Line Tools), or install Xcode."
  fi

  # --- codesign (used to sign the .app ad hoc) ---
  if [[ -x /usr/bin/codesign ]]; then ok "codesign available"
  else fail "/usr/bin/codesign is missing." "Fix: xcode-select --install"; fi
fi

# --- XCTest (only for --tests) ---
if [[ $WANT_TESTS == 1 && "$kind" != none ]]; then
  platform="$(DEVELOPER_DIR="$dev" xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null)"
  xctest=""
  for candidate in "$platform/Developer/Library/Frameworks/XCTest.framework" \
                   "$dev/Library/Developer/Frameworks/XCTest.framework"; do
    [[ -n "$candidate" && -d "$candidate" ]] && { xctest="$candidate"; break; }
  done
  if [[ -n "$xctest" ]]; then
    ok "XCTest found ($xctest)"
  elif [[ -n "$first_xcode" ]]; then
    fail "XCTest is not available in $dev. Tests fail with \"no such module 'XCTest'\"." \
         "Xcode is installed (${xcodes% }). Either use it for this command only:" \
         "  DEVELOPER_DIR=$first_xcode/Contents/Developer bash $ROOT/scripts/test.sh" \
         "or select it for the whole Mac (your choice; this script never changes it):" \
         "  sudo xcode-select --switch $first_xcode/Contents/Developer"
  else
    fail "XCTest is not available in $dev. Tests fail with \"no such module 'XCTest'\"." \
         "Fix: install Xcode 15 or later from the App Store, open it once, then either run" \
         "  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash $ROOT/scripts/test.sh" \
         "or select it for the whole Mac: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" \
         "Building and packaging the app does not need XCTest."
  fi
fi

if [[ $failures -eq 0 ]]; then
  echo "Ready."
else
  echo "Not ready: $failures problem(s) above. Nothing was built."
fi
exit $(( failures > 0 ))
