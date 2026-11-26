# Contributing to Remark

Thanks for taking a look. Remark is a small Swift app with a clear pipeline, so most changes touch one file. This page tells you how to set it up, what to work on, and how to send a change.

## Set up your machine

You need macOS 14.4 or newer and the [Claude CLI](https://docs.claude.com/en/docs/claude-code) on your `PATH`.

1. Fork the repo on GitHub and clone your fork.
2. Set up the transcription sidecar: a Python virtualenv and the Parakeet model. `sidecar/` has the sherpa-onnx install steps and the model files it expects under `./models/parakeet`.
3. Build and run:
   ```bash
   bash build.sh
   open build/Remark.app
   ```
   `build.sh` ad-hoc signs the app, which is enough to run it locally. The Core Audio tap and the Keychain encryption behave best under a real Developer ID; set `REMARK_SIGN_IDENTITY` and `REMARK_NOTARY_PROFILE` and run `bash build.sh notarize` when you need that.

Remark reads and writes its runtime data under `~/remark` (the model, `learnings.md`, the encrypted `context/`).

## Find your way around

The README's "How it works" table maps each pipeline stage to its file. Read the one file for the stage you want to change:

- Starting and stopping on a real meeting: `Sources/MeetingDetector.swift`
- Capturing and resampling audio: `Sources/AudioCapture.swift`
- Transcription: `sidecar/transcribe_server.py`
- Writing the question: `Sources/QuestionEngine.swift`
- Remembering past meetings: `Sources/Distiller.swift`, `Sources/ContextStore.swift`
- The menu bar and panel: `Sources/UI/`, `Sources/Theme.swift`

## Work on the question quality

The prompt that writes the questions lives in two places that must stay in sync: the string in `Sources/QuestionEngine.swift`, and a copy in `evals/prompt_v4.txt` that the eval harness reads.

`evals/eval_context.py` scores the prompt against a set of meeting snippets with an LLM judge. Run it before and after a prompt change:

```bash
python3 evals/eval_context.py
```

Put the before and after scores in your pull request so a reviewer can see the change held or improved quality.

## Send a change

- Open an issue first for anything large, so we can agree on the approach before you build it.
- Keep each pull request to one change.
- In the description, say what the change does and how you checked it. If you changed the prompt or the context code, include the eval scores.
- Match the style of the file you edit. The Swift here uses small functions, early returns, and few comments; a comment explains why, not what.
- Do not commit personal data. `learnings.md`, the thumbs `journal/`, the encrypted `context/`, the model, and build output are all git-ignored; keep them that way.

## Report a bug or ask for a feature

Open an issue. For a bug, say what you did, what you expected, and what happened, with your macOS version. For a feature, say what you want to do and why the current app does not let you.

## Be kind

Assume good faith, keep it civil, and remember that the person on the other side is giving their time for free.
