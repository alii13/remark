"""Remark transcription sidecar.
Reads 16 kHz mono float32 little-endian PCM from stdin (the mixed meeting audio),
segments speech with an energy gate, transcribes each segment on-device with
Parakeet, and writes newline-delimited JSON to stdout:

  {"type":"ready"}                                  once the model is warm
  {"type":"partial","text":...}                     while someone is speaking
  {"type":"final","text":...,"t0":sec,"t1":sec}     when they pause

No audio ever leaves the machine; stdout carries text only.
"""
import sys, json, time
import numpy as np
import sherpa_onnx

MODEL = sys.argv[1] if len(sys.argv) > 1 else "models/parakeet"
SR = 16000
FRAME = 320                 # 20 ms
START_RMS = 0.015           # speech onset
SILENCE_RMS = 0.008         # below this counts as silence
HANGOVER = int(0.6 * SR)    # 0.6 s of silence ends a segment
MAX_SEG = int(14 * SR)      # force a decode after 14 s
PARTIAL_EVERY = int(1.2 * SR)
PREROLL = int(0.25 * SR)

def log(m): sys.stderr.write(m + "\n"); sys.stderr.flush()

rec = sherpa_onnx.OfflineRecognizer.from_transducer(
    encoder=f"{MODEL}/encoder.int8.onnx", decoder=f"{MODEL}/decoder.int8.onnx",
    joiner=f"{MODEL}/joiner.int8.onnx", tokens=f"{MODEL}/tokens.txt",
    num_threads=4, sample_rate=SR, feature_dim=80,
    decoding_method="greedy_search", model_type="nemo_transducer")

def decode(samples: np.ndarray) -> str:
    s = rec.create_stream()
    s.accept_waveform(SR, samples)
    rec.decode_stream(s)
    return s.result.text.strip()

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()

# warm the model so the first real decode is fast
decode(np.zeros(SR // 2, dtype=np.float32))
emit({"type": "ready"})

ring = np.zeros(0, dtype=np.float32)   # rolling pre-roll of recent audio
seg = np.zeros(0, dtype=np.float32)    # current speech segment
in_speech = False
silence = 0
seg_start = 0.0
last_partial = 0
total = 0

while True:
    raw = sys.stdin.buffer.read(FRAME * 4)
    if not raw:
        break
    frame = np.frombuffer(raw, dtype=np.float32)
    if frame.size == 0:
        continue
    total += frame.size
    rms = float(np.sqrt(np.mean(frame * frame)))

    if not in_speech:
        ring = np.concatenate([ring, frame])[-PREROLL:]
        if rms >= START_RMS:
            in_speech = True
            seg = np.concatenate([ring, frame])
            ring = np.zeros(0, dtype=np.float32)
            silence = 0
            seg_start = (total - seg.size) / SR
            last_partial = seg.size
        continue

    seg = np.concatenate([seg, frame])
    silence = silence + frame.size if rms < SILENCE_RMS else 0

    if seg.size - last_partial >= PARTIAL_EVERY and silence == 0:
        txt = decode(seg)
        last_partial = seg.size
        if txt:
            emit({"type": "partial", "text": txt})

    if silence >= HANGOVER or seg.size >= MAX_SEG:
        speech = seg[:seg.size - silence] if silence else seg
        txt = decode(speech) if speech.size > FRAME else ""
        if txt:
            emit({"type": "final", "text": txt,
                  "t0": round(seg_start, 2), "t1": round(seg_start + speech.size / SR, 2)})
        in_speech = False
        seg = np.zeros(0, dtype=np.float32)
        silence = 0

# flush a segment still open when the stream ends (capture stopped)
if in_speech and seg.size > FRAME:
    txt = decode(seg)
    if txt:
        emit({"type": "final", "text": txt,
              "t0": round(seg_start, 2), "t1": round(seg_start + seg.size / SR, 2)})
