"""Pin stable component updates on an isolated integration candidate.

Mihomo is intentionally excluded; it is integrated by FlClashX.
Upstream code is not executed by this script.
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import tempfile
import urllib.request

SETUP = pathlib.Path("scripts/setup_zapret.ps1")
VERSIONS = pathlib.Path("lib/providers/zapret_components.dart")
STRATEGIES = pathlib.Path("services/helper/strategies")
SOURCES = {
    "Zapret2": ("bol-van/zapret2", "Zapret2", "zapret2-{tag}.zip"),
    "Flowseal": ("Flowseal/zapret-discord-youtube", "Flowseal",
                 "zapret-discord-youtube-{tag}.zip"),
}


def git(repo, *args, binary=False):
    return subprocess.check_output(
        ["git", "-C", str(repo), *args], text=not binary
    )


def replace_once(text, pattern, replacement):
    result, count = re.subn(pattern, lambda _: replacement, text)
    if count != 1:
        raise ValueError(f"expected one occurrence: {pattern}; got {count}")
    return result


def ps_value(text, name):
    match = re.findall(r"(?m)^\$" + re.escape(name) + r' = "([^"\r\n]+)"$', text)
    if len(match) != 1:
        raise ValueError(f"invalid PowerShell pin {name}")
    return match[0]


def ps_set(text, name, value):
    return replace_once(text, r"(?m)^\$" + re.escape(name) + r' = "[^"\r\n]+"$',
                        '$' + name + ' = "' + value + '"')


def semver(tag):
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", tag)
    if not match:
        raise ValueError(f"not a stable release: {tag}")
    return tuple(map(int, match.groups()))


def latest_release(repo):
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/latest",
        headers={"Accept": "application/vnd.github+json",
                 "User-Agent": "FlClashZ-component-sync"},
    )
    token = os.environ.get("GH_TOKEN")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def select_asset(repo, tag, filename, release):
    if release.get("draft") or release.get("prerelease"):
        raise ValueError(f"{repo}: release is not stable")
    matches = [a for a in release.get("assets", []) if a["name"] == filename]
    if len(matches) != 1:
        raise ValueError(f"{repo}: expected one asset {filename}")
    asset = matches[0]
    url = f"https://github.com/{repo}/releases/download/{tag}/{filename}"
    digest = asset.get("digest") or ""
    if asset.get("browser_download_url") != url or not re.fullmatch(
        r"sha256:[0-9a-f]{64}", digest
    ) or asset.get("size", 0) <= 0:
        raise ValueError(f"{repo}: missing expected asset URL or SHA-256 digest")
    return url, digest.removeprefix("sha256:")


def update_engine(setup, versions, label, release):
    repo, prefix, template = SOURCES[label]
    tag = release["tag_name"]
    current = re.findall(rf"(?m)^  '{label}': '([^']+)',$", versions)
    if len(current) != 1:
        raise ValueError(f"invalid version metadata: {label}")
    old = current[0]
    if semver(tag) < semver(old):
        raise ValueError(f"{label}: refusing downgrade {old} -> {tag}")
    url, sha = select_asset(repo, tag, template.format(tag=tag), release)
    if semver(tag) == semver(old):
        if (ps_value(setup, prefix + "Url") != url
                or ps_value(setup, prefix + "Sha256") != sha):
            raise ValueError(f"{label}: same version changed its URL or digest")
        return setup, versions, f"{label}: {old} (unchanged)"
    setup = ps_set(setup, prefix + "Url", url)
    setup = ps_set(setup, prefix + "Sha256", sha)
    setup = replace_once(setup, rf'-Label "{re.escape(repo)} [^"]+"',
                         f'-Label "{repo} {tag}"')
    versions = replace_once(versions, rf"(?m)^  '{label}': '[^']+',$",
                            f"  '{label}': '{tag}',")
    return setup, versions, f"{label}: {old} -> {tag}"


def tree_paths(repo, ref, prefix=None):
    args = ["ls-tree", "-r", "-z", "--name-only", ref]
    if prefix:
        args += ["--", prefix]
    return git(repo, *args, binary=True).decode("utf-8").rstrip("\0").split("\0")


def strategy_paths(repo, ref):
    allowed = {}
    for path in tree_paths(repo, ref, "strategies"):
        relative = path.removeprefix("strategies/")
        if (re.fullmatch(r"zapret-[A-Za-z0-9_-]+\.lua", relative)
                or re.fullmatch(r"imported/kinlay0/[^/\\]+\.(?:bat|py|md)", relative, re.I)
                or relative == "imported/kinlay0/LICENSE"):
            if any(ord(c) < 32 or c in '<>:"|?*' for c in relative):
                raise ValueError("invalid Windows strategy path")
            if relative.casefold() in {p.casefold() for p in allowed}:
                raise ValueError("case-insensitive strategy path collision")
            allowed[relative] = git(repo, "show", f"{ref}:{path}", binary=True)
    if not allowed:
        raise ValueError(f"{ref}: no supported strategy files")
    return allowed


def merge_bytes(old, own, new, path):
    if old == new or own == new:
        return own
    if own == old:
        return new
    if old is None or own is None or new is None:
        raise ValueError(f"add/delete conflict: {path}")
    with tempfile.TemporaryDirectory() as tmp:
        files = []
        for i, data in enumerate((own, old, new)):
            target = pathlib.Path(tmp) / str(i)
            target.write_bytes(data)
            files.append(str(target))
        result = subprocess.run(
            ["git", "merge-file", "-p", *files], capture_output=True
        )
    if result.returncode:
        raise ValueError(f"three-way strategy conflict: {path}")
    return result.stdout


def plan_strategies(repo, old, new, target):
    subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", old, new],
                   check=True)
    previous, updated = strategy_paths(repo, old), strategy_paths(repo, new)
    changes = {}
    for path in sorted(previous.keys() | updated.keys()):
        file = target / path
        if file.is_symlink() or any(p.is_symlink() for p in file.parents):
            raise ValueError(f"strategy path is a symlink: {file}")
        local = file.read_bytes() if file.is_file() else None
        merged = merge_bytes(previous.get(path), local, updated.get(path), path)
        if merged != local:
            changes[file] = merged
    return changes


def update_strategies(setup, versions, repo, ref):
    old = ps_value(setup, "ZapretSourceCommit")
    new = git(repo, "rev-parse", ref).strip()
    if old == new:
        return setup, versions, {}, f"zapret2-gui: {old[:12]} (unchanged)"
    if not re.fullmatch(r"[0-9a-f]{40}", new):
        raise ValueError("invalid strategy commit")
    changes = plan_strategies(repo, old, new, STRATEGIES)
    tree = set(tree_paths(repo, new))
    for variable, directory in (("BlobFiles", "bin"), ("ListFiles", "lists")):
        match = re.search(r"(?m)^\s*\$" + variable + r' = @\(([^\r\n]+)\)$', setup)
        if match is None:
            raise ValueError(f"missing {variable}")
        for name in re.findall(r'"([^"]+)"', match[1]):
            if f"{directory}/{name}" not in tree and not name.endswith("-user.txt"):
                raise ValueError(f"missing upstream {directory}/{name}")
    setup = ps_set(setup, "ZapretSourceCommit", new)
    versions = replace_once(versions, r"(?m)^  'Стратегии Lua/BAT': '[^']+',$",
                            f"  'Стратегии Lua/BAT': '{new[:12]}',")
    return setup, versions, changes, f"zapret2-gui: {old[:12]} -> {new[:12]}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--strategy-repo", type=pathlib.Path)
    parser.add_argument("--strategy-ref", default="HEAD")
    parser.add_argument("--report", required=True, type=pathlib.Path)
    args = parser.parse_args()
    setup, versions = SETUP.read_text(encoding="utf-8"), VERSIONS.read_text(encoding="utf-8")
    lines = []
    for label, (repo, _, _) in SOURCES.items():
        try:
            setup, versions, message = update_engine(setup, versions, label, latest_release(repo))
            lines.append(message)
        except Exception as error:
            lines.append(f"BLOCKED {label}: {error}")
    changes = {}
    if args.strategy_repo:
        try:
            setup, versions, changes, message = update_strategies(
                setup, versions, args.strategy_repo, args.strategy_ref
            )
            lines.append(message)
        except Exception as error:
            lines.append(f"BLOCKED zapret2-gui: {error}")
    else:
        lines.append("BLOCKED zapret2-gui: fork could not be fetched")
    for file, content in changes.items():
        if content is None:
            file.unlink()
        else:
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(content)
    for path, content in ((SETUP, setup), (VERSIONS, versions)):
        if path.read_text(encoding="utf-8") != content:
            path.write_text(content, encoding="utf-8", newline="\n")
    args.report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
