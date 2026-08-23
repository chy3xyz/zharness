#!/usr/bin/env python3
"""Link vendored client bundles into apps/web/dist/plugins/<pkg> (run after
every `vite build` — vite wipes the dist tree). Idempotent."""
import json, os, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # webui/
dsh  = os.path.join(root, "dsh")
dist = os.path.join(dsh, "apps", "web", "dist")
manifest = json.load(open(os.path.join(dsh, "build-artifacts", "boot-manifest.json")))
base = os.path.join(dsh, "packages")

os.makedirs(os.path.join(dist, "plugins", "@deepseek-ai"), exist_ok=True)
n = 0
for pkg in manifest["roster"]:
    short = pkg.split("@deepseek-ai/")[1]
    if   short.startswith("dsh-client-"):  sub = "client/" + short[len("dsh-client-"):]
    elif short.startswith("dsh-typert"):   sub = "typert/registry"
    elif short == "dsh-api-gateway":       sub = "api/gateway"
    elif short == "dsh-api-remotes":       sub = "api/remotes"
    else:
        continue
    lib = os.path.join(base, sub, "lib")
    if not os.path.isdir(lib):
        print("MISS", pkg); continue
    link = os.path.join(dist, "plugins", pkg)
    if not os.path.islink(link):
        os.symlink(lib, link); n += 1
print(f"linked {n} new; total {len(os.listdir(os.path.join(dist,'plugins','@deepseek-ai')))}")
