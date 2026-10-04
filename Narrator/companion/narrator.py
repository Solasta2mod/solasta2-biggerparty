"""Narrator companion for Solasta II — plays the recorded voice pack for the lines the Narrator UE4SS mod
writes to queue.txt.

Voice: the pack in pack\\ (index.json + one MP3 per world-event passage, made with tools/render_pack.py),
matched to the text on screen. A line the pack has no recording of is not read. Playback uses the Windows
multimedia API; nothing else is installed and nothing goes over the network.

Files (next to SolastaNarrator.exe, in <game>\\Brimstone\\Binaries\\Win64\\Narrator\\):
  queue.txt      written by the mod: one JSON object per line ({"kind": "...", "text": "..."} or {"kind": "stop"});
                 a "sample" may carry "gain" (0..1): that clip plays at that volume instead of PlaybackVolume
  narrator.ini   Enabled=1 (Ctrl+Shift+M in the game)  PlaybackVolume=100 (Ctrl+Shift+= / Ctrl+Shift+-)
  pack\\         the recordings (the index is read again when pack\\index.json changes)
  packs\\<name>\\ add-on packs of other mods (their own index.json + recordings), played only when a mod asks for
                 a "sample" of one of their lines; a narrator update replaces pack\\ and leaves packs\\ alone
  narrator.log   what was played, and any errors
"""
import ctypes, difflib, json, math, os, re, struct, sys, threading, time, queue, wave

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
    cfg = {"Enabled": "1", "PlaybackVolume": "100"}
    try:
        with open(INI, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith((";", "#", "[")):
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip()
    except OSError:
        with open(INI, "w", encoding="utf-8") as f:
            f.write("[Narrator]\n; 0 = muted (Ctrl+Shift+M in the game toggles it)\nEnabled=1\n"
                    "; playback volume in percent, 10 to 100 (Ctrl+Shift+= / Ctrl+Shift+- in the game)\nPlaybackVolume=100\n")
    return cfg

def chime_path():
    """A short, soft two-note chime, made once in the cache folder: an announcement the pack has no recording
    of (a volume key) plays it, at the playback volume, so the keys still answer."""
    path = os.path.join(CACHE, "chime.wav")
    if not os.path.exists(path):
        rate, frames = 22050, bytearray()
        for freq, dur in ((880.0, 0.12), (1318.5, 0.22)):
            n = int(rate * dur)
            for i in range(n):
                env = min(1.0, i / (0.008 * rate)) * (1.0 - i / n) ** 2
                frames += struct.pack("<h", int(9000 * env * math.sin(2 * math.pi * freq * i / rate)))
        tmp = path + ".part"
        with wave.open(tmp, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(bytes(frames))
        os.replace(tmp, path)
    return path

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
        self.level = 1000                            # MCI volume, 0..1000; applied by the worker thread
        self.lock = threading.Lock()
        threading.Thread(target=self.run, daemon=True).start()
    def play(self, path, gen, level=None):
        """level: this clip's own MCI volume (0..1000), kept whatever the volume keys do; None = the playback volume."""
        self.q.put((path, gen, level))
    def stop(self):
        with self.lock:
            self.gen += 1
            while not self.q.empty():
                try: self.q.get_nowait()
                except queue.Empty: break
    def set_level(self, percent):
        """Playback volume in percent; the clip playing follows within a poll."""
        self.level = max(0, min(100, int(percent))) * 10
    def stale(self, gen):
        with self.lock:
            return gen != self.gen
    def run(self):
        while True:
            path, gen, level = self.q.get()
            if self.stale(gen): continue
            err, _ = mci('open "%s" type mpegvideo alias narr' % path)
            if err:
                log("cannot open %s (mci %d)" % (path, err)); continue
            applied = self.level if level is None else level
            mci("setaudio narr volume to %d" % applied)
            mci("play narr")
            started, seen = time.time(), False
            while not self.stale(gen):               # a stop (new generation) cuts the clip here
                if level is None and self.level != applied:   # the volume keys: the line playing follows at once
                    applied = self.level; mci("setaudio narr volume to %d" % applied)
                err, mode = mci("status narr mode")
                if err: break
                if mode == "playing": seen = True
                elif mode == "stopped" and (seen or time.time() - started > 2): break   # finished
                time.sleep(self.POLL)
            mci("stop narr"); mci("close narr")

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
PACKS = os.path.join(HERE, "packs")      # add-on packs: packs\<name>\index.json (samples only, never narration)

def pack_indexes():
    """The index files of the narration pack and of every add-on pack."""
    out = [os.path.join(PACK, "index.json")]
    if os.path.isdir(PACKS):
        for sub in sorted(os.listdir(PACKS)):
            out.append(os.path.join(PACKS, sub, "index.json"))
    return out

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
    alike, the next sentence decides. A sentence the recording lacks is not read."""
    WAIT = 3.5
    GAP = 2.5          # a pause this long (a choice being made) starts a new block of text
    PROBE_WORDS = 6    # an opening still being typed starts its recording once this long and unique in the game
    def __init__(self, folder, addons=None):
        self.entries, self.kind, self.all, self.extra = [], None, [], []
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
        # add-on packs: other mods' recordings of their own lines, found by exact text only (a "sample")
        for sub in (sorted(os.listdir(addons)) if addons and os.path.isdir(addons) else []):
            idx = os.path.join(addons, sub, "index.json")
            if not os.path.exists(idx): continue
            try:
                for e in json.load(open(idx, encoding="utf-8")).get("passages", []):
                    path = os.path.join(addons, sub, e["file"])
                    if os.path.exists(path): self.extra.append((e["norm"], path))
            except Exception as e:
                log("add-on pack %s unreadable: %r" % (sub, e))
        self.reset()
    def __len__(self): return len(self.entries)
    def exact(self, raw):
        """The recording of exactly this text, if the pack has one (an announcement recorded with the pack)."""
        n = norm_text(raw)
        return next((path for norm, path in self.entries + self.extra if norm == n), None)
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
        """Actions for one sentence: ("play", mp3, label), or ("speak", text) for a sentence with no recording."""
        out = []
        fresh = kind != self.kind or time.time() - self.last > self.GAP
        self.last = time.time()
        if kind != self.kind:
            out += self._resolve(); self.current = None; self.kind = kind
        n = norm_text(raw)
        if not n: return out
        if self.current:
            if near_in(n, self.current): return out              # part of the recording that is playing
            if not self._cands(n): return out + [("speak", raw)] # words the recording lacks: not read
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

def speak(text, player, gen, pack=None, sample=False, level=None):
    """A line with no recording is not read. An announcement (a volume key) plays its recording if the pack
    has one, otherwise the chime; level = its own volume (a kobold hero's line follows the game's voice volume)."""
    if sample:
        rec = pack.exact(text) if pack else None
        log(("pack: " if rec else "chime: ") + text[:80] + ("" if level is None else " (volume %d)" % level))
        player.play(rec or chime_path(), gen, level)
    else:
        log("no recording, not read: " + text[:80])

def run_action(act, player, gen):
    if act[0] == "play":
        log("pack: " + act[2]); player.play(act[1], gen)
    else:
        speak(act[1], player, gen)

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
    log("started; playback volume %s%%" % cfg.get("PlaybackVolume", "100"))
    player = Player()
    try:
        player.set_level(int(cfg.get("PlaybackVolume", "100") or 100))
    except ValueError:
        pass
    def load_pack(why):
        p = Pack(PACK, PACKS)
        if len(p) or p.extra:
            log("pack%s: %d recorded passages%s" % (why, len(p), (", %d lines in add-on packs" % len(p.extra)) if p.extra else ""))
            return p
        log("no voice pack in %s: nothing will be read" % PACK)
        return None
    pack = load_pack("")
    def index_stamp():
        st = []
        for path in pack_indexes():
            try: st.append((path, os.path.getmtime(path)))
            except OSError: pass
        return tuple(st)
    stamp, last_stamp_check = index_stamp(), time.time()
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
                if kind == "mute":
                    muted = True; player.stop(); gen = player.gen; log("muted"); continue
                if kind == "unmute":
                    muted = False; log("unmuted"); continue
                if kind == "volume":           # Ctrl+Shift+= / - in the game; the ini is already updated
                    try:
                        player.set_level(int(item.get("level", 100)))
                        log("volume -> %s%%" % item.get("level"))
                    except (TypeError, ValueError):
                        log("bad volume: %r" % (item.get("level"),))
                    continue
                if kind == "probe":            # the opening of a sentence still being typed: recordings only
                    if pack and not muted:
                        for act in pack.probe(item.get("text") or "", item.get("for") or ""): run_action(act, player, gen)
                    continue
                text = (item.get("text") or "").strip()
                if not text or (muted and kind != "sample"): continue
                if pack and kind in ("description", "outcome"):
                    for act in pack.feed(text, kind): run_action(act, player, gen)
                    continue
                level = None
                if kind == "sample" and item.get("gain") is not None:
                    try: level = int(round(max(0.0, min(1.0, float(item["gain"]))) * 1000))
                    except (TypeError, ValueError): log("bad gain: %r" % (item.get("gain"),))
                speak(text, player, gen, pack, sample=(kind == "sample"), level=level)
        if pack:
            for act in pack.tick(): run_action(act, player, gen)
        if time.time() - last_stamp_check > 2:          # recordings added while the game runs
            last_stamp_check = time.time()
            s = index_stamp()
            if s != stamp:
                stamp = s
                fresh = load_pack(" reloaded")
                if fresh: pack = fresh
        if time.time() - last_check > 10:
            last_check = time.time()
            if not game_running():
                log("game closed; exiting")
                player.stop()
                try: os.remove(LOCK)
                except OSError: pass
                return
        time.sleep(0.05)                                 # a kobold hero's line starts with the game's take

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log("fatal: %r" % (e,))
