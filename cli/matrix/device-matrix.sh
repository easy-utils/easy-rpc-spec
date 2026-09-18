#!/usr/bin/env bash
# easy-rpc DEVICE transport conformance (spec §7.1). These transports cannot run
# on the Linux dev pod — they require an Android device/emulator (Cronet) or a
# macOS host (Cupertino / URLSession h3) — so they are NOT part of run-matrix.sh.
#
# Run this FROM the relevant worker (see k8s/ manifests):
#   easyworker-android.yaml   -> Kotlin CronetTransport, Dart CronetHttpTransport
#   easyworker-macos*.yaml    -> Dart CupertinoHttpTransport, Swift URLSessionTransport (h3)
#   easyworker-linux-desktop  -> C# HttpClientTransport H3 (msquic, if available)
#
# Contract: EASY_RPC_BASE points at an easy-rpc conformance server reachable
# from the worker; EASY_RPC_TRANSPORT names the transport; the worker must run
# the language test target for that transport. Exit 0 => PASS.
#
# Each block below is a TEMPLATE: the worker-specific harness (Gradle/Flutter/
# swift/xunit invocation, plus the TLS/CA setup needed for h3) is provided by the
# worker image. This script documents the required (transport -> command) map so
# the device runs are reproducible and never silently skipped.
set -u
DEVICE="${1:-android}"
BASE="${EASY_RPC_BASE:-http://172.17.0.196:18888}"

echo "== device conformance: device=$DEVICE base=$BASE =="

case "$DEVICE" in
  android)
    # Kotlin CronetTransport (h1+h2+h3) and Dart CronetHttpTransport (h1+h2+h3).
    # The conformance server must be reachable over the pod network; TLS/h3
    # requires a CA the device trusts (system store) or a public CA — see
    # easy-rpc-spec/cli/matrix/macos-results.md §"h3/QUIC 取证".
    echo "kotlin Cronet:  EASY_RPC_BASE=$BASE EASY_RPC_TRANSPORT=cronet \\"
    echo "                gradle test --tests 'InteropTest'   # in easy-rpc-kotlin, on the android worker"
    echo "dart Cronet:    EASY_RPC_BASE=$BASE EASY_RPC_TRANSPORT=cronet \\"
    echo "                flutter test test/cronet_interop_test.dart   # in easy-rpc-dart, on the android worker"
    ;;
  macos)
    echo "dart Cupertino: EASY_RPC_BASE=$BASE EASY_RPC_TRANSPORT=cupertino \\"
    echo "                dart test test/cupertino_interop_test.dart   # on the macos worker"
    echo "swift URLSession h3: EASY_RPC_BASE=$BASE EASY_RPC_TRANSPORT=urlsession-h3 \\"
    echo "                swift test --filter InteropTests   # on the macos-xcode worker"
    ;;
  linux-desktop)
    echo "csharp H3:      EASY_RPC_BASE=$BASE EASY_RPC_TRANSPORT=h3 \\"
    echo "                dotnet test tests/tests.csproj --filter FullyQualifiedName~InteropTests"
    ;;
  *)
    echo "unknown device: $DEVICE (android|macos|linux-desktop)" >&2; exit 2;;
esac

echo
echo "NOTE: h3 requires the server to present a certificate the device trusts."
echo "      On Android the CA must be in the SYSTEM store (user-added roots are"
echo "      read for h2 but QUIC uses getUserAddedRoots -> system trust only);"
echo "      on macOS install the dev CA in the System keychain."
