import sys, zlib, plistlib, json
def load(p):
    raw=open(p,'rb').read()
    try: raw=zlib.decompress(raw)
    except Exception: pass
    return plistlib.loads(raw)
def resolver(objs):
    def R(x, depth=0, seen=frozenset()):
        if isinstance(x, plistlib.UID):
            if x.data in seen or depth>8: return f"<ref {x.data}>"
            return R(objs[x.data], depth+1, seen|{x.data})
        if isinstance(x, dict):
            if "NS.keys" in x:
                return {json.dumps(R(k,depth+1,seen), default=str, sort_keys=True): R(v,depth+1,seen) for k,v in zip(x["NS.keys"], x["NS.objects"])}
            if "NS.objects" in x: return [R(v,depth+1,seen) for v in x["NS.objects"]]
            if "NS.string" in x: return x["NS.string"]
            out={k: R(v,depth+1,seen) for k,v in x.items() if k!="$class"}
            if "$class" in x: out["_class"]=objs[x["$class"].data]["$classname"]
            return out
        if isinstance(x, list): return [R(v,depth+1,seen) for v in x]
        if isinstance(x, bytes): return f"<{len(x)} bytes>"
        return x
    return R
pl=load(sys.argv[1]); objs=pl["$objects"]; R=resolver(objs)
top=objs[1]
for key in ("controllerMapping","outputControllerAssignment"):
    v=R(top.get(key)) if key in top else None
    n=len(v) if isinstance(v,(dict,list)) else v
    print(f"== {key}: {n} entries")
    if isinstance(v,dict):
        for k,val in list(v.items())[:6]:
            print("  KEY", k); print("   ", json.dumps(val, default=str)[:700])
