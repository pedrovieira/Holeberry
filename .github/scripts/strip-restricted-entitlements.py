#!/usr/bin/env python3
"""Strip restricted entitlements that make the kernel reject ad-hoc-signed
binaries on Apple Silicon ("Code has restricted entitlements, but the
validation of its code signature failed").

com.apple.security.get-task-allow is a restricted entitlement that Xcode
injects when no development team is set; it requires a real signing identity.
For ad-hoc releases we drop it.

Usage: strip-restricted-entitlements.py <input.xml> <output.xml>
"""
import plistlib
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    ents = plistlib.load(f)
ents.pop("com.apple.security.get-task-allow", None)
with open(dst, "wb") as f:
    plistlib.dump(ents, f)
print("stripped, remaining keys:", sorted(ents.keys()))
