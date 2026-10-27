import sys, plistlib, struct, json, re
sys.path.insert(0, "")
def embedded_bplists(data):
    out=[]
    for m in re.finditer(b'bplist00', data):
        s=m.start()
        for e in range(s+40, min(len(data), s+2_000_000)+1):
            t=data[e-32:e]
            if len(t)<32: break
            off_size, ref_size = t[6], t[7]
            nobj, top, table = struct.unpack('>QQQ', t[8:32])
            if off_size in (1,2,4,8) and ref_size in (1,2,4,8) and table + nobj*off_size + 32 == e - s and 0 < nobj < 100000:
                try:
                    out.append((s, plistlib.loads(data[s:e]))); break
                except Exception: pass
    return out
def resolve(pl):
    objs=pl.get("$objects")
    if objs is None: return pl
    def R(x, depth=0, seen=frozenset()):
        if isinstance(x, plistlib.UID):
            if x.data in seen or depth>12: return f"<ref {x.data}>"
            return R(objs[x.data], depth+1, seen|{x.data})
        if isinstance(x, dict):
            if "NS.keys" in x: return {json.dumps(R(k,depth+1,seen),default=str,sort_keys=True): R(v,depth+1,seen) for k,v in zip(x["NS.keys"],x["NS.objects"])}
            if "NS.objects" in x: return [R(v,depth+1,seen) for v in x["NS.objects"]]
            if "NS.string" in x: return x["NS.string"]
            if "NS.bytes" in x: return f"<bytes {len(x['NS.bytes'])}>"
            out={k: R(v,depth+1,seen) for k,v in x.items() if k!="$class"}
            if "$class" in x: out["_class"]=objs[x["$class"].data]["$classname"]
            return out
        if isinstance(x, list): return [R(v,depth+1,seen) for v in x]
        if isinstance(x, bytes): return f"<{len(x)} bytes>"
        return x
    return R(pl["$top"])
if __name__=="__main__":
    data=open(sys.argv[1],'rb').read()
    for off,pl in embedded_bplists(data):
        r=resolve(pl)
        print(f"--- archive at {off}: top keys {list(r.keys())[:8] if isinstance(r,dict) else type(r)}")
        print(json.dumps(r, default=str, indent=1)[: int(sys.argv[2]) if len(sys.argv)>2 else 3000])
