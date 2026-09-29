#!/usr/bin/env python3
"""Writes an AltStore / SideStore source for the iPhone app.

A "source" is a small JSON file those apps read to list, install and update
apps. Add it once on the iPhone and Sidekick installs with one tap; new
releases then show up as updates.

Everything comes from the built app, so the listed permissions always match
the .ipa (AltStore refuses to install when they don't):

    tool/altstore_source.py --app build/ios/iphoneos/Runner.app \
        --ipa build/dist/Sidekick-0.3.0.ipa --tag v0.3.0 \
        --repo owner/sidekick --out build/dist/altstore.json
"""

import argparse
import datetime
import json
import os
import plistlib
import subprocess


def entitlements(app):
    """Entitlements baked into the app's signature (none when unsigned)."""
    try:
        out = subprocess.run(
            ["codesign", "-d", "--entitlements", ":-", app],
            capture_output=True,
            check=True,
        ).stdout
        return sorted(plistlib.loads(out).keys()) if out.strip() else []
    except (FileNotFoundError, subprocess.CalledProcessError, plistlib.InvalidFileException):
        return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, help="the built Runner.app")
    ap.add_argument("--ipa", required=True)
    ap.add_argument("--tag", required=True, help="release tag, e.g. v0.3.0")
    ap.add_argument("--repo", required=True, help="owner/name on GitHub")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(os.path.join(args.app, "Info.plist"), "rb") as f:
        info = plistlib.load(f)

    releases = f"https://github.com/{args.repo}/releases"
    icon = f"{releases}/latest/download/sidekick-icon.png"
    tint = "#3F6BE0"
    privacy = {k: v for k, v in info.items() if k.endswith("UsageDescription")}

    source = {
        "name": "Sidekick",
        "identifier": "dev.sidekick.source",
        "subtitle": "Control your computer from your iPhone",
        "description": "The iPhone app for Sidekick: control your PC or Mac and send files both ways.",
        "iconURL": icon,
        "website": f"https://github.com/{args.repo}",
        "tintColor": tint,
        "apps": [
            {
                "name": "Sidekick",
                "bundleIdentifier": info["CFBundleIdentifier"],
                "developerName": "Sidekick",
                "subtitle": "Control your computer, share files",
                "localizedDescription": (
                    "Use your iPhone as a touchpad and keyboard for your Windows PC or Mac, "
                    "control what's playing, and send files both ways. Everything is encrypted "
                    "and stays on your own network, or goes over Bluetooth when there's no Wi-Fi."
                ),
                "iconURL": icon,
                "tintColor": tint,
                "category": "utilities",
                "screenshotURLs": [],
                "versions": [
                    {
                        "version": info["CFBundleShortVersionString"],
                        "buildVersion": str(info["CFBundleVersion"]),
                        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                        "localizedDescription": f"See {releases}/tag/{args.tag}",
                        "downloadURL": f"{releases}/download/{args.tag}/{os.path.basename(args.ipa)}",
                        "size": os.path.getsize(args.ipa),
                        "minOSVersion": info.get("MinimumOSVersion", "15.0"),
                    }
                ],
                "appPermissions": {"entitlements": entitlements(args.app), "privacy": privacy},
            }
        ],
        "news": [],
    }

    with open(args.out, "w") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
    print(f"Wrote {args.out}: {len(privacy)} privacy keys, bundle {info['CFBundleIdentifier']}")


if __name__ == "__main__":
    main()
