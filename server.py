# server.py — FastAPI backend with live preview
import asyncio
import os
import subprocess
import time

from fastapi import FastAPI
from fastapi.responses import StreamingResponse, HTMLResponse, Response
from pydantic import BaseModel

from canvas import InkCanvas

app = FastAPI(title="Penz — Wacom Slate Capture")

canvas = InkCanvas()
canvas_lock = asyncio.Lock()
pages_dir = "data/pages"
os.makedirs(pages_dir, exist_ok=True)

# Background task tracking
_sync_process = None
_capture_process = None


class Point(BaseModel):
    x: int
    y: int
    p: int


class Stroke(BaseModel):
    points: list[tuple[int, int, int]]


@app.get("/", response_class=HTMLResponse)
async def index():
    return HTML_CONTENT


@app.post("/stream/point")
async def receive_point(pt: Point):
    async with canvas_lock:
        canvas.add_point(pt.x, pt.y, pt.p)
    return {"status": "ok"}


@app.post("/stream/stroke")
async def receive_stroke(stroke: Stroke):
    async with canvas_lock:
        canvas.add_stroke(stroke.points)
    return {"status": "ok"}


@app.get("/canvas/live")
async def live_canvas():
    async with canvas_lock:
        png = canvas.to_png_bytes()
    return StreamingResponse(png, media_type="image/png")


@app.post("/canvas/clear")
async def clear_canvas():
    async with canvas_lock:
        canvas.pen_up()
        path = os.path.join(pages_dir, f"page_{int(time.time())}.svg")
        canvas.save(path)
        canvas.clear()
    return {"saved": path}


@app.get("/pages")
async def list_pages():
    files = sorted(
        [f for f in os.listdir(pages_dir) if f.endswith((".png", ".svg"))],
        reverse=True,
    )
    return {"pages": files}


@app.delete("/pages/{name}")
async def delete_page(name: str):
    path = os.path.join(pages_dir, name)
    if not os.path.exists(path):
        return {"error": "not found"}
    os.remove(path)
    return {"deleted": name}


@app.get("/gallery", response_class=HTMLResponse)
async def gallery():
    files = sorted(
        [f for f in os.listdir(pages_dir) if f.endswith((".png", ".svg"))],
        reverse=True,
    )
    cards = ""
    for f in files:
        label = os.path.splitext(f)[0].replace("_", " ").replace("page ", "")
        ext = os.path.splitext(f)[1]
        thumb = f'<img src="/pages/{f}" loading="lazy" />'
        cards += f'<div class="card" data-name="{f}">' \
                 f'<div class="thumb" onclick="view(\'{f}\')">' \
                 f'{thumb}</div>' \
                 f'<div class="card-footer">' \
                 f'<span>{label}</span>' \
                 f'<div class="card-btns">' \
                 f'<button class="btn-sm" onclick="event.stopPropagation();download(\'{f}\')" title="Download">&#x2913;</button>' \
                 f'<button class="btn-sm btn-del" onclick="event.stopPropagation();delPage(\'{f}\')" title="Delete">&#x2715;</button>' \
                 f'</div></div></div>\n'
    return GALLERY_HTML.replace("{{CARDS}}", cards)


@app.get("/pages/{name}")
async def get_page(name: str):
    path = os.path.join(pages_dir, name)
    if not os.path.exists(path):
        return {"error": "not found"}
    if name.endswith(".svg"):
        return Response(content=open(path, "r", encoding="utf-8").read(), media_type="image/svg+xml")
    return StreamingResponse(open(path, "rb"), media_type="image/png")


@app.post("/device/sync")
async def device_sync():
    global _sync_process
    if _sync_process and _sync_process.poll() is None:
        return {"status": "already_running"}
    _sync_process = subprocess.Popen(
        [ "python", "sync.py" ],
        cwd=os.path.dirname(os.path.abspath(__file__)),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    return {"status": "started", "pid": _sync_process.pid}


@app.post("/device/capture")
async def device_capture():
    global _capture_process
    if _capture_process and _capture_process.poll() is None:
        return {"status": "already_running"}
    _capture_process = subprocess.Popen(
        [ "python", "capture.py", "--api", "http://localhost:8000" ],
        cwd=os.path.dirname(os.path.abspath(__file__)),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    return {"status": "started", "pid": _capture_process.pid}


@app.post("/device/stop")
async def device_stop():
    global _capture_process
    if _capture_process and _capture_process.poll() is None:
        _capture_process.terminate()
        _capture_process = None
        return {"status": "stopped"}
    return {"status": "not_running"}


@app.get("/device/status")
async def device_status():
    syncing = _sync_process is not None and _sync_process.poll() is None
    capturing = _capture_process is not None and _capture_process.poll() is None
    return {"syncing": syncing, "capturing": capturing}


HTML_CONTENT = """<!DOCTYPE html>
<html>
<head>
<title>Penz — Live Canvas</title>
<style>
  body { margin: 0; background: #111; display: flex; flex-direction: column; align-items: center; font-family: sans-serif; }
  nav { width: 100%; background: #1a1a1a; padding: 8px 0; display: flex; justify-content: center; gap: 20px; border-bottom: 1px solid #333; }
  nav a { color: #aaa; text-decoration: none; font-size: 13px; }
  nav a:hover, nav a.active { color: #eee; }
  h1 { color: #eee; margin: 10px 0 5px; font-size: 18px; }
  #status { color: #888; font-size: 12px; margin-bottom: 10px; }
  img { border: 1px solid #333; max-width: 95vw; max-height: 80vh; image-rendering: pixelated; }
  .controls { margin: 10px; }
  button { padding: 8px 16px; font-size: 14px; cursor: pointer; background: #333; color: #eee; border: 1px solid #555; border-radius: 4px; }
  button:hover { background: #444; }
</style>
</head>
<body>
<nav><a href="/" class="active">Live</a><a href="/gallery">Gallery</a></nav>
<h1>Penz — Live</h1>
<div id="status">Connecting...</div>
<img id="canvas" src="/canvas/live" />
<div class="controls">
  <button onclick="clearCanvas()">New Page</button>
  <button onclick="refresh()">Refresh</button>
</div>
<script>
let refreshing = false;
function refresh() {
  if (refreshing) return;
  refreshing = true;
  document.getElementById('status').textContent = 'Refreshing...';
  let img = document.getElementById('canvas');
  let t = Date.now();
  img.onload = () => {
    refreshing = false;
    document.getElementById('status').textContent = 'Live';
  };
  img.onerror = () => {
    refreshing = false;
    document.getElementById('status').textContent = 'Error - retrying...';
    setTimeout(refresh, 2000);
  };
  img.src = '/canvas/live?t=' + t;
}
async function clearCanvas() {
  await fetch('/canvas/clear', { method: 'POST' });
  refresh();
}
setInterval(() => { if (!refreshing) refresh(); }, 500);
</script>
</body>
</html>"""


GALLERY_HTML = """<!DOCTYPE html>
<html>
<head>
<title>Penz — Gallery</title>
<style>
  * { box-sizing: border-box; }
  body { margin: 0; background: #111; font-family: sans-serif; }
  nav { width: 100%; background: #1a1a1a; padding: 8px 0; display: flex; justify-content: center; gap: 20px; border-bottom: 1px solid #333; }
  nav a { color: #aaa; text-decoration: none; font-size: 13px; }
  nav a:hover, nav a.active { color: #eee; }
  .toolbar { display: flex; justify-content: space-between; align-items: center; max-width: 1400px; margin: 12px auto; padding: 0 20px; }
  h1 { color: #eee; margin: 0; font-size: 20px; }
  .toolbar-btns { display: flex; gap: 8px; align-items: center; }
  button { padding: 7px 14px; font-size: 13px; cursor: pointer; background: #333; color: #eee; border: 1px solid #555; border-radius: 4px; }
  button:hover { background: #444; }
  button:disabled { opacity: 0.4; cursor: not-allowed; }
  button.btn-green { background: #2a5a2a; border-color: #3a7a3a; }
  button.btn-green:hover { background: #3a7a3a; }
  button.btn-red { background: #5a2a2a; border-color: #7a3a3a; }
  button.btn-red:hover { background: #7a3a3a; }
  .status-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 4px; }
  .status-dot.on { background: #4f4; }
  .status-dot.off { background: #555; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; padding: 0 20px 40px; max-width: 1400px; margin: 0 auto; }
  .card { background: #1a1a1a; border: 1px solid #333; border-radius: 6px; overflow: hidden; transition: border-color 0.2s; }
  .card:hover { border-color: #666; }
  .thumb { cursor: pointer; }
  .card img { width: 100%; aspect-ratio: 2160/1470; object-fit: contain; background: #fff; display: block; }
  .card-footer { display: flex; justify-content: space-between; align-items: center; padding: 6px 10px; }
  .card-footer span { color: #aaa; font-size: 11px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .card-btns { display: flex; gap: 4px; flex-shrink: 0; }
  .btn-sm { padding: 3px 7px; font-size: 14px; line-height: 1; background: #2a2a2a; border: 1px solid #444; border-radius: 3px; cursor: pointer; color: #aaa; }
  .btn-sm:hover { background: #444; color: #eee; }
  .btn-del:hover { background: #5a2a2a; color: #f88; }
  #overlay { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.92); z-index: 100; justify-content: center; align-items: center; flex-direction: column; }
  #overlay.show { display: flex; }
  #overlay .bar { position: absolute; top: 0; left: 0; right: 0; display: flex; justify-content: space-between; align-items: center; padding: 10px 16px; background: rgba(0,0,0,0.6); }
  #overlay .bar-left { display: flex; gap: 8px; align-items: center; }
  #overlay .bar-right { display: flex; gap: 8px; align-items: center; }
  #overlay img { max-width: 95vw; max-height: 85vh; border: 1px solid #333; margin-top: 50px; background: white; }
  #overlay .label { color: #888; font-size: 12px; }
  .empty { color: #555; text-align: center; padding: 60px 20px; font-size: 15px; }
</style>
</head>
<body>
<nav><a href="/">Live</a><a href="/gallery" class="active">Gallery</a></nav>
<div class="toolbar">
  <h1>Pages</h1>
  <div class="toolbar-btns">
    <span id="devstatus"><span class="status-dot off"></span>Idle</span>
    <button class="btn-green" id="btn-sync" onclick="doSync()">Sync Pages</button>
    <button class="btn-green" id="btn-capture" onclick="doCapture()">Start Capture</button>
    <button class="btn-red" id="btn-stop" onclick="doStop()" disabled>Stop Capture</button>
    <button onclick="location.reload()">Refresh</button>
  </div>
</div>
<div class="grid" id="grid">{{CARDS}}</div>
<div id="overlay" onclick="closeOverlay(event)">
  <div class="bar">
    <div class="bar-left">
      <span class="label" id="fulllabel"></span>
    </div>
    <div class="bar-right">
      <button onclick="event.stopPropagation();download(currentFile)">Download</button>
      <button class="btn-red" onclick="event.stopPropagation();delFromOverlay()">Delete</button>
      <button onclick="closeOverlay(event)">&times; Close</button>
    </div>
  </div>
  <img id="fullimg" src="" onclick="event.stopPropagation()" style="display:none" />
</div>
<script>
let currentFile = '';

async function api(url, method='POST') {
  let r = await fetch(url, {method});
  return r.json();
}

async function doSync() {
  let btn = document.getElementById('btn-sync');
  btn.disabled = true; btn.textContent = 'Syncing...';
  await api('/device/sync');
  pollStatus();
  // Auto-refresh gallery after sync might finish
  setTimeout(() => { location.reload(); }, 60000);
}

async function doCapture() {
  let btn = document.getElementById('btn-capture');
  btn.disabled = true; btn.textContent = 'Starting...';
  let r = await api('/device/capture');
  pollStatus();
}

async function doStop() {
  await api('/device/stop');
  pollStatus();
}

async function pollStatus() {
  let r = await (await fetch('/device/status')).json();
  let el = document.getElementById('devstatus');
  let btnSync = document.getElementById('btn-sync');
  let btnCap = document.getElementById('btn-capture');
  let btnStop = document.getElementById('btn-stop');
  if (r.syncing) {
    el.innerHTML = '<span class="status-dot on"></span>Syncing';
    btnSync.disabled = true; btnSync.textContent = 'Syncing...';
  } else {
    btnSync.disabled = false; btnSync.textContent = 'Sync Pages';
  }
  if (r.capturing) {
    el.innerHTML = '<span class="status-dot on"></span>Capturing';
    btnCap.disabled = true; btnCap.textContent = 'Running';
    btnStop.disabled = false;
  } else {
    btnCap.disabled = false; btnCap.textContent = 'Start Capture';
    btnStop.disabled = true;
  }
  if (!r.syncing && !r.capturing) {
    el.innerHTML = '<span class="status-dot off"></span>Idle';
  }
}

function view(name) {
  currentFile = name;
  let imgEl = document.getElementById('fullimg');
  imgEl.style.display = '';
  imgEl.src = '/pages/' + name;
  document.getElementById('fulllabel').textContent = name.replace(/\.(svg|png)$/,'');
  document.getElementById('overlay').classList.add('show');
}

function closeOverlay(e) {
  if (e && e.target.tagName === 'IMG') return;
  document.getElementById('overlay').classList.remove('show');
}

function download(name) {
  let a = document.createElement('a');
  a.href = '/pages/' + name;
  a.download = name;
  a.click();
}

async function delPage(name) {
  if (!confirm('Delete ' + name + '?')) return;
  await api('/pages/' + encodeURIComponent(name), 'DELETE');
  let card = document.querySelector(`.card[data-name="${name}"]`);
  if (card) card.remove();
}

function delFromOverlay() {
  if (!currentFile) return;
  let name = currentFile;
  closeOverlay({target: document.getElementById('overlay')});
  delPage(name);
}

document.addEventListener('keydown', e => {
  if (e.key === 'Escape') document.getElementById('overlay').classList.remove('show');
});

// Auto-refresh gallery when sync finishes
let syncCheck = setInterval(async () => {
  let r = await (await fetch('/device/status')).json();
  if (!r.syncing) { clearInterval(syncCheck); }
  else { location.reload(); }
}, 10000);

pollStatus();
setInterval(pollStatus, 5000);
</script>
</body>
</html>"""


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
