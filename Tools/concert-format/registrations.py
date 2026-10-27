#!/usr/bin/env python3
"""Every place a screen control's identity appears in a concert bundle, as normalized paths.

    registrations.py BUNDLE.concert <uuid or control name>

A control MainStage made with Assign & Map shows up in 12 places (layout, patch and concert data.plist,
the patch's .cst mapping table). If a written control is missing any, MainStage drops it on load; the
tests compare generated controls against MainStage's own this way.
"""
from __future__ import annotations

import os
import plistlib
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import concert_write as cw  # noqa: E402
from keyed_archive import Obj, Ref, decode, plain  # noqa: E402


def identity_name(n):
    u = n.fields.get("uuidString")
    u = u.v if isinstance(u, Ref) else plain(u)
    return u.get("NS.string") if isinstance(u, dict) else u


def walk_node(n, path, name, out, seen=frozenset()):
    """Archived node graph: identities by object, plus strings that contain the name."""
    if isinstance(n, Ref):
        if isinstance(n.v, str) and name in n.v:
            out.add(path + "=str")
    elif isinstance(n, Obj):
        if n.cls == "WsPluginIdentity" and identity_name(n) == name:
            out.add(path + "=identity")
            return
        if id(n) in seen:
            return
        seen = seen | {id(n)}
        if "NS.keys" in n.fields:
            for k, v in zip(n["NS.keys"], n["NS.objects"]):
                hit = set()
                walk_node(k, path + "{key}", name, hit, seen)
                out |= hit
                k = plain(k)
                label = "{ID}" if hit else "{%s}" % (k if isinstance(k, (str, int)) else "obj")
                walk_node(v, path + label, name, out, seen)
            return
        for k, v in n.fields.items():
            walk_node(v, "%s.%s<%s>" % (path, k, n.cls), name, out, seen)
    elif isinstance(n, list):
        for x in n:
            walk_node(x, path + "[]", name, out, seen)
    elif isinstance(n, dict):
        for k, v in n.items():
            walk_node(v, path + "." + k, name, out, seen)


def walk_plain(x, path, name, out):
    """Plain plist values, descending into embedded archives."""
    if isinstance(x, dict):
        for k, v in x.items():
            label = "{ID}" if name in str(k) else "{%s}" % k
            if name in str(k):
                out.add(path + label + "=key")
            if isinstance(v, bytes) and v[:8] == b"bplist00":
                try:
                    walk_node(decode(plistlib.loads(v)), path + label + "<archive>", name, out)
                except Exception:
                    pass
            else:
                walk_plain(v, path + label, name, out)
    elif isinstance(x, list):
        for v in x:
            walk_plain(v, path + "[]", name, out)
    elif isinstance(x, str) and name in x:
        out.add(path + "=str")


def registrations(bundle, name):
    out = set()
    walk_node(decode(cw.Layout(bundle).archive), "layout", name, out)
    for dirpath, _dirs, files in os.walk(os.path.join(bundle, "Concert.patch")):
        level = "concert" if os.path.relpath(dirpath, bundle) == "Concert.patch" else "patch"
        for f in files:
            path = os.path.join(dirpath, f)
            if f == "data.plist":
                walk_plain(cw.load_plist(path), "plist:" + level, name, out)
            elif f.endswith(".cst"):
                cst = cw.ChannelStripFile(path)
                for chunk in (cst.MAPPINGS, cst.LOOKUP):
                    archive = cst.archive(chunk)
                    if archive:
                        walk_node(decode(archive), "cst%x" % chunk, name, out)
    return out


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    for p in sorted(registrations(sys.argv[1], sys.argv[2])):
        print(p)
