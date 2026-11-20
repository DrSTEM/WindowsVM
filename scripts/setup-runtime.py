#!/usr/bin/env python3
"""Download, authenticate, and stage the pinned upstream runtime."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / "scripts/runtime-lock.json").read_text())


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true", help="Recreate Runtime using the pinned upstream release")
    args = parser.parse_args()
    output = ROOT / "Runtime"
    stamp = output / "setup-lock.json"
    required = ["bin/qemu-img", "bin/swtpm", "bin/VMRenderServer", "qemu/keymaps",
                "qemu/edk2-aarch64-secure-code.fd", "qemu/edk2-arm-secure-vars.fd",
                "Frameworks/qemu-aarch64-softmmu.framework", "Frameworks/dxmt-native.framework",
                "Frameworks/spice-client-glib-2.0.8.framework"]
    if not args.refresh and stamp.exists() and json.loads(stamp.read_text()) == LOCK and all((output / x).exists() for x in required):
        print("Pinned runtime already prepared. Use --refresh to recreate it.")
        return
    cache = ROOT / "build/downloads"
    cache.mkdir(parents=True, exist_ok=True)
    dmg = cache / f"UTM-{LOCK['utm_release']}.dmg"
    if not dmg.exists() or sha256(dmg) != LOCK["utm_dmg_sha256"]:
        partial = dmg.with_suffix(".download")
        run("/usr/bin/curl", "--fail", "--location", "--retry", "3", "--proto", "=https",
            "--tlsv1.2", "--output", partial, LOCK["utm_url"])
        if sha256(partial) != LOCK["utm_dmg_sha256"]:
            partial.unlink()
            raise RuntimeError("UTM checksum mismatch. No runtime was installed.")
        partial.replace(dmg)
    print("Verified UTM SHA-256.", flush=True)
    run("xcrun", "stapler", "validate", dmg)
    with tempfile.TemporaryDirectory(prefix="runtime-", dir=ROOT / "build") as temporary:
        stage = Path(temporary)
        mount = stage / "mount"
        mount.mkdir()
        attached = False
        try:
            run("hdiutil", "attach", dmg, "-readonly", "-nobrowse", "-mountpoint", mount)
            attached = True
            run("python3", ROOT / "scripts/prepare-runtime.py", mount / "UTM.app", "--output", stage / "Runtime")
        finally:
            if attached:
                run("hdiutil", "detach", mount)
        (stage / "Runtime/setup-lock.json").write_text(json.dumps(LOCK, indent=2) + "\n")
        # Keep the previous runtime until preparation has completed successfully.
        previous = stage / "previous-runtime"
        if output.exists():
            output.rename(previous)
        try:
            (stage / "Runtime").rename(output)
        except BaseException:
            if previous.exists():
                previous.rename(output)
            raise
    print("Runtime ready. Windows media is obtained separately from Microsoft.")


if __name__ == "__main__":
    main()
