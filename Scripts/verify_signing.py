#!/usr/bin/env python3
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
"""Verify the local signing policy without exporting certificates or keys."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def codesign(*arguments):
    result = subprocess.run(["/usr/bin/codesign", *arguments], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "codesign failed")
    return result.stdout + result.stderr


def verify(app, ad_hoc=False):
    config_path = ROOT / "Signing/LocalSigning.plist"
    if ad_hoc or (not config_path.exists() and not config_path.is_symlink()):
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        bundle = info.get("CFBundleIdentifier")
        if bundle != "local.gargantua.desktop":
            raise RuntimeError("Local candidate must use the production bundle identifier")
        codesign("--verify", "--deep", "--strict", str(app))
        details = codesign("--display", "--verbose=4", str(app))
        if "Signature=adhoc" not in details:
            raise RuntimeError("Expected explicit ad-hoc signing")
        return {
            "bundle_identifier": bundle,
            "version": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"],
            "signing_mode": "ad-hoc-local-candidate",
            "strict_signature_valid": True,
            "certificate_based_identity": False,
            "cdhash": next(line.split("=", 1)[1] for line in details.splitlines() if line.startswith("CDHash=")),
        }

    with (ROOT / "Signing/LocalSigning.plist").open("rb") as stream:
        config = plistlib.load(stream)
    certificate = config["CertificateSHA1"]
    team = config["TeamIdentifier"]
    bundle = config["BundleIdentifier"]
    if not re.fullmatch(r"[A-F0-9]{40}", certificate):
        raise RuntimeError("Invalid pinned certificate fingerprint")
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or not re.fullmatch(r"[a-zA-Z0-9.-]+", bundle):
        raise RuntimeError("Invalid signing identity configuration")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != bundle:
        raise RuntimeError("App bundle identifier does not match signing policy")
    # This is an additional verification constraint, NOT a replacement for the
    # system-generated designated requirement. Keep Apple's default requirement.
    requirement = f'identifier "{bundle}" and anchor apple generic and certificate leaf = H"{certificate}"'
    codesign("--verify", "--deep", "--strict", "-R", "=" + requirement, str(app))
    details = codesign("--display", "--verbose=4", str(app))
    if f"TeamIdentifier={team}\n" not in details or "Signature=adhoc" in details:
        raise RuntimeError("Signing team mismatch or ad-hoc signature")
    requirement_output = codesign("--display", "--requirements", "-", str(app))
    designated = next((line.split("designated => ", 1)[1] for line in requirement_output.splitlines()
                       if line.startswith("designated => ")), None)
    if not designated or "cdhash " in designated or "anchor apple generic" not in designated:
        raise RuntimeError("App does not have the expected certificate-based designated requirement")
    cdhash = next(line.split("=", 1)[1] for line in details.splitlines() if line.startswith("CDHash="))
    return {
        "bundle_identifier": bundle,
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "certificate_sha1": certificate,
        "team_identifier": team,
        "cdhash": cdhash,
        "designated_requirement_sha256": hashlib.sha256(designated.encode()).hexdigest(),
        "strict_signature_valid": True,
        "pinned_certificate_valid": True,
        "certificate_based_identity": True,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--ad-hoc", action="store_true", help="Verify explicit local signing without reading personal configuration")
    args = parser.parse_args()
    try:
        result = json.dumps(verify(args.app, ad_hoc=args.ad_hoc), ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.write_text(result)
        print(result, end="")
    except (OSError, ValueError, KeyError, RuntimeError, StopIteration) as error:
        parser.exit(1, f"Signing verification failed: {error}\n")
