"""Call a tool on BeamNG's local MCP server: python mcp.py <tool> [json-args | @file.lua for run_lua]"""
import json, sys, urllib.request
sys.stdout.reconfigure(encoding="utf-8")

URL = "http://127.0.0.1:29292/mcp"

def call(method, params, id_=1):
    body = json.dumps({"jsonrpc": "2.0", "id": id_, "method": method, "params": params}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8", "replace"))

tool = sys.argv[1]
if tool == "list":
    res = call("tools/list", {})
    for t in res["result"]["tools"]:
        print(t["name"], "-", t.get("description", "")[:110])
    sys.exit()
arg = sys.argv[2] if len(sys.argv) > 2 else "{}"
if arg.startswith("@"):
    args = {"code": open(arg[1:], encoding="utf-8").read()}
elif tool == "run_lua" and not arg.lstrip().startswith("{"):
    args = {"code": arg}
else:
    args = json.loads(arg)
res = call("tools/call", {"name": tool, "arguments": args})
if "error" in res:
    print("RPC ERROR:", res["error"]); sys.exit(1)
r = res["result"]
for c in r.get("content", []):
    if c.get("type") == "text":
        print(c["text"])
    elif c.get("type") == "image":
        import base64
        out = sys.argv[3] if len(sys.argv) > 3 else "shot.png"
        open(out, "wb").write(base64.b64decode(c["data"]))
        print("image saved to", out)
if r.get("isError"):
    sys.exit(2)
