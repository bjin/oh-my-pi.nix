#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import tomllib
import urllib.request
from pathlib import Path, PurePosixPath

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
TMP_ROOT = ROOT / ".tmp"
HASHES_PATH = ROOT / "hashes.json"
UPSTREAM_DIR = ROOT / "upstream"
SYSTEM = "x86_64-linux"
UPSTREAM_REPO_URL = "https://github.com/can1357/oh-my-pi.git"
UPSTREAM_ARCHIVE_URL = "https://github.com/can1357/oh-my-pi/archive/{rev}.tar.gz"
UPSTREAM_TAG_GLOB = "v*.*.*"

# Files the flake parses while evaluating, copied verbatim out of the release
# tarball into a flat `upstream/`. Nothing is ever edited in place; an update
# replaces the whole directory. Keeping `nix/bun.nix` as `upstream/bun.nix`
# leaves it one directory below the tree root, exactly where it sits upstream,
# which is what lets flake.nix resolve the workspace member paths that file
# spells relative to itself.
COPIED_FILES = {
    "nix/bun.nix": "bun.nix",
    "Cargo.lock": "Cargo.lock",
}


def run(
    *args: str,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    capture: bool = True,
) -> str:
    result = subprocess.run(
        list(args),
        cwd=cwd or ROOT,
        env=env,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else subprocess.STDOUT,
    )
    return result.stdout.strip() if capture and result.stdout is not None else ""


def require_clean_git_tree() -> None:
    porcelain = run("git", "status", "--porcelain")
    if porcelain:
        raise SystemExit(
            "working tree is not clean; commit or stash changes before running update.py"
        )


def resolve_tag_revision(tag: str) -> str:
    output = run(
        "git",
        "ls-remote",
        "--exit-code",
        UPSTREAM_REPO_URL,
        f"refs/tags/{tag}",
        f"refs/tags/{tag}^{{}}",
    )
    refs: dict[str, str] = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) != 2:
            raise SystemExit(f"unexpected upstream ref line: {line}")
        refs[parts[1]] = parts[0]

    rev = refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")
    if rev is None:
        raise SystemExit(f"upstream tag does not exist: {tag}")
    if not re.fullmatch(r"[0-9a-f]{40}", rev):
        raise SystemExit(f"unexpected upstream revision for {tag}: {rev}")
    return rev


def get_latest_tag() -> tuple[str, str]:
    output = run(
        "git",
        "ls-remote",
        "--refs",
        "--tags",
        "--sort=-v:refname",
        UPSTREAM_REPO_URL,
        UPSTREAM_TAG_GLOB,
    )
    lines = output.splitlines()
    if not lines:
        raise SystemExit("could not find upstream release tags")
    ref = lines[0].split()[1]
    tag = ref.removeprefix("refs/tags/")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise SystemExit(f"unexpected upstream tag format: {tag}")
    return tag, resolve_tag_revision(tag)


def normalize_tag(raw_version: str) -> str:
    tag = raw_version if raw_version.startswith("v") else f"v{raw_version}"
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise SystemExit(f"unexpected upstream version format: {raw_version}")
    return tag


def resolve_target_tag(raw_version: str | None) -> tuple[str, str, str]:
    if raw_version:
        tag = normalize_tag(raw_version)
        rev = resolve_tag_revision(tag)
    else:
        tag, rev = get_latest_tag()
    return tag, tag.removeprefix("v"), rev


def read_pin() -> tuple[str, str, str]:
    pin = json.loads(HASHES_PATH.read_text())
    if not isinstance(pin, dict):
        raise SystemExit("hashes.json is not a JSON object")
    version = pin.get("version")
    rev = pin.get("rev")
    bun_version = pin.get("bunVersion")
    if not isinstance(version, str) or not version:
        raise SystemExit("hashes.json is missing version")
    if not isinstance(rev, str) or not re.fullmatch(r"[0-9a-f]{40}", rev):
        raise SystemExit("hashes.json is missing a 40-character rev")
    if not isinstance(bun_version, str) or not re.fullmatch(
        r"\d+\.\d+\.\d+", bun_version
    ):
        raise SystemExit("hashes.json is missing an x.y.z bunVersion")
    return version, rev, bun_version


def download_source(rev: str, work: Path) -> Path:
    # The same archive `pkgs.fetchzip` downloads at build time, so the hash
    # taken below is the one the flake has to record.
    url = UPSTREAM_ARCHIVE_URL.format(rev=rev)
    print(f"Downloading {url}")
    archive = work / "source.tar.gz"
    with urllib.request.urlopen(url) as response, archive.open("wb") as sink:
        shutil.copyfileobj(response, sink)

    unpacked = work / "unpacked"
    unpacked.mkdir()
    with tarfile.open(archive, "r:gz") as tar:
        tar.extractall(unpacked, filter="data")

    roots = sorted(unpacked.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        raise SystemExit(
            f"unexpected release tarball layout: {[root.name for root in roots]}"
        )
    return roots[0]


def hash_source(tree: Path) -> str:
    # `fetchzip` strips the tarball's single root directory and hashes what is
    # left, which is what this tree already is.
    digest = run("nix", "hash", "path", str(tree))
    if not digest.startswith("sha256-"):
        raise SystemExit(f"unexpected hash for {tree}: {digest}")
    return digest


def read_json(path: Path) -> dict:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise SystemExit(f"{path} is not a JSON object")
    return data


def parse_bun_floor(label: str, spec: object, prefix: str = "") -> tuple[int, ...]:
    if not isinstance(spec, str):
        raise SystemExit(f"upstream release does not declare {label}")
    text = spec.strip().removeprefix(prefix) if prefix else spec.strip()
    match = re.fullmatch(r">=\s*(\d+(?:\.\d+){0,2})", text)
    if match is None:
        raise SystemExit(f"unrecognised {label} specifier: {spec}")
    return tuple(int(part) for part in match.group(1).split("."))


def read_bun_floors(tree: Path) -> dict[str, tuple[int, ...]]:
    # Both floors bind the one Bun this build uses: `engines.bun` is the runtime
    # minimum for the interpreter the binary embeds, `packageManager` the
    # toolchain minimum upstream builds with. flake.nix explains why both bind.
    engines = read_json(tree / "packages/utils/package.json").get("engines")
    return {
        "engines.bun": parse_bun_floor(
            "engines.bun", engines.get("bun") if isinstance(engines, dict) else None
        ),
        "packageManager": parse_bun_floor(
            "packageManager", read_json(tree / "package.json").get("packageManager"), "bun@"
        ),
    }


def check_bun_pin(pinned: str, floors: dict[str, tuple[int, ...]]) -> None:
    # The pin is a reviewed constant, not something derived from the release
    # being pulled in, so an update only has to notice when a floor passes it.
    version = tuple(int(part) for part in pinned.split("."))
    unmet = sorted(
        (label, ".".join(str(part) for part in floor))
        for label, floor in floors.items()
        if version < floor
    )
    if unmet:
        raise SystemExit(
            f"hashes.json pins Bun {pinned}, below "
            + ", ".join(f"{label} >={floor}" for label, floor in unmet)
            + "; raise bunVersion to the newest nix-bun versions/*.json that clears every floor"
        )


def read_rust_toolchain_channel(tree: Path) -> str:
    toolchain = tomllib.loads((tree / "rust-toolchain.toml").read_text())
    channel = toolchain.get("toolchain", {}).get("channel")
    if not isinstance(channel, str) or not channel:
        raise SystemExit("upstream release does not declare a rust toolchain channel")
    return channel


def read_source_version(tree: Path) -> str:
    version = read_json(tree / "packages/coding-agent/package.json").get("version")
    if not isinstance(version, str) or not version:
        raise SystemExit("upstream release does not declare a package version")
    return version


def read_patched_dependencies(tree: Path) -> dict[str, str]:
    patched = read_json(tree / "package.json").get("patchedDependencies", {})
    if not isinstance(patched, dict) or not all(
        isinstance(patch, str) for patch in patched.values()
    ):
        raise SystemExit("upstream patchedDependencies is not a string map")
    return patched


def vendor_upstream_files(tree: Path, patched: dict[str, str]) -> dict[str, str]:
    copies = dict(COPIED_FILES)
    flat_names = {flat: source for source, flat in copies.items()}
    patched_flat: dict[str, str] = {}

    for dependency, patch in sorted(patched.items()):
        flat = PurePosixPath(patch).name
        claimed = flat_names.setdefault(flat, patch)
        if claimed != patch:
            raise SystemExit(f"upstream/{flat} would hold both {claimed} and {patch}")
        copies[patch] = flat
        patched_flat[dependency] = flat

    if UPSTREAM_DIR.exists():
        shutil.rmtree(UPSTREAM_DIR)
    UPSTREAM_DIR.mkdir()
    for source, flat in sorted(copies.items()):
        origin = tree / source
        if not origin.is_file():
            raise SystemExit(f"upstream release is missing {source}")
        shutil.copyfile(origin, UPSTREAM_DIR / flat)
    return patched_flat


def write_pin(
    version: str,
    rev: str,
    source_hash: str,
    bun_version: str,
    rust_toolchain_channel: str,
    patched_dependencies: dict[str, str],
) -> None:
    HASHES_PATH.write_text(
        json.dumps(
            {
                "version": version,
                "rev": rev,
                "hash": source_hash,
                "bunVersion": bun_version,
                "rustToolchainChannel": rust_toolchain_channel,
                "patchedDependencies": patched_dependencies,
            },
            indent=2,
        )
        + "\n"
    )


def seed_source(tree: Path, version: str) -> None:
    # `pkgs.fetchzip` would otherwise download the very tarball this run already
    # has, so publish that tree instead: a fixed-output path is a pure function
    # of its recursive sha256 and its name, so registering the tree under the
    # name the flake gives it leaves that derivation already valid and `nix
    # build` skips its own fetch. One download per update, not two.
    #
    # The comparison keeps the shortcut honest — it fails unless the flake, the
    # freshly written pin and this tree all agree on the store path — and it is
    # also what proves evaluation reads nothing but this repository. A short
    # download cannot reach here either: gzip and tar both fail on a truncated
    # archive. `ci.yml` still fetches the tarball independently on the pushed
    # commit, where the store is cold.
    #
    # The attribute names matter: an attribute set carrying `outPath` serialises
    # to that string alone, so asking for `outPath` by name would throw the rest
    # of the query away.
    source = json.loads(
        run(
            "nix",
            "eval",
            "--json",
            "--apply",
            "package: {"
            " inherit (package) version;"
            " sourceName = package.src.name;"
            " sourcePath = package.src.outPath;"
            " }",
            f".#packages.{SYSTEM}.oh-my-pi",
        )
    )
    if source["version"] != version:
        raise SystemExit(
            f"flake evaluates version {source['version']}, expected {version}"
        )

    added = run(
        "nix",
        "store",
        "add",
        "--mode",
        "nar",
        "--name",
        source["sourceName"],
        str(tree),
    )
    if added != source["sourcePath"]:
        raise SystemExit(
            f"seeded {added}, but the flake fetches {source['sourcePath']}"
        )
    print(f"Seeded {added}")


def run_omp_isolated(*args: str, extra_env: dict[str, str] | None = None) -> str:
    TMP_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="oh-my-pi-smoke-", dir=TMP_ROOT
    ) as temp_dir:
        temp_path = Path(temp_dir)
        home = temp_path / "home"
        xdg_data_home = temp_path / "xdg-data"
        home.mkdir()
        (xdg_data_home / "omp").mkdir(parents=True)
        return run(
            "./result/bin/omp",
            *args,
            env={
                **os.environ,
                **(extra_env or {}),
                "HOME": str(home),
                "XDG_DATA_HOME": str(xdg_data_home),
            },
        )


def verify_haskell_crash_regression() -> None:
    output = run_omp_isolated("read", str(ROOT / "Crash.hs"))
    if not output:
        raise SystemExit("Haskell crash regression produced no output")


def verify_embedded_bun_runtime() -> None:
    # The binary embeds the Bun that built it. A wrong one still starts the CLI,
    # but every `Bun.Image` caller (resize, PNG, kitty rendering) degrades.
    output = run_omp_isolated(
        "-e",
        "console.log(`${Bun.version} ${typeof Bun.Image}`)",
        extra_env={"BUN_BE_BUN": "1"},
    )
    version, _, image_kind = output.partition(" ")
    if image_kind != "function":
        raise SystemExit(f"embedded Bun {version} lacks Bun.Image")


def verify_smoke_test() -> None:
    output = run_omp_isolated("--smoke-test")
    if output != "smoke-test: ok":
        raise SystemExit(f"unexpected smoke test output: {output!r}")
    verify_haskell_crash_regression()
    verify_embedded_bun_runtime()


def verify_no_embedded_native_addons() -> None:
    omp_binary = ROOT / "result/lib/omp/omp"
    embedded_markers = (
        b"embedded-addons.linux-x64.tar.gz",
        b"pi_natives.linux-x64-baseline.node",
        b"pi_natives.linux-x64-modern.node",
    )
    binary = omp_binary.read_bytes()
    found_markers = [marker.decode() for marker in embedded_markers if marker in binary]
    if found_markers:
        formatted = "\n".join(f"  {marker}" for marker in found_markers)
        raise SystemExit(
            f"omp binary embeds native addon metadata; expected loose .node files:\n{formatted}"
        )


def verify_build() -> None:
    run("nix", "build", ".", capture=False)
    verify_smoke_test()
    verify_no_embedded_native_addons()


def commit_message(tag: str, version: str, previous_version: str, rev: str) -> str:
    if version == previous_version:
        return f"Update oh-my-pi {tag} source revision to {rev[:12]}"
    return f"Update oh-my-pi to {tag}"


def stage() -> None:
    # Before evaluating: Nix reads a dirty work tree through git, so a patch file
    # upstream only just added stays invisible — and fatal — until it is in the
    # index.
    run("git", "add", "-A", "hashes.json", "upstream", capture=False)


def commit(message: str) -> None:
    run("git", "commit", "-m", message, capture=False)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Update this flake to an upstream oh-my-pi release"
    )
    parser.add_argument(
        "--version",
        help="target upstream version, for example 17.3.0 or v17.3.0; defaults to the latest tag",
    )
    args = parser.parse_args()

    require_clean_git_tree()

    previous_version, previous_rev, bun_version = read_pin()
    tag, version, rev = resolve_target_tag(args.version)

    if rev == previous_rev:
        print(f"Already up to date at {tag} ({rev})")
        return 0

    if version == previous_version:
        print(f"Upstream tag {tag} moved from {previous_rev} to {rev}")
    else:
        print(f"Updating from {previous_version} to {version} ({rev})")

    TMP_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="oh-my-pi-source-", dir=TMP_ROOT
    ) as work_dir:
        tree = download_source(rev, Path(work_dir))
        source_version = read_source_version(tree)
        if source_version != version:
            raise SystemExit(
                f"upstream tag {tag} ships version {source_version}, not {version}"
            )
        check_bun_pin(bun_version, read_bun_floors(tree))
        write_pin(
            version,
            rev,
            hash_source(tree),
            bun_version,
            read_rust_toolchain_channel(tree),
            vendor_upstream_files(tree, read_patched_dependencies(tree)),
        )
        stage()
        seed_source(tree, version)

    verify_build()
    commit(commit_message(tag, version, previous_version, rev))
    print(f"Committed update for {tag}. Review locally, then push when ready.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
