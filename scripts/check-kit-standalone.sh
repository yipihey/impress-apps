#!/usr/bin/env bash
# scripts/check-kit-standalone.sh: "the kit can leave" as a command (ADR-0033 D7,
# plan-wave-6 W6).
#
# Copies the kit crates (the table in docs/kit-manifest.md) plus impress-core,
# the kit's one allowed reach into this repository, into a scratch directory,
# gives them a workspace of their own and runs `cargo check` there. The scratch
# workspace contains nothing else from this repository. If a kit crate needs
# a crate that was not copied, this fails, whether or not check-kit-deps.sh
# was told about it.
#
# What the scratch workspace is:
#   * crates/<name> for each crate, the tracked and untracked-but-not-ignored
#     files only (no target/, no build products). The layout is kept because
#     impress-core's tests include_str! an impress-layout golden by relative
#     path.
#   * The real root Cargo.toml with `members` replaced by the copied set and
#     every [workspace.dependencies] path entry for an uncopied crate removed.
#     Everything else (registry versions, [workspace.package], profiles) is
#     the real file, so `workspace = true` resolves exactly as it does here.
#   * docs/<file> for each document a copied crate include_str!s (today the
#     kit's contract, docs/agent-surfaces.md, which a surface test parses).
#   * rust-toolchain.toml, .cargo/config.toml and Cargo.lock, so the pinned
#     compiler and the locked versions are the ones this repo builds with.
#
# Dependencies are held to two standards:
#   * A normal or build dependency on an uncopied workspace crate is a
#     failure, named before cargo runs.
#   * A dev-dependency on one (today: surface-demo-service -> imprint-core, for
#     one test) is dropped from the copy. That crate is then checked without
#     the targets that use it, and the output names them.
#
# Crates under the manifest's `kit-open-findings` block are left out and
# named. --strict keeps them in, so they fail the way they would if the kit
# really left.
#
# It never writes to the repository. The build goes to $CARGO_TARGET_DIR when
# set (CI points it at a persistent directory), otherwise to this checkout's
# own target/, where registry dependencies are shared with the normal build.
#
# Usage: scripts/check-kit-standalone.sh [--strict] [--keep]
#   --keep  leave the scratch workspace in place and print its path

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
export KIT_ROOT="$ROOT"
export KIT_STRICT=0 KIT_KEEP=0
for arg in "$@"; do
    case "$arg" in
        --strict) KIT_STRICT=1 ;;
        --keep) KIT_KEEP=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

exec python3 -u - <<'PY'
import os, re, shutil, subprocess, sys, tempfile, time, tomllib
from pathlib import Path

ROOT = Path(os.environ["KIT_ROOT"])
STRICT = os.environ["KIT_STRICT"] == "1"
KEEP = os.environ["KIT_KEEP"] == "1"
MANIFEST = ROOT / "docs" / "kit-manifest.md"
REACH = ["impress-core"]
# Feature passes a crate needs beyond --all-targets, applied only when the
# crate is in the scratch workspace (the FFI is what the apps link, with native).
EXTRA_FEATURES = {"impress-store-ffi": "native"}
DEP_SECTIONS = ("dependencies", "build-dependencies")


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def block(name):
    text = MANIFEST.read_text()
    m = re.search(rf"<!-- {name}:begin -->\n(.*?)<!-- {name}:end -->", text, re.S)
    if not m:
        fail(f"no {name} block in {MANIFEST.relative_to(ROOT)}")
    return m.group(1)


kit = [re.match(r"\| `([^`]+)`", l).group(1)
       for l in block("kit-crates").splitlines() if l.startswith("| `")]
findings = {}
for l in block("kit-open-findings").splitlines():
    m = re.match(r"- `([^`]+)`:(.*)", l)
    if m:
        findings[m.group(1)] = re.findall(r"`([^`]+)`", m.group(2))
if not kit:
    fail("the kit-crates table in docs/kit-manifest.md is empty")

left_out = [] if STRICT else [c for c in kit if c in findings]
members = [c for c in kit if c not in left_out] + REACH
member_set = set(members)

root_text = (ROOT / "Cargo.toml").read_text()
root = tomllib.loads(root_text)
ws_deps = root["workspace"]["dependencies"]


def crate_dir_name(path_str, base):
    """The workspace crate a path dependency points at, or None if outside crates/."""
    p = (base / path_str).resolve()
    try:
        rel = p.relative_to(ROOT)
    except ValueError:
        return None
    return tomllib.loads((ROOT / rel / "Cargo.toml").read_text())["package"]["name"], rel


def resolve(key, spec, crate_dir):
    """(package name, repo-relative dir) if this dependency is a path dependency."""
    if not isinstance(spec, dict):
        return None
    if spec.get("workspace"):
        root_spec = ws_deps.get(key)
        if isinstance(root_spec, dict) and "path" in root_spec:
            return crate_dir_name(root_spec["path"], ROOT)
        return None
    if "path" in spec:
        return crate_dir_name(spec["path"], crate_dir)
    return None


def sections(manifest):
    for s in DEP_SECTIONS + ("dev-dependencies",):
        yield s, manifest.get(s, {})
    for tgt, tbl in manifest.get("target", {}).items():
        for s in DEP_SECTIONS + ("dev-dependencies",):
            yield f"target.{tgt}.{s}", tbl.get(s, {})


print(f"kit (docs/kit-manifest.md): {' '.join(kit)}")
print(f"allowed reach, copied with it: {' '.join(REACH)}")
for c in left_out:
    print(f"LEFT OUT (open finding, ask-first, docs/kit-manifest.md): {c} reaches "
          f"{' '.join(findings[c])}; run with --strict to include it")

# --- the dependency census, before anything is copied -------------------------
errors, drops = [], {}  # drops: crate -> [(section, key, package)]
opt_drops = {}  # crate -> [(section, key, package)]: optional, out of kit
for c in members:
    cdir = ROOT / "crates" / c
    if not (cdir / "Cargo.toml").exists():
        errors.append(f"docs/kit-manifest.md lists {c}, but crates/{c} does not exist")
        continue
    manifest = tomllib.loads((cdir / "Cargo.toml").read_text())
    for sec, deps in sections(manifest):
        for key, spec in deps.items():
            r = resolve(key, spec, cdir)
            if r is None:
                continue
            pkg, rel = r
            if pkg in member_set:
                if rel != Path("crates") / pkg:
                    errors.append(f"{c} -> {pkg} lives at {rel}, not crates/{pkg}")
                continue
            if sec.endswith("dev-dependencies"):
                drops.setdefault(c, []).append((sec, key, pkg))
            elif isinstance(spec, dict) and spec.get("optional"):
                # An optional dependency outside the kit is fine while nothing in
                # the kit turns it on (impress-ai -> impel-core behind `executor`).
                opt_drops.setdefault(c, []).append((sec, key, pkg))
            else:
                errors.append(f"{c} has a {sec.split('.')[-1]} entry on {pkg} ({rel}), "
                              f"which is not in the kit: it could not leave")

def gating_features(manifest, key):
    """The [features] of a crate that turn optional dependency `key` on."""
    out = []
    for feat, vals in (manifest.get("features") or {}).items():
        if any(v in (f"dep:{key}", key) or v.startswith((f"{key}/", f"{key}?/")) for v in vals):
            out.append(feat)
    return out


root_ws_deps = tomllib.loads(root_text).get("workspace", {}).get("dependencies", {})
opt_features = {}  # crate -> features to strip from its copy
for c, ds in opt_drops.items():
    manifest = tomllib.loads((ROOT / "crates" / c / "Cargo.toml").read_text())
    for sec, key, pkg in ds:
        feats = gating_features(manifest, key)
        if "default" in feats or any(
                f in (manifest.get("features") or {}).get("default", []) for f in feats):
            errors.append(f"{c}'s optional {pkg} is on by default, so the kit pulls it: "
                          f"it could not leave")
            continue
        # Who turns those features on? Any kit crate (or the root's workspace entry).
        ws_spec = root_ws_deps.get(c)
        if isinstance(ws_spec, dict) and set(ws_spec.get("features", [])) & set(feats):
            errors.append(f"[workspace.dependencies] enables {c}'s {', '.join(feats)}, "
                          f"which pulls {pkg}: it could not leave")
        for other in members:
            om = tomllib.loads((ROOT / "crates" / other / "Cargo.toml").read_text())
            for osec, odeps in sections(om):
                spec = odeps.get(c)
                if isinstance(spec, dict) and set(spec.get("features", [])) & set(feats):
                    errors.append(f"kit crate {other} enables {c}'s "
                                  f"{', '.join(set(spec['features']) & set(feats))}, which pulls "
                                  f"{pkg} (not in the kit): it could not leave")
        opt_features.setdefault(c, []).extend(feats)
if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)

# --- the scratch workspace -----------------------------------------------------
scratch = Path(tempfile.mkdtemp(prefix="kit-standalone."))


def copy_tracked(rel):
    out = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard",
                          "--", str(rel)], cwd=ROOT, check=True, capture_output=True).stdout
    for f in filter(None, out.decode().split("\0")):
        src = ROOT / f
        if not src.is_file():  # deleted in the working tree
            continue
        dst = scratch / f
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def strip_dep(text, section, key):
    """Remove `key = ...` (one line or a balanced multi-line inline table) from [section]."""
    lines, out, i, in_sec, removed = text.splitlines(keepends=True), [], 0, False, False
    header = f"[{section}]"
    while i < len(lines):
        s = lines[i].strip()
        if s.startswith("["):
            in_sec = s == header
        if in_sec and re.match(rf"{re.escape(key)}(\.workspace)?\s*=", s):
            depth = lines[i].count("{") - lines[i].count("}")
            i += 1
            while depth > 0 and i < len(lines):
                depth += lines[i].count("{") - lines[i].count("}")
                i += 1
            removed = True
            continue
        out.append(lines[i])
        i += 1
    if not removed:
        fail(f"could not find {key} under [{section}] to drop it")
    return "".join(out)


def strip_feature(text, feat):
    """Empty `feat = [...]` (one line or a multi-line array) in [features]: `feat = []`."""
    lines, out, i, in_sec, removed = text.splitlines(keepends=True), [], 0, False, False
    while i < len(lines):
        s = lines[i].strip()
        if s.startswith("["):
            in_sec = s == "[features]"
        if in_sec and re.match(rf"{re.escape(feat)}\s*=", s):
            depth = lines[i].count("[") - lines[i].count("]")
            i += 1
            while depth > 0 and i < len(lines):
                depth += lines[i].count("[") - lines[i].count("]")
                i += 1
            # Kept as an empty feature so `#[cfg(feature = ...)]` stays a known
            # cfg: nothing in the kit enables it, so the gated code stays out.
            out.append(f"{feat} = []\n")
            removed = True
            continue
        out.append(lines[i])
        i += 1
    if not removed:
        fail(f"could not find feature {feat} under [features] to drop it")
    return "".join(out)


def mentions(path, lib):
    code = [l for l in path.read_text().splitlines() if not l.lstrip().startswith("//")]
    return any(re.search(rf"\b{lib}\b", l) for l in code)


try:
    for c in members:
        copy_tracked(Path("crates") / c)
    for f in ("rust-toolchain.toml", ".cargo/config.toml", "Cargo.lock"):
        if (ROOT / f).exists():
            (scratch / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / f, scratch / f)

    # Documents a kit crate compiles in with include_str! (the kit's own
    # contract doc, docs/agent-surfaces.md, is parsed by a surface test). Only
    # files under docs/ are copied: a crate reaching anywhere else is a finding.
    for rs in scratch.glob("crates/*/**/*.rs"):
        for rel in re.findall(r'include_str!\(\s*"([^"]+)"', rs.read_text()):
            target = (rs.parent / rel).resolve()
            try:
                inside = target.relative_to(scratch.resolve())
            except ValueError:
                fail(f"{rs.relative_to(scratch)} includes {rel}, outside the workspace")
            if target.exists() or inside.parts[0] != "docs":
                continue
            if not (ROOT / inside).is_file():
                fail(f"{rs.relative_to(scratch)} includes {rel}, which does not exist")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / inside, target)

    # Root manifest: the real one, members replaced, uncopied path entries removed.
    text = re.sub(r"(?ms)^members\s*=\s*\[.*?^\]",
                  "members = [\n" + "".join(f'    "crates/{c}",\n' for c in members) + "]",
                  root_text, count=1)
    kept = []
    in_ws_deps = False
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if s.startswith("["):
            in_ws_deps = s == "[workspace.dependencies]"
        m = re.match(r'([A-Za-z0-9_-]+)\s*=\s*\{[^}]*\bpath\s*=\s*"([^"]+)"', s) if in_ws_deps else None
        if m and Path(m.group(2)).name not in member_set:
            continue
        kept.append(line)
    text = "".join(kept)
    parsed = tomllib.loads(text)
    for key, spec in parsed["workspace"]["dependencies"].items():
        if isinstance(spec, dict) and "path" in spec and not (scratch / spec["path"]).exists():
            fail(f"scratch [workspace.dependencies] still points at {spec['path']}")
    (scratch / "Cargo.toml").write_text(text)

    # Optional out-of-kit dependencies nothing in the kit enables: gone from the copy,
    # with the features that would turn them on.
    for c, ds in opt_drops.items():
        mpath = scratch / "crates" / c / "Cargo.toml"
        mtext = mpath.read_text()
        for sec, key, pkg in ds:
            mtext = strip_dep(mtext, sec, key)
        for feat in opt_features.get(c, []):
            mtext = strip_feature(mtext, feat)
        mpath.write_text(mtext)
        print(f"optional dependency dropped: {c} -> {', '.join(p for _, _, p in ds)} "
              f"(feature {', '.join(opt_features.get(c, [])) or 'none'}, enabled by no kit crate)")

    # Dropped dev-dependencies, and the targets that can still be checked without them.
    partial = {}
    for c, ds in drops.items():
        mpath = scratch / "crates" / c / "Cargo.toml"
        mtext = mpath.read_text()
        for sec, key, pkg in ds:
            mtext = strip_dep(mtext, sec, key)
        mpath.write_text(mtext)
        libs = [pkg.replace("-", "_") for _, _, pkg in ds]
        cdir = scratch / "crates" / c
        args, skipped = ["--lib", "--bins"], []
        # The lib's own #[cfg(test)] modules, unless src/ uses a dropped crate.
        lib_tests = not any(mentions(p, l) for p in (cdir / "src").rglob("*.rs") for l in libs)
        for kind, flag in (("tests", "--test"), ("examples", "--example"), ("benches", "--bench")):
            d = cdir / kind
            if not d.is_dir():
                continue
            for p in sorted(d.glob("*.rs")) + sorted(d.glob("*/main.rs")):
                name = p.stem if p.name != "main.rs" else p.parent.name
                src = [p] if p.name != "main.rs" else list(p.parent.rglob("*.rs"))
                if any(mentions(s, l) for s in src for l in libs):
                    skipped.append(f"{kind}/{p.relative_to(d)}")
                else:
                    args += [flag, name]
        partial[c] = (args, lib_tests, skipped)
        print(f"dev-dependency dropped: {c} -> {', '.join(p for _, _, p in ds)} "
              f"(not in the kit); not checked: {', '.join(skipped) or 'none'}"
              f"{'' if lib_tests else ', lib unit tests'}")

    print(f"scratch workspace: {scratch} ({len(members)} crates: {' '.join(members)})")
    print(f"CARGO_TARGET_DIR={os.environ['CARGO_TARGET_DIR']}")

    def cargo(*args):
        cmd = ["cargo", "check", "-q", *args]
        print("+ " + " ".join(cmd), flush=True)
        t = time.time()
        r = subprocess.run(cmd, cwd=scratch)
        if r.returncode != 0:
            fail(f"`{' '.join(cmd)}` failed in the scratch workspace: the kit does not "
                 f"build on its own (docs/kit-manifest.md)")
        print(f"  ok ({time.time() - t:.0f}s)", flush=True)

    excl = [a for c in partial for a in ("--exclude", c)]
    cargo("--workspace", "--all-targets", *excl)
    for c, (args, lib_tests, _) in partial.items():
        cargo("-p", c, *args)
        if lib_tests:
            cargo("-p", c, "--lib", "--profile", "test")
    for c, feats in EXTRA_FEATURES.items():
        if c in member_set:
            cargo("-p", c, "--all-targets", "--features", feats)
    print(f"kit standalone OK: {len(members)} crates build with nothing else from this repository"
          + (f" ({', '.join(left_out)} left out: open finding)" if left_out else ""))
finally:
    if KEEP:
        print(f"kept: {scratch}")
    else:
        shutil.rmtree(scratch, ignore_errors=True)
PY
