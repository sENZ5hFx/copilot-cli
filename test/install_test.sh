#!/usr/bin/env bash
set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
BASE_PATH="$PATH"
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$WORK_ROOT"' EXIT

FAILURES=0
STATUS=0
OUTPUT=""

fail() {
  printf '    %s\n' "$*" >&2
  return 1
}

assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) fail "expected output to contain: $2" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected output not to contain: $2" ;;
    *) return 0 ;;
  esac
}

assert_status_nonzero() {
  [ "$STATUS" -ne 0 ] || fail "expected installer to fail, but it exited 0"
}

assert_status_zero() {
  [ "$STATUS" -eq 0 ] || {
    printf '%s\n' "$OUTPUT" >&2
    fail "expected installer to succeed, but it exited $STATUS"
  }
}

setup_case() {
  CASE_DIR="$WORK_ROOT/$1"
  STUB_BIN="$CASE_DIR/stub-bin"
  PREFIX="$CASE_DIR/prefix"
  HOME_DIR="$CASE_DIR/home"
  PAYLOAD_DIR="$CASE_DIR/payload"
  FIXTURE_ARTIFACT="$CASE_DIR/copilot-linux-x64.tar.gz"
  FIXTURE_MANIFEST="$CASE_DIR/SHA256SUMS.txt"
  GIT_ARGS_LOG="$CASE_DIR/git-args.log"
  GIT_LS_REMOTE_OUTPUT="$CASE_DIR/git-ls-remote.txt"

  mkdir -p "$STUB_BIN" "$PREFIX/bin" "$HOME_DIR" "$PAYLOAD_DIR"

  cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
set -u
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    -H|--header)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

[ -n "$out" ] || exit 2
case "$url" in
  *SHA256SUMS.txt)
    [ "${CURL_FAIL_MANIFEST:-0}" != "1" ] || exit 22
    cp "$FIXTURE_MANIFEST" "$out"
    ;;
  *)
    cp "$FIXTURE_ARTIFACT" "$out"
    ;;
esac
STUB
  chmod +x "$STUB_BIN/curl"

  unset TEST_GITHUB_TOKEN CURL_FAIL_MANIFEST
  TEST_VERSION="vtest"
}

make_regular_archive() {
  printf '%s\n' "${1:-new-binary}" > "$PAYLOAD_DIR/copilot"
  chmod +x "$PAYLOAD_DIR/copilot"
  tar -czf "$FIXTURE_ARTIFACT" -C "$PAYLOAD_DIR" copilot
}

make_archive_without_binary() {
  printf '%s\n' "not-the-binary" > "$PAYLOAD_DIR/README"
  tar -czf "$FIXTURE_ARTIFACT" -C "$PAYLOAD_DIR" README
}

make_symlink_archive() {
  ln -s /bin/sh "$PAYLOAD_DIR/copilot"
  tar -czf "$FIXTURE_ARTIFACT" -C "$PAYLOAD_DIR" copilot
}

write_manifest_once() {
  hash="$(sha256sum "$FIXTURE_ARTIFACT" | awk '{print $1}')"
  printf '%s  %s\n' "$hash" "$(basename "$FIXTURE_ARTIFACT")" > "$FIXTURE_MANIFEST"
}

run_installer() {
  set +e
  OUTPUT="$({
    PATH="$STUB_BIN:$PREFIX/bin:$BASE_PATH" \
    PREFIX="$PREFIX" \
    HOME="$HOME_DIR" \
    SHELL=/bin/bash \
    VERSION="$TEST_VERSION" \
    GITHUB_TOKEN="${TEST_GITHUB_TOKEN:-}" \
    CURL_FAIL_MANIFEST="${CURL_FAIL_MANIFEST:-0}" \
    FIXTURE_ARTIFACT="$FIXTURE_ARTIFACT" \
    FIXTURE_MANIFEST="$FIXTURE_MANIFEST" \
    GIT_ARGS_LOG="$GIT_ARGS_LOG" \
    GIT_LS_REMOTE_OUTPUT="$GIT_LS_REMOTE_OUTPUT" \
    bash "$INSTALLER"
  } 2>&1)"
  STATUS=$?
  set -e
}

test_rejects_duplicate_checksum_entries() {
  setup_case duplicate-checksums
  make_regular_archive
  write_manifest_once
  cat "$FIXTURE_MANIFEST" >> "$FIXTURE_MANIFEST"

  run_installer
  assert_status_nonzero || return 1
  assert_contains "$OUTPUT" "Found 2 checksum entries" || return 1
  [ ! -e "$PREFIX/bin/copilot" ] || fail "installer wrote a binary after ambiguous checksum failure"
}

test_missing_archive_binary_cannot_reuse_stale_install() {
  setup_case stale-binary
  printf '%s\n' old-binary > "$PREFIX/bin/copilot"
  chmod +x "$PREFIX/bin/copilot"
  make_archive_without_binary
  write_manifest_once

  run_installer
  assert_status_nonzero || return 1
  assert_contains "$OUTPUT" "did not contain a regular top-level copilot binary" || return 1
  [ "$(cat "$PREFIX/bin/copilot")" = "old-binary" ] || fail "existing binary was modified on failed install"
}

test_rejects_symlink_binary() {
  setup_case symlink-binary
  make_symlink_archive
  write_manifest_once

  run_installer
  assert_status_nonzero || return 1
  assert_contains "$OUTPUT" "did not contain a regular top-level copilot binary" || return 1
}

test_rejects_missing_checksum_manifest() {
  setup_case missing-manifest
  make_regular_archive
  write_manifest_once
  CURL_FAIL_MANIFEST=1

  run_installer
  assert_status_nonzero || return 1
  assert_contains "$OUTPUT" "refusing an unverified install" || return 1
  [ ! -e "$PREFIX/bin/copilot" ] || fail "installer wrote a binary without checksum verification"
}

test_installs_uniquely_verified_binary() {
  setup_case verified-install
  make_regular_archive verified-binary
  write_manifest_once

  run_installer
  assert_status_zero || return 1
  [ -x "$PREFIX/bin/copilot" ] || fail "installed binary is not executable"
  [ "$(cat "$PREFIX/bin/copilot")" = "verified-binary" ] || fail "installed binary content does not match verified artifact"
}

test_unsupported_os_never_falls_through_to_winget() {
  setup_case unsupported-os
  WINGET_LOG="$CASE_DIR/winget.log"
  cat > "$STUB_BIN/uname" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' FreeBSD ;;
  -m) printf '%s\n' x86_64 ;;
  *) printf '%s\n' FreeBSD ;;
esac
STUB
  cat > "$STUB_BIN/winget" <<STUB
#!/usr/bin/env bash
printf '%s\n' called > "$WINGET_LOG"
exit 0
STUB
  chmod +x "$STUB_BIN/uname" "$STUB_BIN/winget"

  run_installer
  assert_status_nonzero || return 1
  assert_contains "$OUTPUT" "Unsupported operating system FreeBSD" || return 1
  [ ! -e "$WINGET_LOG" ] || fail "winget was invoked for an unsupported non-Windows OS"
}

test_prerelease_git_arguments_do_not_expose_token() {
  setup_case token-hygiene
  make_regular_archive verified-binary
  write_manifest_once
  TEST_VERSION="prerelease"
  TEST_GITHUB_TOKEN="supersecret-test-token"

  cat > "$GIT_LS_REMOTE_OUTPUT" <<'REFS'
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	refs/tags/v1.0.0
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	refs/tags/v1.1.0-beta.1
cccccccccccccccccccccccccccccccccccccccc	refs/tags/v1.1.0
REFS
  cat > "$STUB_BIN/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$GIT_ARGS_LOG"
cat "$GIT_LS_REMOTE_OUTPUT"
STUB
  chmod +x "$STUB_BIN/git"

  run_installer
  assert_status_zero || return 1
  args="$(cat "$GIT_ARGS_LOG")"
  assert_not_contains "$args" "$TEST_GITHUB_TOKEN" || return 1
  assert_contains "$OUTPUT" "Latest prerelease version: v1.1.0-beta.1" || return 1
}

run_test() {
  name="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name"
    FAILURES=$((FAILURES + 1))
  fi
}

run_test "duplicate checksum entries are rejected" test_rejects_duplicate_checksum_entries
run_test "stale installed binary cannot mask malformed archive" test_missing_archive_binary_cannot_reuse_stale_install
run_test "symlink copilot payload is rejected" test_rejects_symlink_binary
run_test "missing checksum manifest is fatal" test_rejects_missing_checksum_manifest
run_test "uniquely verified binary installs successfully" test_installs_uniquely_verified_binary
run_test "unsupported OS does not fall through to winget" test_unsupported_os_never_falls_through_to_winget
run_test "prerelease git arguments do not expose GITHUB_TOKEN" test_prerelease_git_arguments_do_not_expose_token

if [ "$FAILURES" -ne 0 ]; then
  printf '%s\n' "$FAILURES installer regression test(s) failed" >&2
  exit 1
fi

printf '%s\n' "all installer regression tests passed"
