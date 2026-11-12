#!/usr/bin/env python3
"""Check every Mach-O member of a universal macOS library."""

import re
import subprocess
import sys


def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def main():
    if len(sys.argv) != 3:
        sys.exit("Usage: verify-macos-deployment-target.py BINARY MINIMUM_MACOS")
    binary, minimum = sys.argv[1:]
    maximum = version(minimum)
    architectures = subprocess.check_output(
        ["xcrun", "lipo", "-archs", binary], text=True
    ).split()
    if set(architectures) != {"arm64", "x86_64"}:
        sys.exit(f"Expected arm64 and x86_64 in {binary}, got {architectures}")
    for architecture in architectures:
        output = subprocess.check_output(
            ["xcrun", "otool", "-l", "-arch", architecture, binary], text=True
        )
        command = None
        member = binary
        checked = 0
        for line in output.splitlines():
            stripped = line.strip()
            if line.endswith(":"):
                member = line
            if stripped.startswith("cmd "):
                command = stripped.split()[1]
            if command == "LC_BUILD_VERSION" and stripped.startswith("platform "):
                if stripped.split()[1] not in {"1", "macos"}:
                    sys.exit(f"Not a macOS object: {architecture}: {member}")
            if (command == "LC_BUILD_VERSION" and stripped.startswith("minos ")) or (
                command == "LC_VERSION_MIN_MACOSX" and stripped.startswith("version ")
            ):
                target = stripped.split()[1]
                if not re.fullmatch(r"\d+(?:\.\d+){0,2}", target):
                    sys.exit(f"Invalid deployment version: {target}")
                if version(target) > maximum:
                    sys.exit(f"{architecture}: macOS {target} exceeds {minimum}: {member}")
                checked += 1
        if checked == 0:
            sys.exit(f"No macOS deployment commands found for {architecture}: {binary}")
        print(f"Verified {architecture}: {checked} objects target macOS {minimum} or earlier")


if __name__ == "__main__":
    main()
