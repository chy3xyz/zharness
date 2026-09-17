#!/usr/bin/env python3
"""Link vendored client bundles into dist/plugins/<pkg> (run after
every `vite build` — vite wipes the dist tree). Idempotent."""
import json, os, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # webui/
dist = os.path.join(root, "dist")
manifest = json.load(open(os.path.join(root, "build-artifacts", "boot-manifest.json")))
base = os.path.join(root, "packages")

os.makedirs(os.path.join(dist, "plugins", "@deepseek-ai"), exist_ok=True)

# name -> packages/ subdir, derived from each package's own location in the
# workspace (single source of truth: scan packages/*/*/package.json names).
name_to_sub = {}
for group in sorted(os.listdir(base)):
    gdir = os.path.join(base, group)
    if not os.path.isdir(gdir):
        continue
    for leaf in sorted(os.listdir(gdir)):
        pj = os.path.join(gdir, leaf, "package.json")
        if not os.path.isfile(pj):
            continue
        try:
            name = json.load(open(pj)).get("name")
        except Exception:
            continue
        if name:
            name_to_sub[name] = f"{group}/{leaf}"

n = 0
for pkg in manifest["roster"]:
    sub = name_to_sub.get(pkg)
    if sub is None:
        print("MISS", pkg); continue
    lib = os.path.join(base, sub, "lib")
    if not os.path.isdir(lib):
        print("MISS", pkg); continue
    link = os.path.join(dist, "plugins", pkg)
    if not os.path.islink(link):
        os.symlink(lib, link); n += 1
print(f"linked {n} new; total {len(os.listdir(os.path.join(dist,'plugins','@deepseek-ai')))}")
