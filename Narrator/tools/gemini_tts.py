"""Small client for Gemini text-to-speech (gemini-3.8-flash-tts): voices and synthesis, standard library only.

The API key is read from the GEMINI_API_KEY environment variable, or straight from the user's registry
environment (HKCU/Environment) so a key set in Windows works without restarting anything. The key is
never printed or written anywhere. With no key at all, requests go out without one: a Claude Code cloud
environment can hold the key as an API credential and add it on the way out, unseen by the session.
"""
import base64, io, json, os, re, struct, time, urllib.error, urllib.parse, urllib.request, wave

API = "https://generativelanguage.googleapis.com/v1beta"
MODEL = "gemini-3.8-flash-tts"

def get_key():
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    if key:
        return key
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
            return str(winreg.QueryValueEx(k, "GEMINI_API_KEY")[0]).strip()
    except (ImportError, OSError):
        return ""

class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__("HTTP %s: %s" % (status, message)); self.status = status

# Tier 1 allows 10 requests a minute on the TTS model: keep POSTs at least 6.5 s apart, and on a 429 wait
# for the time the error names (or a minute) and try again
MIN_GAP = 6.5
_last_post = [0.0]

def call(method, path, body=None, query=None, timeout=120, retries=6):
    for attempt in range(retries + 1):
        if method == "POST":
            wait = _last_post[0] + MIN_GAP - time.time()
            if wait > 0: time.sleep(wait)
            _last_post[0] = time.time()
        try:
            return _call(method, path, body, query, timeout)
        except ApiError as e:
            if e.status not in (0, 429, 500, 503) or attempt == retries:
                raise
            wait = 15 if e.status == 0 else retry_seconds(str(e))
            if wait > 300:                       # the day's quota: waiting hours in a script helps nobody
                raise ApiError(e.status, "daily limit reached; " + str(e))
            time.sleep(wait + 1)

def retry_seconds(message):
    """'retry in 32s', '1m5s' or '8h26m45s' -> seconds (60 when the message names no time)."""
    m = re.search(r"retry in ((?:\d+h)?(?:\d+m)?(?:\d+(?:\.\d+)?s)?)", message)
    if not m or not m.group(1): return 60
    total = 0.0
    for num, unit in re.findall(r"(\d+(?:\.\d+)?)([hms])", m.group(1)):
        total += float(num) * {"h": 3600, "m": 60, "s": 1}[unit]
    return total or 60

def _call(method, path, body=None, query=None, timeout=120):
    key = get_key()
    headers = {"Content-Type": "application/json"}
    if key: headers["x-goog-api-key"] = key
    url = API + path + ("?" + urllib.parse.urlencode(query, doseq=True) if query else "")
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read()).get("error", {}).get("message", "")
        except Exception:
            msg = e.reason
        deny = e.headers.get("x-deny-reason") if e.headers else None
        if deny:                                  # a network proxy refused the host, Google never saw it
            msg = "blocked by the network proxy (%s)" % deny
        elif e.code in (401, 403) and not key:
            # names only, never values: shows a misspelt or mis-spaced variable, or that none came through at all
            near = sorted(n for n in os.environ if re.search(r"gemini|google|api.?key", n, re.I))
            state = ("GEMINI_API_KEY is set but empty" if "GEMINI_API_KEY" in os.environ else
                     "GEMINI_API_KEY is not set here (%s)" % ("similar names: " + ", ".join(repr(n) for n in near)
                                                              if near else "no similar variable either"))
            msg += (" - no API key reached Google: %s; set it, or give the cloud environment an API credential"
                    " for generativelanguage.googleapis.com" % state)
        raise ApiError(e.code, msg)
    except (urllib.error.URLError, OSError) as e:        # no connection, DNS, proxy refused, timed out
        raise ApiError(0, "network error: %s" % (getattr(e, "reason", None) or e,))

def list_voices(**filters):
    out, token = [], None
    while True:
        q = dict(filters)
        if token: q["page_token"] = token
        r = call("GET", "/voices", query=q)
        out += r.get("voices", [])
        token = r.get("next_page_token") or r.get("nextPageToken")
        if not token: return out

def design_voice(display_name, description, gender=None, language_code="en-GB", store=True):
    """Create a designed ("prompted") voice. Returns (voice id, preview wav bytes)."""
    voice = {"model": MODEL, "type": "prompted", "display_name": display_name[:60],
             "language_code": language_code, "prompted": {"input": description}}
    if gender: voice["gender"] = gender
    r = call("POST", "/voices", {"store": store, "voice": voice})
    v = r.get("voice", r)
    return v.get("id") or v.get("name", "").split("/")[-1], _audio_bytes(v.get("sample_audio") or r)

def _audio_bytes(obj):
    """The first base64 audio payload anywhere in a response."""
    if isinstance(obj, dict):
        mt = obj.get("mime_type") or obj.get("mimeType") or ""
        if "data" in obj and (mt.startswith("audio") or not mt):
            try: return base64.b64decode(obj["data"])
            except Exception: pass
        for v in obj.values():
            b = _audio_bytes(v)
            if b: return b
    elif isinstance(obj, list):
        for v in obj:
            b = _audio_bytes(v)
            if b: return b
    return b""

def synthesize(text, voice, style=None):
    """One line in one voice. Returns WAV bytes (24 kHz mono 16-bit)."""
    item = {"type": "text", "text": text}
    if style:
        item["annotations"] = [{"type": "speech_metadata", "style": style}]
    body = {"model": MODEL, "input": [{"type": "user_input", "content": [item]}],
            "response_format": {"type": "audio"},
            "generation_config": {"speech_config": [{"voice": voice}]}}
    audio = _audio_bytes(call("POST", "/interactions", body))
    if not audio:
        raise ApiError(0, "no audio in the response")
    return audio

def pcm_of(wav_bytes):
    with wave.open(io.BytesIO(wav_bytes)) as w:
        return w.getframerate(), w.getnchannels(), w.getsampwidth(), w.readframes(w.getnframes())

def join_wavs(parts, gap_ms=300):
    """Concatenate WAV clips (same format) with a short silence between them."""
    rate, ch, width, pcm = pcm_of(parts[0])
    silence = b"\x00" * int(rate * gap_ms / 1000) * ch * width
    frames = [pcm]
    for p in parts[1:]:
        r2, c2, w2, pcm2 = pcm_of(p)
        if (r2, c2, w2) != (rate, ch, width):
            raise ValueError("clip format differs: %s vs %s" % ((r2, c2, w2), (rate, ch, width)))
        frames += [silence, pcm2]
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(ch); w.setsampwidth(width); w.setframerate(rate); w.writeframes(b"".join(frames))
    return out.getvalue()

def mix_wavs(a, b):
    """Two voices at once (lines spoken in unison): sample-wise average, padded to the longer clip."""
    ra, ca, wa, pa = pcm_of(a); rb, cb, wb, pb = pcm_of(b)
    if (ra, ca, wa) != (rb, cb, wb) or wa != 2:
        raise ValueError("clips must share a 16-bit format")
    n = max(len(pa), len(pb)) // 2
    sa = struct.unpack("<%dh" % (len(pa) // 2), pa) + (0,) * (n - len(pa) // 2)
    sb = struct.unpack("<%dh" % (len(pb) // 2), pb) + (0,) * (n - len(pb) // 2)
    mixed = struct.pack("<%dh" % n, *[max(-32768, min(32767, int((x + y) * 0.6))) for x, y in zip(sa, sb)])
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(ca); w.setsampwidth(wa); w.setframerate(ra); w.writeframes(mixed)
    return out.getvalue()
