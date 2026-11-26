# Transcription sidecar

`transcribe_server.py` reads raw 16 kHz mono float32 audio from stdin and prints newline-delimited JSON to stdout, one `partial` or `final` object per utterance. It runs the Parakeet model through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) on your machine, so no audio leaves it.

## Install

From the repo root:

```bash
python3 -m venv sidecar/.venv
sidecar/.venv/bin/pip install -r sidecar/requirements.txt
```

## Get the model

The app loads a Parakeet transducer (int8) from `models/parakeet/`. Download one from the sherpa-onnx [pre-trained ASR models](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/index.html) and put these four files under `models/parakeet/`:

- `encoder.int8.onnx`
- `decoder.int8.onnx`
- `joiner.int8.onnx`
- `tokens.txt`

The app passes this directory to the sidecar as its one argument.

## Run it by hand

```bash
sidecar/.venv/bin/python sidecar/transcribe_server.py models/parakeet < audio.f32
```

`audio.f32` is raw little-endian 32-bit float samples at 16 kHz, mono. The app feeds this stream live; you only run it by hand to test the model.
