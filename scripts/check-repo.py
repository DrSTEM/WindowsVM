#!/usr/bin/env python3
"""Check tracked publication content and relative documentation links."""
from pathlib import Path
import json
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent


def main():
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    errors = []
    forbidden = {"Machines", "Media", "Runtime", "build", "dist", "evidence"}
    private_docs = {"docs/BRIEF.md", "docs/TEST-REPORT.md", "scripts/prove-backend.py"}
    extensions = {".qcow2", ".raw", ".iso", ".dmg", ".vhdx", ".vmdk", ".p12", ".pem", ".log"}
    secrets = re.compile(r"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)")
    for name in filter(None, paths):
        path = ROOT / name
        if path.parts[len(ROOT.parts)] in forbidden or path.suffix.lower() in extensions or name in private_docs or name.startswith("docs/research/") or path.name.startswith(".env"):
            errors.append(f"Private/generated content is tracked: {name}")
        if path.is_symlink():
            errors.append(f"Review tracked symlink before publication: {name}")
            continue
        if not path.is_file():
            continue
        if path.stat().st_size > 2 * 1024 * 1024:
            errors.append(f"Unexpected large source file: {name}")
        try:
            content = path.read_text()
        except UnicodeDecodeError:
            errors.append(f"Unexpected binary file: {name}")
            continue
        if secrets.search(content):
            errors.append(f"Possible credential: {name}")
        if re.search(r"/Users/[A-Za-z0-9_.-]+/", content):
            errors.append(f"Personal absolute path: {name}")
        if path.suffix == ".md":
            for target in re.findall(r"\]\(([^\s)]+)(?:\s+[^)]*)?\)", content):
                link = urlsplit(target.strip("<>"))
                if link.scheme or link.netloc or not link.path:
                    continue
                resolved = (path.parent / unquote(link.path)).resolve()
                if not resolved.is_relative_to(ROOT) or not resolved.exists():
                    errors.append(f"Broken local link in {name}: {target}")
    lock = json.loads((ROOT / "scripts/runtime-lock.json").read_text())
    if not re.fullmatch(r"[a-f0-9]{64}", lock["utm_dmg_sha256"]):
        errors.append("Invalid UTM SHA-256 in runtime lock")
    if not re.fullmatch(r"[a-f0-9]{40}", lock["cocoaspice_revision"]):
        errors.append("Invalid CocoaSpice revision in runtime lock")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Publication checks passed for {len(list(filter(None, paths)))} tracked files; local documentation links resolve.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
