"""Minimal NSKeyedArchiver codec for MainStage concert files.

decode() turns an archive into a graph of Obj / Ref nodes (sharing preserved), and Encoder turns nodes
back into `$objects` entries, either into a fresh archive or appended to an existing one so the rest of
that archive stays exactly as MainStage wrote it.

- Obj: an archived object (`$class` + fields). Field values are inline scalars, nodes, or lists of them.
- Ref: a scalar or string stored as its own object and referenced by UID (NSKeyedArchiver does this for
  values encoded with encodeObject:, e.g. `slot`, `parameterIndex_1`, strings). Inline scalars stay plain.
- NULL: `$null` (UID 0).
"""
from __future__ import annotations

import plistlib
from plistlib import UID

NULL = None


class Obj:
    __slots__ = ("cls", "chain", "fields")

    def __init__(self, cls, chain=None, fields=None):
        self.cls = cls
        self.chain = chain          # the `$classes` list, or None when the archive omits it
        self.fields = dict(fields or {})

    def __getitem__(self, key):
        return self.fields[key]

    def __setitem__(self, key, value):
        self.fields[key] = value

    def __repr__(self):
        return "Obj(%s, %r)" % (self.cls, self.fields)


class Ref:
    __slots__ = ("v",)

    def __init__(self, v):
        self.v = v

    def __repr__(self):
        return "Ref(%r)" % (self.v,)


def ns_dict(items):
    return Obj("NSMutableDictionary", ["NSMutableDictionary", "NSDictionary", "NSObject"],
               {"NS.keys": [Ref(k) for k, _ in items], "NS.objects": [v if isinstance(v, (Obj, Ref)) else Ref(v) for _, v in items]})


def ns_array(items, mutable=True):
    if mutable:
        return Obj("NSMutableArray", ["NSMutableArray", "NSArray", "NSObject"], {"NS.objects": list(items)})
    return Obj("NSArray", ["NSArray", "NSObject"], {"NS.objects": list(items)})


def decode(archive):
    """Archive dict (as plistlib loads it) → {top key: node}."""
    objs = archive["$objects"]
    memo = {}

    def node(i):
        if i == 0:
            return NULL
        if i in memo:
            return memo[i]
        o = objs[i]
        if isinstance(o, dict) and "$class" in o:
            c = objs[o["$class"].data]
            n = Obj(c["$classname"], c.get("$classes"))
            memo[i] = n
            for k, v in o.items():
                if k != "$class":
                    n.fields[k] = conv(v)
            return n
        n = Ref(o)
        memo[i] = n
        return n

    def conv(v):
        if isinstance(v, UID):
            return node(v.data)
        if isinstance(v, list):
            return [conv(x) for x in v]
        return v

    return {k: conv(v) for k, v in archive["$top"].items()}


def _scalar_key(v):
    return (type(v).__name__, v)


class Encoder:
    """Appends nodes to an `$objects` list. Pass an existing list to extend that archive in place."""

    def __init__(self, objects=None):
        self.objects = objects if objects is not None else ["$null"]
        self.memo = {}
        self.scalars = {}
        self.classes = {}
        for i, o in enumerate(self.objects):
            if i == 0:
                continue
            if isinstance(o, dict) and "$classname" in o:
                self.classes.setdefault(o["$classname"], i)
            elif isinstance(o, (str, int, float, bool)):
                self.scalars.setdefault(_scalar_key(o), i)

    def adopt(self, index):
        """A node standing for an object already in the archive, so new objects can share it."""
        n = Obj("$existing")
        self.memo[id(n)] = (index, n)
        return n

    def uid(self, n):
        if n is NULL:
            return UID(0)
        if isinstance(n, Ref):
            key = _scalar_key(n.v)
            if key not in self.scalars:
                self.scalars[key] = len(self.objects)
                self.objects.append(n.v)
            return UID(self.scalars[key])
        if isinstance(n, Obj):
            if id(n) in self.memo:
                return UID(self.memo[id(n)][0])
            i = len(self.objects)
            self.objects.append(None)
            self.memo[id(n)] = (i, n)   # keep n alive so its id() can't be reused by a later node
            d = {k: self.value(v) for k, v in n.fields.items()}
            d["$class"] = self.class_uid(n)
            self.objects[i] = d
            return UID(i)
        raise TypeError("not a node: %r" % (n,))

    def value(self, v):
        if v is NULL or isinstance(v, (Obj, Ref)):
            return self.uid(v)
        if isinstance(v, list):
            return [self.value(x) for x in v]
        return v

    def class_uid(self, n):
        if n.cls not in self.classes:
            self.classes[n.cls] = len(self.objects)
            d = {"$classname": n.cls}
            if n.chain is not None:
                d["$classes"] = list(n.chain)
            self.objects.append(d)
        return UID(self.classes[n.cls])


def encode(top):
    """{top key: node} → archive bytes (binary plist), the way MainStage writes mapping blobs."""
    enc = Encoder()
    top_uids = {k: enc.uid(v) for k, v in top.items()}
    archive = {"$version": 100000, "$archiver": "NSKeyedArchiver", "$top": top_uids, "$objects": enc.objects}
    return plistlib.dumps(archive, fmt=plistlib.FMT_BINARY, sort_keys=False)


def plain(n, depth=0, strict=False):
    """Node graph → plain Python values, for comparisons and printing. strict=True also records which
    scalars are stored as referenced objects ({"$ref": v}) and each class's `$classes` chain."""
    if depth > 40:
        return "<deep>"
    if isinstance(n, Ref):
        return {"$ref": n.v} if strict else n.v
    if isinstance(n, Obj):
        head = {"_class": n.cls, "_chain": n.chain} if strict else {"_class": n.cls}
        if "NS.keys" in n.fields:
            def key(k):
                k = plain(k, depth + 1)
                return k if isinstance(k, (str, int, float, bool)) else repr(k)
            return {**head, "items": {key(k): plain(v, depth + 1, strict) for k, v in zip(n["NS.keys"], n["NS.objects"])}}
        return {**head, **{k: plain(v, depth + 1, strict) for k, v in n.fields.items()}}
    if isinstance(n, list):
        return [plain(x, depth + 1, strict) for x in n]
    if isinstance(n, dict):
        return {k: plain(v, depth + 1, strict) for k, v in n.items()}
    return n
