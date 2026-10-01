"""Narrator companion for Solasta II — speaks the lines the Narrator UE4SS mod writes to queue.txt.

Voice: a recorded pack when one is installed (pack\\index.json + one MP3 per world-event passage, made
with tools/render_pack.py), otherwise Microsoft Edge neural text-to-speech (free, needs internet), through
the edge-tts package. Edge audio is cached next to this program (cache\\<hash>.mp3), so a line already heard
plays instantly and offline. Playback uses the Windows multimedia API; nothing else is installed.

Files (next to SolastaNarrator.exe, in <game>\\Brimstone\\Binaries\\Win64\\Narrator\\):
  queue.txt      written by the mod: one JSON object per line ({"kind": "...", "text": "..."} or {"kind": "stop"})
  narrator.ini   Voice=en-IE-EmilyNeural  Rate=+0%  Volume=+0%  Enabled=1  (Ctrl+Shift+N / Ctrl+Shift+M in the game, or edit and restart)
  narrator.log   what was spoken, and any errors
"""
import asyncio, ctypes, difflib, hashlib, json, os, re, subprocess, sys, threading, time, queue

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
    cfg = {"Voice": "en-IE-EmilyNeural", "Rate": "+0%", "Volume": "+0%", "Pitch": "+0Hz", "Enabled": "1", "Pack": "1"}
    try:
        with open(INI, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith((";", "#", "[")):
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip()
    except OSError:
        with open(INI, "w", encoding="utf-8") as f:
            f.write("[Narrator]\n; Edge neural voice (en-IE-EmilyNeural, en-IE-ConnorNeural, en-GB-RyanNeural, en-GB-SoniaNeural, en-US-AndrewNeural, en-US-AvaNeural, ...)\n"
                    "Voice=en-IE-EmilyNeural\n; speaking rate and volume, e.g. -10% or +20%\nRate=+0%\nVolume=+0%\nPitch=+0Hz\n; 0 = muted (Ctrl+Shift+M in the game toggles it)\nEnabled=1\n")
    return cfg

winmm = ctypes.windll.winmm
def mci(cmd):
    buf = ctypes.create_unicode_buffer(256)
    err = winmm.mciSendStringW(cmd, buf, 255, None)
    return err, buf.value

class Player:
    """Plays mp3 files one after another on a worker thread; stop() drops everything pending and cuts the
    clip that is playing. Every MCI call is made on the worker thread: an MCI device belongs to the thread
    that opened it, and a stop sent from any other thread fails (error 263) while the clip plays on."""
    POLL = 0.1
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
    def stale(self, gen):
        with self.lock:
            return gen != self.gen
    def run(self):
        while True:
            path, gen = self.q.get()
            if self.stale(gen): continue
            err, _ = mci('open "%s" type mpegvideo alias narr' % path)
            if err:
                log("cannot open %s (mci %d)" % (path, err)); continue
            mci("play narr")
            started, seen = time.time(), False
            while not self.stale(gen):               # a stop (new generation) cuts the clip here
                err, mode = mci("status narr mode")
                if err: break
                if mode == "playing": seen = True
                elif mode == "stopped" and (seen or time.time() - started > 2): break   # finished
                time.sleep(self.POLL)
            mci("stop narr"); mci("close narr")

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

PACK = os.path.join(HERE, "pack")

def norm_text(t):
    """Matching key: lower-case letters and digits, single spaces (tools/render_pack.py makes the same)."""
    t = re.sub(r"[^a-z0-9]+", " ", (t or "").lower())
    return re.sub(r"\s+", " ", t).strip()

def near_in(n, text):
    """Sentence n appears in text, allowing a word or two to differ: the game's wording can drift from the
    recorded text after a patch ("Get 'em, lads!" on screen, "Get them, lads!" in the recording)."""
    if n in text: return True
    w, c = n.split(), text.split()
    if len(w) < 3: return False
    m = difflib.SequenceMatcher(None, w, c, autojunk=False).find_longest_match(0, len(w), 0, len(c))
    if m.size < 2: return False
    window = c[max(0, m.b - m.a - 3):m.b - m.a + len(w) + 3]
    hit = sum(b.size for b in difflib.SequenceMatcher(None, w, window, autojunk=False).get_matching_blocks())
    return hit >= 0.7 * len(w)

def near_start(n, text):
    """Text begins with (nearly) n: at least 90% of n's characters found, in order, at the start of text."""
    if len(n) < 20: return False
    head = text[:len(n) + 6]
    hit = sum(b.size for b in difflib.SequenceMatcher(None, n, head, autojunk=False).get_matching_blocks())
    return hit >= 0.9 * len(n)

class Pack:
    """Recorded world-event passages, matched by their text. A passage plays whole from its first sentence
    and the sentences after it are skipped (small wording differences allowed); when several passages open
    alike, the next sentence decides. A sentence the recording lacks is read by the Edge voice after it."""
    WAIT = 3.5
    GAP = 2.5          # a pause this long (a choice being made) starts a new block of text
    PROBE_WORDS = 6    # an opening still being typed starts its recording once this long and unique in the game
    def __init__(self, folder):
        self.entries, self.kind, self.all = [], None, []
        index = os.path.join(folder, "index.json")
        if os.path.exists(index):
            try:
                data = json.load(open(index, encoding="utf-8"))
                for e in data.get("passages", []):
                    path = os.path.join(folder, e["file"])
                    if os.path.exists(path): self.entries.append((e["norm"], path))
                self.all = sorted(set(data.get("all", [])))      # every passage in the game, recorded or not
            except Exception as e:
                log("pack index unreadable: %r" % (e,))
        self.reset()
    def __len__(self): return len(self.entries)
    def reset(self):
        self.current, self.pending, self.since, self.last = None, [], 0.0, 0.0
    def _cands(self, joined):
        found = [e for e in self.entries if e[0].startswith(joined)]
        return found or [e for e in self.entries if near_start(joined, e[0])]
    def _play(self, entry):
        self.current, self.pending = entry[0], []
        return [("play", entry[1], entry[0][:70])]
    def _flush(self):
        acts = [("speak", raw) for n, raw in self.pending]
        self.pending = []
        return acts
    def _resolve(self):
        if not self.pending: return []
        joined = " ".join(n for n, raw in self.pending)
        cands = self._cands(joined)
        exact = [e for e in cands if e[0] == joined]
        if exact: return self._play(exact[0])
        if cands: return self._play(min(cands, key=lambda e: len(e[0])))
        return self._flush()
    def feed(self, raw, kind):
        """Actions for one sentence: ("play", mp3, label) or ("speak", text) for the Edge voice."""
        out = []
        fresh = kind != self.kind or time.time() - self.last > self.GAP
        self.last = time.time()
        if kind != self.kind:
            out += self._resolve(); self.current = None; self.kind = kind
        n = norm_text(raw)
        if not n: return out
        if self.current:
            if near_in(n, self.current): return out              # part of the recording that is playing
            if not self._cands(n): return out + [("speak", raw)] # words the recording lacks: read after it
            self.current = None                                  # another recorded passage begins
        if not fresh and not self.pending and len(n.split()) < 5:
            return out + [("speak", raw)]    # a short line in the middle of a block ("Here?") never starts one
        joined = " ".join([m for m, r in self.pending] + [n])
        cands = self._cands(joined)
        if not cands and self.pending:
            out += self._flush(); cands = self._cands(n)
        if not cands: return out + [("speak", raw)]
        self.pending.append((n, raw)); self.since = time.time()
        return out + (self._play(cands[0]) if len(cands) == 1 else [])
    def tick(self):
        if self.pending and time.time() - self.since >= self.WAIT: return self._resolve()
        return []
    def probe(self, raw, kind):
        """The opening of a first sentence still being typed. When no other passage in the whole game (recorded
        or not: the index lists them all) begins this way and this one is recorded, it starts at once."""
        if not self.all or self.pending: return []
        n = norm_text(raw)
        if len(n.split()) < self.PROBE_WORDS: return []
        if self.current and kind == self.kind and near_in(n, self.current): return []
        if sum(1 for t in self.all if t.startswith(n)) != 1: return []
        rec = [e for e in self.entries if e[0].startswith(n)]
        if len(rec) != 1: return []
        out = self._resolve() if kind != self.kind else []
        self.kind, self.last = kind, 0.0
        act = self._play(rec[0])[0]
        return out + [(act[0], act[1], "early: " + act[2])]

def game_running():
    pids = running_pids(GAME_EXE)
    return True if pids is None else len(pids) > 0

def speak_edge(text, cfg, player, gen):
    key = hashlib.sha1((cfg["Voice"] + cfg["Rate"] + cfg["Pitch"] + "|" + text).encode("utf-8")).hexdigest()
    path = os.path.join(CACHE, key + ".mp3")
    if not os.path.exists(path):
        try:
            t0 = time.time()
            asyncio.run(synthesize(text, cfg, path))
            log("synthesized in %.1f s: %s" % (time.time() - t0, text[:80]))
        except Exception as e:
            log("synthesis failed (%s): %s" % (e, text[:80]))
            return
    else:
        log("cached: " + text[:80])
    player.play(path, gen)

def run_action(act, cfg, player, gen):
    if act[0] == "play":
        log("pack: " + act[2]); player.play(act[1], gen)
    else:
        speak_edge(act[1], cfg, player, gen)

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
    pack = Pack(PACK) if cfg.get("Pack", "1").strip() != "0" else None
    if pack is not None:
        if len(pack): log("pack: %d recorded passages" % len(pack))
        else: pack = None
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
                    if pack: pack.reset()
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
                if kind == "probe":            # the opening of a sentence still being typed: recordings only
                    if pack and not muted:
                        for act in pack.probe(item.get("text") or "", item.get("for") or ""): run_action(act, cfg, player, gen)
                    continue
                text = (item.get("text") or "").strip()
                if not text or (muted and kind != "sample"): continue
                if pack and kind in ("description", "outcome"):
                    for act in pack.feed(text, kind): run_action(act, cfg, player, gen)
                    continue
                speak_edge(text, cfg, player, gen)
        if pack:
            for act in pack.tick(): run_action(act, cfg, player, gen)
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
