"""Preserve FlClashZ's independent version and record integrated upstream versions.

Run inside an isolated candidate merge, never on the clean main mirror.
Only the root pubspec version line is treated specially; other conflicts
remain conflicts. The metadata describes the source actually merged.
"""
import argparse
import pathlib
import re
import subprocess
import tempfile

PUBSPEC = "pubspec.yaml"
METADATA = "lib/common/flclashz_upstream_versions.dart"
VERSION = re.compile(r"(?m)^version: ([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.+-]+)?)[ \t]*$")
CORE_CONFIG = re.compile(r"(?m)^core_version:\s*(v[0-9]+\.[0-9]+\.[0-9]+)\s*$")
CORE_MODULE = re.compile(r"(?m)^\s*github\.com/metacubex/mihomo\s+(v[0-9]+\.[0-9]+\.[0-9]+)\s*$")


def git(*args):
    return subprocess.check_output(["git", *args], text=True)


def value(pattern, content, name):
    matches = pattern.findall(content)
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {name}, got {len(matches)}")
    return matches[0]


def version(content):
    return value(VERSION, content, "pubspec version")


def replace_version(content, replacement):
    version(content)
    return VERSION.sub(lambda match: "version: " + replacement, content, count=1)


def resolve_pubspec():
    """Three-way merge with only version normalized; never choose ours wholesale."""
    stages = [git("show", f":{n}:{PUBSPEC}") for n in (1, 2, 3)]
    own = version(stages[1])
    with tempfile.TemporaryDirectory() as directory:
        paths = []
        for i, content in enumerate(stages):
            path = pathlib.Path(directory) / str(i)
            path.write_text(replace_version(content, "0.0.0"), encoding="utf-8")
            paths.append(str(path))
        result = subprocess.run(
            ["git", "merge-file", "-p", paths[1], paths[0], paths[2]],
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            raise ValueError("pubspec has conflicts beyond the version line")
        pathlib.Path(PUBSPEC).write_text(
            replace_version(result.stdout, own), encoding="utf-8"
        )
    git("add", PUBSPEC)


def record(development, upstream):
    own = version(git("show", f"{development}:{PUBSPEC}"))
    original = version(git("show", f"{upstream}:{PUBSPEC}")).split("+")[0]
    pub = pathlib.Path(PUBSPEC)
    pub.write_text(replace_version(pub.read_text(encoding="utf-8"), own), encoding="utf-8")
    config = pathlib.Path("build_config.yaml").read_text(encoding="utf-8")
    mod = pathlib.Path("core/go.mod").read_text(encoding="utf-8")
    core = value(CORE_CONFIG, config, "Mihomo build version")
    module = value(CORE_MODULE, mod, "Mihomo module version")
    if core != module:
        raise ValueError(f"Mihomo config {core} does not match go.mod {module}")
    pathlib.Path(METADATA).write_text(
        "// Maintained by tool/flclashz_sync_versions.py after an upstream merge.\n"
        f"const flClashXVersion = '{original}';\n"
        f"const bundledMihomoVersion = '{core}';\n", encoding="utf-8"
    )
    git("add", PUBSPEC, METADATA)
    print(f"FlClashZ {own}; FlClashX {original}; Mihomo {core}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--resolve-pubspec", action="store_true")
    parser.add_argument("--development")
    parser.add_argument("--upstream")
    args = parser.parse_args()
    if args.resolve_pubspec:
        resolve_pubspec()
    elif args.development and args.upstream:
        record(args.development, args.upstream)
    else:
        parser.error("provide --resolve-pubspec or both commit refs")


if __name__ == "__main__":
    main()
