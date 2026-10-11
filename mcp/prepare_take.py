"""Word times for one take: Takes runs it when it saves a take, and before a cut (2026-10-11). Free,
on this Mac, no key: faster-whisper (model "small", about 500 MB, downloaded once).

  uv run -q --python 3.11 --with faster-whisper --with numpy prepare_take.py IN.wav OUT.json \
      [--language en] [--hints "Takes,Acme"] [--model small]

IN is a 16 kHz mono 16-bit WAV on the take's video clock (takes_mcp.extract_voice). OUT gets
{"language", "words": [{"word", "start", "end"}], "sounds": [[start, end], ...]} in seconds of IN.
Whisper puts a word's edges in the pauses around it: each edge then moves to the sound (10 ms
loudness frames), and a word after a pause starts at its voice onset. "sounds" are voiced
stretches no word covers (a breath, a click, a cough).

Progress: "TAKES_PROGRESS 0.4" lines (the Jobs row reads them); the first comes at once, so Takes
knows uv got the packages. A failure ends with one plain line
that says what to do (the Jobs row shows the last line): exit 3 when the model did not download.
"""
import argparse
import json
import sys
import wave

DOWNLOAD_ERROR = ("Takes could not download the speech model. Connect to the internet. "
                  "Takes tries again at the next cut.")
HOP = 0.01          # seconds per loudness frame
VOICED_DB = 10.0    # a frame this far over the quiet floor (20th percentile) is voiced
SNAP_MAX = 0.3      # an edge moves at most this far, and at most half the word
END_PAD = 0.03      # an end keeps this much after the last voiced frame
SOUND_MIN = 0.12    # a voiced stretch this long with no word is a sound
SOUND_CLEAR = 0.05  # ... when no word is this close
PAUSE = 0.15        # a word this far after the word before it (or the first word) starts at its voice onset
ONSET_GAP = 0.12    # a word's own sound has no silence longer than this inside it
WORD_MIN = 0.08     # an onset start stays at least this far before the word's end


def say(line):
    print(line, flush=True)


def cached(model):
    try:
        from huggingface_hub import try_to_load_from_cache
        hit = try_to_load_from_cache("Systran/faster-whisper-" + model, "model.bin")
        return isinstance(hit, str)
    except Exception:
        return False


def read_wav(path):
    import numpy as np  # here, not at the top: takes_mcp imports onsets() without numpy
    with wave.open(path, "rb") as w:
        sr, n, width, ch = w.getframerate(), w.getnframes(), w.getsampwidth(), w.getnchannels()
        raw = w.readframes(n)
    if width != 2:
        raise SystemExit("prepare_take.py needs a 16-bit WAV.")
    x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def voiced_frames(x, sr):
    import numpy as np
    hop = max(1, int(sr * HOP))
    k = len(x) // hop
    if k == 0:
        return np.zeros(0, dtype=bool)
    rms = np.sqrt((x[:k * hop].reshape(k, hop) ** 2).mean(axis=1))
    db = 20 * np.log10(rms + 1e-9)
    return db > np.percentile(db, 20) + VOICED_DB


def snap(words, voiced):
    """A start in silence moves forward to the first voiced frame; an end in silence moves back to the
    last voiced frame + END_PAD. Never more than SNAP_MAX or half the word."""
    n = len(voiced)

    def at(t):
        return min(n - 1, max(0, int(t / HOP)))
    for w in words:
        if n == 0:
            break
        limit = min(SNAP_MAX, (w["end"] - w["start"]) / 2)
        i = at(w["start"])
        if not voiced[i]:
            for j in range(i, at(w["start"] + limit) + 1):
                if voiced[j]:
                    w["start"] = j * HOP
                    break
        e = at(w["end"] - 1e-6)
        if not voiced[e]:
            for j in range(e, at(w["end"] - limit) - 1, -1):
                if voiced[j]:
                    w["end"] = min(w["end"], (j + 1) * HOP + END_PAD)
                    break
    return words


def onsets(words, voiced):
    """After a pause Whisper starts a word 0.2 to 1 s too early, often more than SNAP_MAX. Such a word
    starts at its voice onset: walk back from its last voiced frame over gaps up to ONSET_GAP. The start
    only moves later, and stays WORD_MIN before the end."""
    n, prev_end = len(voiced), 0.0
    for w in words:
        lo, hi = min(n, max(0, int(w["start"] / HOP))), min(n, int(w["end"] / HOP) + 1)
        k = next((j for j in range(hi - 1, lo - 1, -1) if voiced[j]), None)
        if k is not None:
            onset, quiet, j = k, 0, k
            while j > 0 and quiet * HOP <= ONSET_GAP:
                j -= 1
                if voiced[j]:
                    onset, quiet = j, 0
                else:
                    quiet += 1
            t = min(onset * HOP, w["end"] - WORD_MIN)
            if t > w["start"] and t - prev_end >= PAUSE:
                w["start"] = t
        prev_end = w["end"]
    return words


def sounds(words, voiced):
    out, i, n = [], 0, len(voiced)
    while i < n:
        if not voiced[i]:
            i += 1
            continue
        j = i
        while j < n and voiced[j]:
            j += 1
        a, b = i * HOP, j * HOP
        if b - a >= SOUND_MIN and not any(w["start"] < b + SOUND_CLEAR and w["end"] > a - SOUND_CLEAR for w in words):
            out.append([round(a, 3), round(b, 3)])
        i = j
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("inp")
    p.add_argument("out")
    p.add_argument("--language")
    p.add_argument("--hints", default="")
    p.add_argument("--model", default="small")
    a = p.parse_args()
    say("TAKES_PROGRESS 0")  # the script runs: uv got its packages
    x, sr = read_wav(a.inp)
    if not cached(a.model):
        say("Gets the speech model (one time, about 500 MB).")
    from faster_whisper import WhisperModel
    try:
        model = WhisperModel(a.model, device="cpu", compute_type="int8")
    except Exception as e:  # the download: no internet, a full disk, a proxy
        print("prepare_take: %s" % e, file=sys.stderr)
        say(DOWNLOAD_ERROR)
        sys.exit(3)
    hints = [h.strip() for h in a.hints.split(",") if h.strip()]
    # Never the script itself: Whisper then hears script words that were not said.
    prompt = "Um, uh, so." + (" " + ", ".join(hints) + "." if hints else "")
    segments, info = model.transcribe(a.inp, word_timestamps=True, vad_filter=True,
                                      vad_parameters={"min_silence_duration_ms": 500},
                                      language=a.language or None, initial_prompt=prompt,
                                      condition_on_previous_text=False)
    total = float(info.duration or len(x) / sr) or 1.0
    words = []
    for seg in segments:
        for w in seg.words or []:
            t = (w.word or "").strip()
            if t:
                words.append({"word": t, "start": float(w.start), "end": float(max(w.end, w.start))})
        say("TAKES_PROGRESS %.3f" % min(1.0, float(seg.end) / total))
    voiced = voiced_frames(x, sr)
    words = onsets(snap(words, voiced), voiced)
    for w in words:
        w["start"], w["end"] = round(float(w["start"]), 3), round(float(w["end"]), 3)
    with open(a.out, "w") as f:
        json.dump({"language": info.language, "words": words, "sounds": sounds(words, voiced)}, f)
    say("TAKES_PROGRESS 1")


if __name__ == "__main__":
    main()
