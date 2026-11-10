#!/usr/bin/env python3
"""Save or restore Canon PTZ positions (pan, tilt, zoom) over Canon's HTTP control.

    python3 Tools/canon_position.py save positions.json 192.168.20.91 192.168.20.92
    python3 Tools/canon_position.py restore positions.json
"""
import json, sys, time, urllib.request

def get(ip, path):
    return urllib.request.urlopen(f"http://{ip}/-wvhttp-01-/{path}", timeout=5).read().decode(errors="replace")

def kv(text):
    out = {}
    for line in text.splitlines():
        for sep in (":=", "=="):
            if sep in line:
                k, v = line.split(sep, 1); out[k] = v; break
    return out

def session(ip):
    s = kv(get(ip, "open.cgi"))["s"]; get(ip, f"claim.cgi?s={s}"); return s

def position(ip):
    d = kv(get(ip, "info.cgi"))
    return {"pan": d.get("c.1.pan"), "tilt": d.get("c.1.tilt"), "zoom": d.get("c.1.zoom")}

if __name__ == "__main__":
    mode, path = sys.argv[1], sys.argv[2]
    if mode == "save":
        saved = {ip: position(ip) for ip in sys.argv[3:]}
        json.dump(saved, open(path, "w"), indent=1); print("saved", saved)
    else:
        saved = json.load(open(path))
        for ip, p in saved.items():
            s = session(ip)
            q = "&".join(f"{k}={v}" for k, v in p.items() if v not in (None, ""))
            print(ip, "restore", q, "->", get(ip, f"control.cgi?s={s}&{q}").replace("\n", " | "))
        time.sleep(5)
        for ip, p in saved.items():
            now = position(ip); print(ip, "now", now, "match" if now == p else "DIFFERENT")
