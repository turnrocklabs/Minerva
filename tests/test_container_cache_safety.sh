#!/usr/bin/env bash
# Regression test for the container test/build caches' no-delete, no-clobber
# guarantees (Target 1 01a0c71330d8; design reviewed in docket comments
# 2012-2027). Run: bash tests/test_container_cache_safety.sh
#
# Covers: cache-root validation (shell and Python agree), the in-container
# overlay path check, publish.py's collision matrix (absent / matching /
# file / empty dir / mismatched / exec-bit / symlink destinations, ENOENT,
# EXDEV, unsupported renameat2), a real two-process publish race, check-git
# tamper detection, build.py's publish/verify_entry/keep_failed contract,
# build.py mount-rows (whole-or-nothing rows) and container-test.sh's
# fail_before_container evidence.
#
# It never runs docker, a build, Godot or any delete: a stub `docker` first on
# PATH fails any call, and the fixtures (a fresh mktemp -d under ${TMPDIR:-/tmp})
# are LEFT BEHIND for inspection — by the owner's no-script-delete policy;
# ordinary temp-dir cleanup reclaims them. The one outside path it names is a
# non-existent /dev/shm probe used to provoke EXDEV; it asserts the probe was
# never created (that check needs /dev/shm on a different filesystem than
# $TMPDIR, true on this Linux setup).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${TMPDIR:-/tmp}"
PUB=(python3 -B "$REPO/scripts/container-build/publish.py")
S="$(mktemp -d "$SCRATCH/minerva-cache-safety.XXXXXX")" || exit 1
echo "fixtures: $S"
pass=0 fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
# check LABEL CONDITION: CONDITION is eval'd inside check, so it must name
# variables, never positional parameters ("$2" there is CONDITION itself).
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# tally LABEL EXPECTED OUT RC: fold an embedded Python block's PASS/FAIL lines
# into the totals; a non-zero exit (e.g. a traceback) or a PASS count other than
# EXPECTED is a FAIL of its own.
tally() {
	local label="$1" expected="$2" out="$3" rc="$4" np nf
	echo "$out"
	np="$(grep -c '^PASS' <<< "$out")"; nf="$(grep -c '^FAIL' <<< "$out")"
	pass=$((pass + np)); fail=$((fail + nf))
	[[ $rc -eq 0 ]] || bad "$label: python exited $rc"
	[[ $np -eq $expected ]] || bad "$label: expected $expected PASS lines, got $np"
}
# snap PATH: type, mode, inode, size and mtime of PATH itself plus its tree,
# never following links — "unchanged" means byte-for-byte and inode-for-inode.
snap() { find "$1" -printf '%P|%y|%m|%i|%s|%T@|%l\n' 2>/dev/null | sort | sha256sum; }

# ── fixtures ──────────────────────────────────────────────────────────────
mkdir -p "$S/stubs" "$S/outside/data" "$S/realcache" "$S/work/src/existing" "$S/cache" "$S/srcdir/sub/empty"
printf '#!/bin/sh\necho called >> "%s/docker-called"\nexit 99\n' "$S" > "$S/stubs/docker"
chmod +x "$S/stubs/docker"
export PATH="$S/stubs:$PATH"
echo keep > "$S/outside/data/sentinel"
echo x > "$S/work/src/file"
echo lib > "$S/srcdir/sub/lib.so"
printf '#!/bin/sh\n' > "$S/srcdir/run.sh" && chmod +x "$S/srcdir/run.sh"
ln -s sub/lib.so "$S/srcdir/link"
echo helper > "$S/srcfile"
ln -s "$S/realcache" "$S/linkroot"
ln -s "$S/outside" "$S/work/src/escape"
outside_before="$(snap "$S/outside"; snap "$S/realcache")"
# stage NAME: a fresh private copy of srcdir, as the scripts stage one.
stage() { local d; d="$(mktemp -d "$S/cache/$1.stage.XXXXXX")" && cp -a "$S/srcdir" "$d/entry" && echo "$d/entry"; }

# ── 1. cache root validation (unchanged contract; both implementations) ──
expect_sh() {
	local out
	out="$(env MINERVA_CT_CACHE="$1" "$REPO/scripts/container-test.sh" prune 2>&1)"
	if [[ $? -eq 2 && "$out" =~ $2 ]]; then ok "sh root '$1' -> /$2/"; else bad "sh root '$1': expected /$2/, got: $out"; fi
}
expect_py() {
	local out
	out="$(env MINERVA_CT_CACHE="$1" python3 -B - "$REPO/scripts/container-build/build.py" <<'EOF' 2>&1
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("container_build", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("accepted", module.cache_root())
EOF
)"
	if [[ "$out" =~ $2 ]]; then ok "py root '$1' -> /$2/"; else bad "py root '$1': expected /$2/, got: $out"; fi
}
for impl in sh py; do
	expect_$impl "" "must be an absolute path"
	expect_$impl "relative/cache" "must be an absolute path"
	expect_$impl "/" "refusing cache root /"
	expect_$impl "$HOME" "too broad"
	expect_$impl "$(dirname "$HOME")" "too broad"
	expect_$impl "$REPO" "too broad"
	expect_$impl "$(dirname "$REPO")" "too broad"
	expect_$impl "$S/linkroot" "is a symlink"
	expect_$impl "$S/linkroot/" "is a symlink"
	expect_$impl "$S/linkroot//" "is a symlink"
done
expect_sh "$S/newcache" "automatic reclamation is disabled"
expect_py "$S/newcache" "accepted $S/newcache"
check "validation created no cache dir" '[[ ! -e "$S/newcache" ]]'

# ── 2. overlay_path_ok (unchanged contract) ──
overlay_fn="$(sed -n '/^overlay_path_ok() {/,/^}/p' "$REPO/scripts/container-test/in-container.sh")"
check_overlay() {
	( WORK="$S/work"; eval "$overlay_fn"; overlay_path_ok "$1" ) 2>/dev/null
	local rc=$?
	if [[ ( "$2" == accept && $rc -eq 0 ) || ( "$2" == refuse && $rc -ne 0 ) ]]; then ok "overlay '$1' -> $2"
	else bad "overlay '$1': expected $2, rc $rc"; fi
}
for p in "/abs/x" "src/../x" "src//x" "./src/x" "src/x/" "." "" \
		"src/escape/sentinel" "src/escape/data/new" "src/file/x" "src/existing" "src/file"; do
	check_overlay "$p" refuse
done
check_overlay "src/new/lib.so" accept
check_overlay "src/bin/libterminal.so" accept
check "overlay checks wrote nothing" '[[ ! -e "$S/work/src/new" && ! -e "$S/work/src/bin" ]]'

# ── 3. publish.py CLI: the collision matrix ──
digest="$("${PUB[@]}" digest "$S/srcdir")"
check "digest is 64 hex" '[[ "$digest" =~ ^[0-9a-f]{64}$ ]]'
# absent destination -> published, read-only, identical, staged path consumed
e="$(stage absent)"; out="$("${PUB[@]}" publish "$e" "$S/cache/absent" 2>&1)"; rc=$?
check "absent dest: published (rc 0)" '[[ $rc -eq 0 && "$out" == published* ]]'
check "absent dest: identical digest" '[[ "$("${PUB[@]}" digest "$S/cache/absent")" == "$digest" ]]'
check "absent dest: read-only (top + file)" '[[ ! -w "$S/cache/absent" && ! -w "$S/cache/absent/sub/lib.so" ]]'
check "absent dest: exec bit and link text kept" '[[ -x "$S/cache/absent/run.sh" && "$(readlink "$S/cache/absent/link")" == sub/lib.so ]]'
check "absent dest: empty dir kept" '[[ -d "$S/cache/absent/sub/empty" ]]'
check "absent dest: staged path consumed" '[[ ! -e "$e" ]]'
# matching winner -> accepted without replacement, source kept
before="$(snap "$S/cache/absent")"; e="$(stage match)"
out="$("${PUB[@]}" publish "$e" "$S/cache/absent" 2>&1)"; rc=$?
check "matching winner: accepted (rc 0, reported)" '[[ $rc -eq 0 && "$out" == *"already published identically"* ]]'
check "matching winner: dest unchanged (inodes, mtimes)" '[[ "$(snap "$S/cache/absent")" == "$before" ]]'
check "matching winner: staged copy kept" '[[ -d "$e" ]]'
# refused collisions: dest unchanged, source kept, rc 3
refuse_case() {  # refuse_case LABEL DEST
	local label="$1" d="$2" e before out rc
	e="$(stage "refuse")"; before="$(snap "$d")"
	out="$("${PUB[@]}" publish "$e" "$d" 2>&1)"; rc=$?
	check "$label: refused (rc 3)" '[[ $rc -eq 3 && "$out" == *refused* ]]'
	check "$label: dest unchanged" '[[ "$(snap "$d")" == "$before" ]]'
	check "$label: staged copy kept" '[[ -d "$e" ]]'
}
echo wrong > "$S/cache/wrongfile"; refuse_case "regular file at dest" "$S/cache/wrongfile"
mkdir "$S/cache/emptydir"; refuse_case "empty dir at dest" "$S/cache/emptydir"
cp -a "$S/srcdir" "$S/cache/mismatch" && echo changed > "$S/cache/mismatch/sub/lib.so"; refuse_case "mismatched dir at dest" "$S/cache/mismatch"
cp -a "$S/srcdir" "$S/cache/execflip" && chmod -x "$S/cache/execflip/run.sh"; refuse_case "exec-bit-only mismatch" "$S/cache/execflip"
ln -s "$S/outside" "$S/cache/linkdest"; refuse_case "symlink at dest" "$S/cache/linkdest"
check "symlink at dest: its target untouched" '[[ "$(snap "$S/outside"; snap "$S/realcache")" == "$outside_before" ]]'
# non-collision errors are explicit and never reported as success
e="$(stage enoent)"; out="$("${PUB[@]}" publish "$e" "$S/cache/no-such-parent/x" 2>&1)"; rc=$?
check "missing parent: explicit error (rc 3, ENOENT)" '[[ $rc -eq 3 && "$out" == *ENOENT* ]]'
check "missing parent: staged copy kept" '[[ -d "$e" ]]'
probe="/dev/shm/minerva-exdev-probe-$(basename "$S")"
e="$(stage exdev)"; out="$("${PUB[@]}" publish "$e" "$probe" 2>&1)"; rc=$?
check "cross-device: explicit error (rc 3, EXDEV), no fallback" '[[ $rc -eq 3 && "$out" == *EXDEV* ]]'
check "cross-device: probe never created" '[[ ! -e "$probe" && ! -L "$probe" ]]'
check "cross-device: staged copy kept" '[[ -d "$e" ]]'
# check / check-git
check "check: matching digest passes" '"${PUB[@]}" check "$S/cache/absent" "$digest"'
check "check: wrong digest refused" '! "${PUB[@]}" check "$S/cache/mismatch" "$digest" 2>/dev/null'

# ── 4. unsupported renameat2 (isolated stubs; not real-filesystem coverage) ──
out="$(python3 -B - "$REPO/scripts/container-build" "$S" <<'EOF' 2>&1
import ctypes, errno, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import publish
class NoSymbol:
    pass
class Fails:
    def __init__(self, err): self.err = err
    @property
    def renameat2(self):
        err = self.err
        def call(*args):
            ctypes.set_errno(err)
            return -1
        return call
src = os.path.join(sys.argv[2], "srcfile")
for label, fake, want in [("no libc symbol", NoSymbol(), "no renameat2"),
                          ("EINVAL", Fails(errno.EINVAL), "unsupported"),
                          ("ENOSYS", Fails(errno.ENOSYS), "unsupported"),
                          ("EOPNOTSUPP", Fails(errno.EOPNOTSUPP), "unsupported")]:
    publish.ctypes.CDLL = lambda *a, fake=fake, **k: fake
    try:
        publish.rename_noreplace(src, src + ".never")
        print(f"FAIL: stub {label}: returned instead of refusing")
    except publish.PublishError as e:
        good = want in str(e) and os.path.exists(src) and not os.path.exists(src + ".never")
        print(("PASS" if good else "FAIL") + f": stub {label}: refused, nothing moved ({e})")
EOF
)"
tally "stub block" 4 "$out" $?

# ── 5. two concurrent publishers of the same entry (real processes) ──
e1="$(stage race)"; e2="$(stage race)"
"${PUB[@]}" publish "$e1" "$S/cache/race" > "$S/race1.out" 2>&1 & p1=$!
"${PUB[@]}" publish "$e2" "$S/cache/race" > "$S/race2.out" 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
published="$(cat "$S/race1.out" "$S/race2.out" | grep -c '^published')"
identical="$(cat "$S/race1.out" "$S/race2.out" | grep -c 'already published identically')"
check "race: both exit 0" '[[ $r1 -eq 0 && $r2 -eq 0 ]]'
check "race: exactly one published, one accepted as identical" '[[ $published -eq 1 && $identical -eq 1 ]]'
check "race: dest verifies" '"${PUB[@]}" check "$S/cache/race" "$digest"'
check "race: the loser staged copy kept" '[[ -d "$e1" || -d "$e2" ]] && ! [[ -d "$e1" && -d "$e2" ]]'

# ── 6. container-test.sh's publish wrapper (extracted), onto fixtures ──
fns="$(sed -n '/^die() {/p; /^PUBLISH=/p; /^publish() {/p' "$REPO/scripts/container-test.sh")"
run_fn() { ( REPO_ROOT="$REPO"; eval "$fns"; "$@" ); }
e="$(stage wrap)"; run_fn publish "$e" "$S/cache/wrapped" > /dev/null; rc=$?
check "sh publish: new entry published" '[[ $rc -eq 0 && "$("${PUB[@]}" digest "$S/cache/wrapped")" == "$digest" ]]'
before="$(snap "$S/cache/wrapped")"; e="$(stage wrap)"
run_fn publish "$e" "$S/cache/wrapped" > /dev/null 2>&1; rc=$?
check "sh publish: identical winner accepted, unchanged" '[[ $rc -eq 0 && "$(snap "$S/cache/wrapped")" == "$before" ]]'
before="$(snap "$S/cache/mismatch")"; e="$(stage wrap)"
run_fn publish "$e" "$S/cache/mismatch" > /dev/null 2>&1; rc=$?
check "sh publish: mismatched winner dies, unchanged" '[[ $rc -ne 0 && "$(snap "$S/cache/mismatch")" == "$before" && -d "$e" ]]'

# ── 7. check-git against a throwaway repo in the fixtures ──
G="$S/gitrepo"; mkdir -p "$G/dir/nested"
echo a > "$G/a.txt"; echo n > "$G/dir/nested/n.txt"; printf '#!/bin/sh\n' > "$G/run.sh"; chmod +x "$G/run.sh"; ln -s a.txt "$G/alink"
git -C "$G" init -q && git -C "$G" add -A && git -C "$G" -c user.name=h -c user.email=h@h commit -qm fixture
gsha="$(git -C "$G" rev-parse HEAD)"
mkdir "$S/arch" && git -C "$G" archive "$gsha" | tar -x -C "$S/arch"
check "check-git: exact archive passes" '"${PUB[@]}" check-git "$S/arch" "$G" "$gsha"'
tamper() {  # tamper LABEL SHELL-EDIT
	local d="$S/tamper-$1"
	cp -a "$S/arch" "$d" && ( cd "$d" && eval "$2" )
	check "check-git: $1 refused" '! "${PUB[@]}" check-git "$d" "$G" "$gsha" 2>/dev/null'
}
tamper extra-file 'echo x > extra.txt'
tamper extra-empty-dir 'mkdir extra'
tamper changed-content 'chmod u+w a.txt && echo b > a.txt'
tamper exec-flip 'chmod -x run.sh'
tamper link-retarget 'mv alink alink.orig && ln -s dir alink'
tamper missing-file 'mv dir/nested/n.txt ../moved-n-$RANDOM.txt'

# ── 8. build.py: no-clobber publish, strict verify_entry, keep_failed ──
check "build.py never touches an entry's mtime (no os.utime)" '! grep -q "os.utime" "$REPO/scripts/container-build/build.py"'
check "container-test.sh never touches an entry (no touch)" '! grep -qE "^[[:space:]]*touch " "$REPO/scripts/container-test.sh"'
out="$(python3 -B - "$REPO/scripts/container-build/build.py" "$S/pybuild" <<'EOF' 2>&1
import importlib.util, json, os, shutil, sys, tempfile
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("container_build", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
comp = Path(sys.argv[2]) / "builds" / "comp"
comp.mkdir(parents=True)
recipe = {"inputs": [], "submodules": [], "command": "true", "outputs": ["a.txt"]}

def work(key, content="a\n"):
    w = Path(tempfile.mkdtemp(prefix=f".tmp-{key}-", dir=comp))
    (w / "files").mkdir()
    (w / "files" / "a.txt").write_text(content)
    (w / "toolchain.txt").write_text("zig test\n")
    return w

def state(path):
    """lstat of every entry under path, never following links."""
    out = []
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in [""] + dirs + files:
            full = os.path.join(root, name) if name else root
            st = os.lstat(full)
            out.append((full, st.st_mode, st.st_ino, st.st_size, st.st_mtime_ns))
    return sorted(out)

def entry(name, key, outputs_types, build_files, provenance=None):
    """A hand-made, unpublished entry: files/ built by build_files(files)."""
    e = comp / name
    (e / "files").mkdir(parents=True)
    build_files(e / "files")
    prov = provenance if provenance is not None else {
        "key": key, "output_types": outputs_types,
        "files_digest": m.tree_digest(str(e / "files"))}
    (e / "provenance.json").write_text(json.dumps(prov))
    return e

checks = {}
w = work("k1"); dest = comp / "k1"
m.publish("comp", recipe, "0" * 40, "k1", {}, ("tag", "id"), "t0", w, dest)
checks["publish: published, work gone"] = dest.is_dir() and not w.exists()
checks["publish: read-only"] = not os.access(dest, os.W_OK) and not os.access(dest / "files" / "a.txt", os.W_OK)
checks["publish: output_types recorded"] = json.loads((dest / "provenance.json").read_text())["output_types"] == {"a.txt": "file"}
checks["verify_entry: own key"] = m.verify_entry(dest, "k1", recipe)
checks["verify_entry: foreign key"] = not m.verify_entry(dest, "k2", recipe)
checks["verify_entry: missing entry"] = not m.verify_entry(comp / "absent", "k1", recipe)
checks["verify_entry: missing declared output"] = not m.verify_entry(dest, "k1", {**recipe, "outputs": ["b.txt"]})

# Symlinked dest pointing at a valid entry: refused, target untouched.
before = state(dest)
os.symlink("k1", comp / "k1link")
checks["verify_entry: symlink dest refused"] = not m.verify_entry(comp / "k1link", "k1", recipe)
checks["verify_entry: symlink dest target untouched"] = state(dest) == before
# Symlinked files/ root.
real = comp / "realfiles"; real.mkdir(); (real / "a.txt").write_text("a\n")
e = comp / "e-files-link"; e.mkdir(); os.symlink("../realfiles", e / "files")
(e / "provenance.json").write_text(json.dumps({"key": "k6", "output_types": {"a.txt": "file"},
                                               "files_digest": m.tree_digest(str(real))}))
checks["verify_entry: symlink files/ refused"] = not m.verify_entry(e, "k6", recipe)
# Symlinked provenance.json.
e = comp / "e-prov-link"; (e / "files").mkdir(parents=True); (e / "files" / "a.txt").write_text("a\n")
(comp / "prov-real.json").write_text(json.dumps({"key": "k7", "output_types": {"a.txt": "file"},
                                                 "files_digest": m.tree_digest(str(e / "files"))}))
os.symlink("../prov-real.json", e / "provenance.json")
checks["verify_entry: symlink provenance refused"] = not m.verify_entry(e, "k7", recipe)
# Missing files root: False, not an exception.
e = comp / "e-no-files"; e.mkdir(); (e / "provenance.json").write_text(json.dumps({"key": "k8"}))
checks["verify_entry: missing files root refused"] = not m.verify_entry(e, "k8", recipe)
# Non-object provenance.
e = entry("e-prov-list", "k9", {}, lambda f: (f / "a.txt").write_text("a\n"), provenance=[1, 2])
checks["verify_entry: non-object provenance refused"] = not m.verify_entry(e, "k9", recipe)
# dest is a regular file.
(comp / "e-file").write_text("x")
checks["verify_entry: regular-file dest refused"] = not m.verify_entry(comp / "e-file", "k1", recipe)
# Dangling declared output (digest otherwise consistent).
e = entry("e-dangling", "k10", {"a.txt": "file"}, lambda f: (f / "b.txt").write_text("b\n"))
checks["verify_entry: missing output refused"] = not m.verify_entry(e, "k10", recipe)
def dangling_link(f):
    (f / "b.txt").write_text("b\n"); os.symlink("nowhere", f / "a.txt")
e = entry("e-dangling-link", "k11", {"a.txt": "symlink"}, dangling_link)
checks["verify_entry: dangling symlink output refused"] = not m.verify_entry(e, "k11", recipe)
# Escaping and absolute symlinks anywhere in files/.
def escaping(f):
    (f / "a.txt").write_text("a\n"); os.symlink("../../realfiles/a.txt", f / "lib.so")
e = entry("e-escape", "k12", {"a.txt": "file"}, escaping)
checks["verify_entry: escaping symlink refused"] = not m.verify_entry(e, "k12", recipe)
def absolute(f):
    (f / "a.txt").write_text("a\n"); os.symlink("/etc/hostname", f / "lib.so")
e = entry("e-absolute", "k13", {"a.txt": "file"}, absolute)
checks["verify_entry: absolute symlink refused"] = not m.verify_entry(e, "k13", recipe)
# Declared output reached through an intermediate (contained) symlink.
def intermediate(f):
    (f / "realsub").mkdir(); (f / "realsub" / "a.txt").write_text("a\n"); os.symlink("realsub", f / "sub")
e = entry("e-intermediate", "k14", {"sub/a.txt": "file"}, intermediate)
checks["verify_entry: output via intermediate symlink refused"] = not m.verify_entry(e, "k14", {**recipe, "outputs": ["sub/a.txt"]})
# output_types schema: must be a dict, and each declared output recorded as
# file/dir (a self-consistent "missing" must not verify).
e = entry("e-types-list", "k17", ["a.txt"], lambda f: (f / "a.txt").write_text("a\n"))
checks["verify_entry: list output_types refused"] = not m.verify_entry(e, "k17", recipe)
e = entry("e-types-missing", "k18", {"a.txt": "missing"}, lambda f: (f / "b.txt").write_text("b\n"))
checks["verify_entry: recorded 'missing' output refused"] = not m.verify_entry(e, "k18", recipe)
# Contained library-style link chain is accepted.
def library(f):
    (f / "libfoo.so.1.2").write_text("elf\n"); os.symlink("libfoo.so.1.2", f / "libfoo.so.1")
    os.symlink("libfoo.so.1", f / "libfoo.so")
e = entry("e-library", "k15", {"libfoo.so.1.2": "file"}, library)
checks["verify_entry: contained library link chain accepted"] = m.verify_entry(e, "k15", {**recipe, "outputs": ["libfoo.so.1.2"]})
# publish() refuses a build whose output escapes via a symlink; work kept, dest absent.
wb = work("k16"); os.symlink("/etc/hostname", wb / "files" / "bad")
try:
    m.publish("comp", recipe, "0" * 40, "k16", {}, ("tag", "id"), "t0", wb, comp / "k16")
    checks["publish: escaping build output refused"] = False
except m.PublishError:
    checks["publish: escaping build output refused"] = True
checks["publish: refused build kept, dest absent"] = wb.exists() and not os.path.lexists(comp / "k16")
# A foreign entry at dest (unverifiable) must be refused, both kept.
foreign = comp / "k3"; foreign.mkdir(); (foreign / "junk").write_text("x")
w3 = work("k3")
try:
    m.publish("comp", recipe, "0" * 40, "k3", {}, ("tag", "id"), "t0", w3, foreign)
    checks["publish onto foreign entry: refused"] = False
except m.PublishError:
    checks["publish onto foreign entry: refused"] = True
checks["publish onto foreign entry: both kept"] = (foreign / "junk").read_text() == "x" and w3.exists()
# Tampered files/ (digest mismatch) fails verification.
t = work("k4"); m.publish("comp", recipe, "0" * 40, "k4", {}, ("tag", "id"), "t0", t, comp / "k4")
tampered = comp / "k4-copy"
shutil.copytree(comp / "k4", tampered, symlinks=True)
for root, dirs, files in os.walk(tampered):
    os.chmod(root, 0o755)
    for name in files:
        os.chmod(os.path.join(root, name), 0o644)
(tampered / "files" / "a.txt").write_text("z\n")
checks["verify_entry: tampered output refused"] = not m.verify_entry(tampered, "k4", recipe)
# keep_failed never overwrites an existing retained failure.
f1 = work("k5"); (f1 / "build.log").write_text("first\n")
kept = m.keep_failed(f1, "k5", "20260922T000000Z")
checks["keep_failed: renamed, log intact"] = not f1.exists() and (kept / "build.log").read_text() == "first\n"
f2 = work("k5")
collide = f2.with_name(f".failed-k5-20260922T000000Z-{f2.name.rsplit('-', 1)[-1]}")
collide.mkdir(); (collide / "marker").write_text("old\n")
kept2 = m.keep_failed(f2, "k5", "20260922T000000Z")
checks["keep_failed: collision leaves both"] = kept2 == f2 and f2.exists() and (collide / "marker").read_text() == "old\n"
for name, good in checks.items():
    print(("PASS" if good else "FAIL") + ": build.py " + name)
EOF
)"
tally "build.py block" 29 "$out" $?  # 27 unique v3 keys + 2 schema cases

# ── 9. mount-rows is whole-or-nothing; fail_before_container leaves evidence ──
MR="$S/mountrows"
out="$(python3 -B - "$REPO/scripts/container-build/build.py" "$MR" <<'EOF' 2>&1
import importlib.util, json, sys, tempfile
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("container_build", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = Path(sys.argv[2])
components = {}
for name in ("json-schema-helper", "addons"):  # real recipes, fake bytes
    recipe = m.RECIPES[name]
    comp = root / "builds" / name
    comp.mkdir(parents=True)
    work = Path(tempfile.mkdtemp(prefix=".tmp-k-", dir=comp))
    for out in recipe["outputs"]:
        target = work / "files" / out
        if name == "addons":
            target.mkdir(parents=True)
            (target / "lib.so").write_text("so\n")
        else:
            target.parent.mkdir(parents=True)
            target.write_text("helper\n")
    (work / "toolchain.txt").write_text("test\n")
    m.publish(name, recipe, "0" * 40, f"key-{name}", {}, ("tag", "id"), "t0", work, comp / f"key-{name}")
    components[name] = {"key": f"key-{name}", "cache_hit": False, "dir": str(comp / f"key-{name}"),
                        "outputs": recipe["outputs"]}
(root / "good.json").write_text(json.dumps({"components": components}))
broken = dict(components)
empty = root / "builds" / "addons" / "no-provenance"; (empty / "files").mkdir(parents=True)
broken["addons"] = {**components["addons"], "dir": str(empty)}
(root / "bad-entry.json").write_text(json.dumps({"components": broken}))
print("PASS: fixtures for mount-rows built")
EOF
)"
tally "mount-rows fixtures" 1 "$out" $?
rows() {  # rows MANIFEST PROVDIR: run mount-rows; sets rc, rows_out
	rows_out="$("${BUILD_PY[@]}" mount-rows --manifest "$1" --provenance-dir "$2" 2>/dev/null)"; rc=$?
}
BUILD_PY=(python3 -B "$REPO/scripts/container-build/build.py")
mkdir -p "$MR/prov-good" "$MR/prov-bad" "$MR/prov-collide"
rows "$MR/good.json" "$MR/prov-good"
check "mount-rows: valid manifest -> rc 0, 3 rows" '[[ $rc -eq 0 && "$(wc -l <<< "$rows_out")" -eq 3 ]]'
check "mount-rows: rows name entry files/<output> -> <output>" '[[ "$rows_out" == *"/builds/addons/key-addons/files/src/addons/ffmpeg/linux64	src/addons/ffmpeg/linux64"* ]]'
check "mount-rows: provenance copied per component" '[[ -f "$MR/prov-good/addons.json" && -f "$MR/prov-good/json-schema-helper.json" ]]'
rows "$MR/bad-entry.json" "$MR/prov-bad"
check "mount-rows: bad entry after a valid one -> rc 3, NO rows" '[[ $rc -eq 3 && -z "$rows_out" ]]'
check "mount-rows: bad entry -> no provenance copied" '[[ -z "$(ls -A "$MR/prov-bad")" ]]'
echo existing > "$MR/prov-collide/addons.json"
rows "$MR/good.json" "$MR/prov-collide"
check "mount-rows: copy fails after first copy -> rc 3, NO rows" '[[ $rc -eq 3 && -z "$rows_out" ]]'
check "mount-rows: existing provenance file not overwritten" '[[ "$(cat "$MR/prov-collide/addons.json")" == existing ]]'
# fail_before_container, extracted and run against a fixture results dir.
fbc="$(sed -n '/^fail_before_container() {/,/^}/p' "$REPO/scripts/container-test.sh")"
FB="$S/failjob"; mkdir -p "$FB/logs"
( TOOLS_DIR="$REPO/scripts/container-test"; eval "$fbc"; fail_before_container "$FB" 1 native-build deadbeef job9 test/a.gd app-smoke ) > /dev/null 2>&1; rc=$?
check "fail_before_container: exits with its rc" '[[ $rc -eq 1 && "$(cat "$FB/exit_code")" == 1 ]]'
check "fail_before_container: results.json not green, stage failed, suites not_run" 'python3 -c "import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if (not r[\"green\"] and r[\"failed_stages\"] == [\"native-build\"] and [x[\"verdict\"] for x in r[\"suites\"]] == [\"not_run\", \"not_run\"]) else 1)" "$FB/results.json"'
check "fail_before_container: run.json has job, revision, stage, accounting rc 1" 'python3 -c "import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if (r[\"job\"], r[\"revision\"], r[\"failed_stage\"], r[\"accounting_exit\"]) == (\"job9\", \"deadbeef\", \"native-build\", 1) else 1)" "$FB/run.json"'

# ── invariants ──
check "outside/ and realcache/ unchanged" '[[ "$(snap "$S/outside"; snap "$S/realcache")" == "$outside_before" ]]'
check "docker never called" '[[ ! -e "$S/docker-called" ]]'
echo "=== Results: $pass passed, $fail failed === (fixtures left at $S)"
(( fail == 0 && pass > 0 ))
