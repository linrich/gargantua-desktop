#!/usr/bin/env python3
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
"""Check two signed builds without launching them or accessing desktop frames."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def report(app):
    result = subprocess.run([sys.executable, str(ROOT / "Scripts/verify_signing.py"), str(app)],
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def requirement(app):
    result = subprocess.run(["/usr/bin/codesign", "--display", "--requirements", "-", str(app)],
                            text=True, capture_output=True, check=True)
    return next(line.split("designated => ", 1)[1] for line in (result.stdout + result.stderr).splitlines()
                if line.startswith("designated => "))


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("first", type=Path)
parser.add_argument("second", type=Path)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--reject-adhoc", type=Path)
args = parser.parse_args()
if not (ROOT / "Signing/LocalSigning.plist").exists():
    parser.error("Continuity verification requires your own pinned LocalSigning.plist; ad hoc identity is not stable across builds.")
first, second = report(args.first), report(args.second)
first_requirement, second_requirement = requirement(args.first), requirement(args.second)
checks = {
    "different_signed_content": first["cdhash"] != second["cdhash"],
    "same_pinned_certificate": first["certificate_sha1"] == second["certificate_sha1"],
    "same_team": first["team_identifier"] == second["team_identifier"],
    "same_designated_requirement": first_requirement == second_requirement,
    "both_signatures_strictly_valid": first["strict_signature_valid"] and second["strict_signature_valid"],
}
for label, app, other_requirement in [("new_build_satisfies_old_identity", args.second, first_requirement),
                                       ("old_build_satisfies_new_identity", args.first, second_requirement)]:
    result = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=" + other_requirement, str(app)],
                            text=True, capture_output=True)
    checks[label] = result.returncode == 0
if args.reject_adhoc:
    details = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(args.reject_adhoc)],
                             text=True, capture_output=True, check=True)
    checks["negative_control_is_adhoc"] = "Signature=adhoc" in details.stderr
    rejected = subprocess.run([sys.executable, str(ROOT / "Scripts/verify_signing.py"), str(args.reject_adhoc)],
                              text=True, capture_output=True)
    checks["signing_policy_rejects_adhoc"] = rejected.returncode != 0
result = {"checks": checks, "first": first, "second": second,
          "scope": "Signature identity checks only; TCC permission continuity requires native upgrade verification."}
args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
if not all(checks.values()):
    raise SystemExit("Signing continuity checks failed")
