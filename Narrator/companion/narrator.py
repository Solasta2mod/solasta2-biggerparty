"""Narrator companion for Solasta II — speaks the lines the Narrator UE4SS mod writes to queue.txt.

Voice: Microsoft Edge neural text-to-speech (free, needs internet), through the edge-tts package.
Audio is cached next to this program (cache\\<hash>.mp3), so a line already heard plays instantly and
offline. Playback uses the Windows multimedia API; nothing else is installed.

Files (next to SolastaNarrator.exe, in <game>\\Brimstone\\Binaries\\Win64\\Narrator\\):
  queue.txt      written by the mod: one JSON object per line ({"kind": "...", "text": "..."} or {"kind": "stop"})
  narrator.ini   Voice=en-GB-RyanNeural  Rate=+0%  Volume=+0%  Enabled=1  (Ctrl+Shift+N / Ctrl+Shift+M in the game, or edit and restart)
  narrator.log   what was spoken, and any errors
"""
import asyncio, ctypes, hashlib, json, os, subprocess, sys, threading, time, queue

HERE = os.path.dirname(os.path.abspath(sys.argv[0]))
QUEUE = os.path.join(HERE, "queue.txt")
CACHE = os.path.join(HERE, "cache")
INI = os.path.join(HERE, "narrator.ini")
LOG = os.path.join(HERE, "narrator.log")
LOCK = os.path.join(HERE, "narrator.lock")
GAME_EXE = "Brimstone-Win64-Shipping.exe"

def log(msg):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("[%H:%M:%S] ") + msg + "\n")
    except OSError:
        pass

def read_ini():
    cfg = {"Voice": "en-GB-RyanNeural", "Rate": "+0%", "Volume": "+0%", "Pitch": "+0Hz", "Enabled": "1"}
    try:
        with open(INI, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith((";", "#", "[")):
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip()
    except OSError:
        with open(INI, "w", encoding="utf-8") as f:
            f.write("[Narrator]\n; Edge neural voice (en-GB-RyanNeural, en-GB-ThomasNeural, en-GB-SoniaNeural, en-US-AndrewNeural, en-US-AvaNeural, ...)\n"
                    "Voice=en-GB-RyanNeural\n; speaking rate and volume, e.g. -10% or +20%\nRate=+0%\nVolume=+0%\nPitch=+0Hz\n; 0 = muted (Ctrl+Shift+M in the game toggles it)\nEnabled=1\n")
    return cfg

winmm = ctypes.windll.winmm
def mci(cmd):
    buf = ctypes.create_unicode_buffer(256)
    err = winmm.mciSendStringW(cmd, buf, 255, None)
    return err, buf.value

class Player:
    """Plays mp3 files one after another on a worker thread; stop() drops everything pending."""
    def __init__(self):
        self.q = queue.Queue()
        self.gen = 0
        self.lock = threading.Lock()
        threading.Thread(target=self.run, daemon=True).start()
    def play(self, path, gen):
        self.q.put((path, gen))
    def stop(self):
        with self.lock:
            self.gen += 1
            while not self.q.empty():
                try: self.q.get_nowait()
                except queue.Empty: break
        mci("stop narr"); mci("close narr")
    def run(self):
        while True:
            path, gen = self.q.get()
            with self.lock:
                if gen != self.gen: continue
            alias = "narr"
            err, _ = mci('open "%s" type mpegvideo alias %s' % (path, alias))
            if err:
                log("cannot open %s (mci %d)" % (path, err)); continue
            mci("play %s wait" % alias)
            mci("close %s" % alias)

async def synthesize(text, cfg, path):
    import edge_tts
    tts = edge_tts.Communicate(text, cfg["Voice"], rate=cfg["Rate"], volume=cfg["Volume"], pitch=cfg["Pitch"])
    tmp = path + ".part"
    await tts.save(tmp)
    os.replace(tmp, path)          # never leave a half-written file where the player could pick it up

def running_pids(exe_name):
    """PIDs of processes with this image name, through the toolhelp snapshot (no console needed)."""
    k32 = ctypes.windll.kernel32
    TH32CS_SNAPPROCESS = 0x2
    class PROCESSENTRY32W(ctypes.Structure):
        _fields_ = [("dwSize", ctypes.c_ulong), ("cntUsage", ctypes.c_ulong), ("th32ProcessID", ctypes.c_ulong),
                    ("th32DefaultHeapID", ctypes.c_void_p), ("th32ModuleID", ctypes.c_ulong), ("cntThreads", ctypes.c_ulong),
                    ("th32ParentProcessID", ctypes.c_ulong), ("pcPriClassBase", ctypes.c_long), ("dwFlags", ctypes.c_ulong),
                    ("szExeFile", ctypes.c_wchar * 260)]
    pids = []
    snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == ctypes.c_void_p(-1).value or snap == -1:
        return None
    try:
        entry = PROCESSENTRY32W(); entry.dwSize = ctypes.sizeof(PROCESSENTRY32W)
        ok = k32.Process32FirstW(snap, ctypes.byref(entry))
        while ok:
            if entry.szExeFile.lower() == exe_name.lower():
                pids.append(entry.th32ProcessID)
            ok = k32.Process32NextW(snap, ctypes.byref(entry))
    finally:
        k32.CloseHandle(snap)
    return pids

def process_name(pid):
    """Image name of a live process, or None."""
    k32 = ctypes.windll.kernel32
    TH32CS_SNAPPROCESS = 0x2
    class PROCESSENTRY32W(ctypes.Structure):
        _fields_ = [("dwSize", ctypes.c_ulong), ("cntUsage", ctypes.c_ulong), ("th32ProcessID", ctypes.c_ulong),
                    ("th32DefaultHeapID", ctypes.c_void_p), ("th32ModuleID", ctypes.c_ulong), ("cntThreads", ctypes.c_ulong),
                    ("th32ParentProcessID", ctypes.c_ulong), ("pcPriClassBase", ctypes.c_long), ("dwFlags", ctypes.c_ulong),
                    ("szExeFile", ctypes.c_wchar * 260)]
    snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == ctypes.c_void_p(-1).value or snap == -1:
        return None
    try:
        entry = PROCESSENTRY32W(); entry.dwSize = ctypes.sizeof(PROCESSENTRY32W)
        ok = k32.Process32FirstW(snap, ctypes.byref(entry))
        while ok:
            if entry.th32ProcessID == pid:
                return entry.szExeFile
            ok = k32.Process32NextW(snap, ctypes.byref(entry))
    finally:
        k32.CloseHandle(snap)
    return None

def game_running():
    pids = running_pids(GAME_EXE)
    return True if pids is None else len(pids) > 0

def main():
    os.makedirs(CACHE, exist_ok=True)
    # one instance at a time: the lock names the running companion's pid (any file name, so an older
    # build left running still counts)
    try:
        if os.path.exists(LOCK):
            pid = int(open(LOCK).read().strip() or 0)
            if pid and pid != os.getpid() and "narrator" in (process_name(pid) or "").lower():
                return
        open(LOCK, "w").write(str(os.getpid()))
    except Exception:
        pass
    cfg = read_ini()
    log("started; voice %s rate %s volume %s" % (cfg["Voice"], cfg["Rate"], cfg["Volume"]))
    player = Player()
    # start at the end of whatever is already in the queue file
    try:
        pos = os.path.getsize(QUEUE)
    except OSError:
        pos = 0
    gen = 0
    muted = cfg.get("Enabled", "1").strip() == "0"
    last_check = time.time()
    while True:
        try:
            size = os.path.getsize(QUEUE)
        except OSError:
            size = 0
        if size < pos:
            pos = 0          # the mod truncated it
        if size > pos:
            with open(QUEUE, "rb") as f:
                f.seek(pos)
                chunk = f.read(size - pos)
            pos = size
            for raw in chunk.decode("utf-8", "replace").splitlines():
                raw = raw.strip()
                if not raw: continue
                try:
                    item = json.loads(raw)
                except ValueError:
                    log("bad line: " + raw[:120]); continue
                kind = item.get("kind", "")
                if kind == "stop":
                    player.stop(); gen = player.gen
                    log("stop")
                    continue
                if kind == "voice":            # Ctrl+Shift+N in the game: switch at once, the ini is already updated
                    cfg["Voice"] = item.get("voice") or cfg["Voice"]
                    player.stop(); gen = player.gen
                    log("voice -> " + cfg["Voice"])
                    continue
                if kind == "mute":
                    muted = True; player.stop(); gen = player.gen; log("muted"); continue
                if kind == "unmute":
                    muted = False; log("unmuted"); continue
                text = (item.get("text") or "").strip()
                if not text or (muted and kind != "sample"): continue
                key = hashlib.sha1((cfg["Voice"] + cfg["Rate"] + cfg["Pitch"] + "|" + text).encode("utf-8")).hexdigest()
                path = os.path.join(CACHE, key + ".mp3")
                if not os.path.exists(path):
                    try:
                        t0 = time.time()
                        asyncio.run(synthesize(text, cfg, path))
                        log("synthesized in %.1f s: %s" % (time.time() - t0, text[:80]))
                    except Exception as e:
                        log("synthesis failed (%s): %s" % (e, text[:80]))
                        continue
                else:
                    log("cached: " + text[:80])
                player.play(path, gen)
        if time.time() - last_check > 10:
            last_check = time.time()
            if not game_running():
                log("game closed; exiting")
                player.stop()
                try: os.remove(LOCK)
                except OSError: pass
                return
        time.sleep(0.2)

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log("fatal: %r" % (e,))
