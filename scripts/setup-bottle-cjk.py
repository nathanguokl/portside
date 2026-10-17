#!/usr/bin/env python3
"""Install pinned OFL CJK fonts in one stopped Portside bottle. Bottle deletion removes them.

There is no remove mode. Original font registration/alias values are recorded for review.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import uuid

spec = importlib.util.spec_from_file_location("portside_dxvk_setup", Path(__file__).with_name("setup-bottle-dxvk.py"))
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)

COMMIT = "f8d157532fbfaeda587e826d4cd5b21a49186f7c"
FONT = "NotoSansCJKsc-Regular.otf"
FONT_HASH = "2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b"
LICENSE_HASH = "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"
FONT_KEY = r"HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
FONT_NAME = "Noto Sans CJK SC (OpenType)"
FONT_PATH = "C:\\windows\\Fonts\\" + FONT
ALIAS_KEY = r"HKCU\Software\Wine\Fonts\Replacements"
ALIAS_NAME, ALIAS_VALUE = "Noto Sans CJK JP", "Noto Sans CJK SC"
BASE_URL = f"https://raw.githubusercontent.com/notofonts/noto-cjk/{COMMIT}/Sans/"


def registry_value(installer, key, name):
    code, output = installer.command(installer.wine, ["reg", "query", key, "/v", name], allowed=(0, 1))
    if code == 1:
        helpers.require(re.search(r"unable to find|cannot find|not found|does not exist|specified registry key", output, re.I),
                        f"Could not safely query {key} / {name}: {output}")
        return None
    match = re.search(r"^\s*" + re.escape(name) + r"\s+REG_SZ(?:\s+(.*))?$", output, re.M | re.I)
    helpers.require(match is not None, f"Unsupported registry type/output for {key} / {name}; preserved.")
    return match.group(1) or ""


def install_new_file(path, data):
    """Create a complete file atomically without following/replacing an existing entry."""
    helpers.no_link(path)
    if path.exists():
        helpers.require(helpers.regular(path) and path.read_bytes() == data, f"Different existing file preserved: {path}")
        return
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.chmod(temporary, 0o644)
            os.link(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def install(args):
    source = Path(os.path.abspath(args.font_dir.expanduser()))
    helpers.no_link(source)
    for filename, expected in ((FONT, FONT_HASH), ("OFL.txt", LICENSE_HASH)):
        path = source / filename
        helpers.no_link(path)
        helpers.require(helpers.regular(path) and helpers.digest(path) == expected, f"Pinned font/license checksum mismatch: {path}")
    prefix, bottle, wine, server = helpers.managed_bottle(args.home, str(uuid.UUID(args.bottle_id)).upper())
    fonts = prefix / "drive_c/windows/Fonts"
    helpers.no_link(fonts)
    helpers.require(fonts.is_dir() and prefix.resolve() in fonts.resolve().parents, "Unsafe or missing bottle Fonts directory.")
    destination = fonts / FONT
    helpers.no_link(destination)
    if destination.exists():
        helpers.require(helpers.regular(destination) and helpers.digest(destination) == FONT_HASH,
                        f"Different existing font preserved: {destination}")
    installer = helpers.Installer(prefix, bottle, wine, server)
    installer.directory = installer.base / "noto-cjk-sc"
    installer.backups = installer.directory / "originals"
    installer.state_path = installer.directory / "state.json"
    installer.environment = {key: value for key, value in installer.environment.items() if not key.startswith("LC_")}
    installer.environment.update(LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
    try:
        installer.start()  # Includes an idle check; never sends wineserver -k.
        registration = registry_value(installer, FONT_KEY, FONT_NAME)
        alias = registry_value(installer, ALIAS_KEY, ALIAS_NAME)
        helpers.require(registration is None or registration.casefold() == FONT_PATH.casefold(),
                        "A different existing font registration was preserved.")
        state = None
        if installer.state_path.exists() or installer.state_path.is_symlink():
            state = helpers.read_json(installer.state_path)
            helpers.require(state.get("schemaVersion") == 1 and state.get("owner") == helpers.OWNER
                            and state.get("bottleID") == bottle["id"] and state.get("componentID") == "noto-cjk-sc"
                            and state.get("version") == "2.004" and state.get("upstreamCommit") == COMMIT,
                            "Existing CJK component metadata does not match this bottle.")
        if state is None:
            state = {"schemaVersion": 1, "owner": helpers.OWNER, "bottleID": bottle["id"], "componentID": "noto-cjk-sc",
                     "version": "2.004", "upstreamCommit": COMMIT, "installedAt": datetime.now(timezone.utc).isoformat(),
                     "originalRegistration": registration, "originalAlias": alias, "status": "pending"}
        helpers.save_json(installer.state_path, state)
        provenance = {"repository": "https://github.com/notofonts/noto-cjk", "commit": COMMIT,
                      "font": {"file": FONT, "sha256": FONT_HASH, "url": BASE_URL + "OTF/SimplifiedChinese/" + FONT},
                      "license": {"file": "OFL.txt", "sha256": LICENSE_HASH, "url": BASE_URL + "LICENSE"}}
        install_new_file(installer.directory / "OFL.txt", (source / "OFL.txt").read_bytes())
        install_new_file(installer.directory / "PROVENANCE.json", (json.dumps(provenance, indent=2) + "\n").encode())
        install_new_file(destination, (source / FONT).read_bytes())
        if registration is None:
            installer.command(wine, ["reg", "add", FONT_KEY, "/v", FONT_NAME, "/t", "REG_SZ", "/d", FONT_PATH, "/f"])
        if alias is None:
            installer.command(wine, ["reg", "add", ALIAS_KEY, "/v", ALIAS_NAME, "/t", "REG_SZ", "/d", ALIAS_VALUE, "/f"])
        state["status"] = "installed"
        helpers.save_json(installer.state_path, state)
        print(json.dumps({"bottleID": bottle["id"], "font": str(destination), "sha256": FONT_HASH,
                          "alias": alias if alias is not None else ALIAS_VALUE, "metadata": str(installer.directory)}, indent=2))
    finally:
        installer.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bottle_id", metavar="BOTTLE_UUID")
    parser.add_argument("--font-dir", type=Path, required=True, help="Directory containing the pinned OTF and OFL.txt")
    parser.add_argument("--home", type=Path, default=Path.home() / "Library/Application Support/Portside")
    args = parser.parse_args()
    try:
        install(args)
    except (helpers.SetupError, OSError, ValueError) as error:
        print(f"CJK font setup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
