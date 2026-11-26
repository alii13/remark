<p align="center">
  <img src="docs/banner.png" alt="Remark" width="100%">
</p>

<p align="center">
  <b>Remark listens to your meeting and whispers the one question worth asking.</b><br>
  It transcribes on your Mac, stays quiet until a question earns its place, and remembers each meeting so the next one picks up where it left off.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014.4%2B-0C0C0D" alt="macOS 14.4+">
  <img src="https://img.shields.io/badge/built%20with-Swift-E8A84C" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-888" alt="MIT">
  <img src="https://img.shields.io/badge/PRs-welcome-E8A84C" alt="PRs welcome">
</p>

---

Remark sits in your menu bar. When a meeting starts it listens, and once in a while - only when it matters - it shows one question you could ask out loud: the edge case nobody handled, the number with no baseline, the decision left hanging. Remark says nothing the rest of the time, because a weak question costs more than silence.

After each meeting, Remark distills what was said into an encrypted note on your Mac. The next meeting opens with a short brief of recurring topics, past decisions, and open threads, so it can ask a real follow-up instead of starting cold.

## Why you might want it

- **It stays quiet.** Most moments earn nothing, so Remark says nothing. You get a question only when one is worth asking.
- **It runs on your Mac.** [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) transcribes the audio locally with the Parakeet model. The audio never leaves the machine. Only the rolling text goes to your Claude subscription to write a question.
- **It remembers.** Remark encrypts each meeting's notes with AES-GCM and keeps the key in your login Keychain. The next meeting gets the gist of the last ones.
- **It learns your taste.** 👍 or 👎 on a question teaches the next meeting which questions you actually want.
- **It does not record your screen.** Remark reads system audio through a Core Audio process tap, which asks for the "System Audio Recording" permission, not screen capture.

## Quick start

You need macOS 14.4 or newer (Core Audio taps landed in 14.4) and the [Claude CLI](https://docs.claude.com/en/docs/claude-code) on your `PATH`.

```bash
# 1. Put the Parakeet model files under ./models/parakeet (see Credits for the source).

# 2. Build. This fetches the sherpa-onnx library, compiles, and ad-hoc signs the app.
bash build.sh
open build/Remark.app
```

The first launch asks for **Microphone** and **System Audio Recording**. After that Remark lives in the menu bar and appears on its own when you join a meeting.

- Ask on demand: press ⌥Q, or click **ask now** in the panel.
- Thumbs on a question teach the next meeting. Remark writes them to `~/remark/learnings.md`.

Ad-hoc signing runs the app, but the Core Audio tap and the Keychain-backed encryption work cleanly only under a real **Developer ID**. To sign, notarize, and install to `/Applications`, set your own credentials and run `build.sh notarize`:

```bash
export REMARK_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export REMARK_NOTARY_PROFILE="your-notarytool-profile"   # from: xcrun notarytool store-credentials
bash build.sh notarize
```

Remark keeps its runtime data under `~/remark`: the Parakeet model, `learnings.md`, and the encrypted `context/`.

## How it works

Remark is a pipeline. Each stage lives in one file, so you can read it end to end.

| Stage | File | What it does |
| --- | --- | --- |
| Detect the meeting | `Sources/MeetingDetector.swift` | Starts only when a real meeting app (Zoom, Teams, a Slack huddle, a browser call) holds the mic. It ignores dictation and background mic use, and reads no calendar. |
| Capture the audio | `Sources/AudioCapture.swift` | Taps system output (and the mic if you turn it on) through Core Audio, and converts it to 16 kHz mono. It adapts to the output device's real sample rate, so Bluetooth headsets still transcribe. |
| Transcribe it | `Sources/Recognizer.swift` | Runs the Parakeet model in-process through sherpa-onnx (no Python). No audio leaves the machine. |
| Write the question | `Sources/QuestionEngine.swift` | Feeds the rolling transcript to a warm `claude -p` session, which answers with one line, `gap \| question`, or `-` to stay silent. |
| Remember the meeting | `Sources/Distiller.swift`, `Sources/ContextStore.swift` | When the meeting ends, a one-shot `claude` distills the transcript, and Remark encrypts the result and folds it into a running profile. |

The SwiftUI layer (`Sources/UI/`, `Sources/Theme.swift`) draws the menu bar, the floating panel, and the onboarding flow.

## Contributing

Remark is small and the pipeline is easy to follow, so it is a good project to pick up. Pull requests are welcome.

**Set up to hack on it**

1. Fork the repo and clone your fork.
2. Put the Parakeet model files under `models/parakeet` (see Credits for the source).
3. Run `bash build.sh` and `open build/Remark.app`.
4. The question prompt and its quality checks live in `evals/`. Run the quality gate with `python3 evals/eval_context.py`; it scores the shipped prompt against a set of meeting snippets.

**Good places to start**

- Wire up the ChatGPT/Codex engine. The menu offers it, but it still routes to Claude (`Sources/QuestionEngine.swift`, `Sources/AppState.swift`).
- Bundle the Geist font. Without it, the UI falls back to the system font.
- Sharpen the question prompt. Change `evals/prompt_v4.txt` (and the matching string in `QuestionEngine.swift`), then run `evals/eval_context.py` and show the before and after scores in your PR.

**Sending a change**

- Keep each pull request to one change, and say in the description what it changes and how you checked it.
- Match the style of the file you are editing. The Swift here leans on small functions, early returns, and few comments.
- If you touch the question prompt or the context code, run `evals/eval_context.py` and put the scores in the PR.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the longer version.

## Privacy

- Your audio never leaves your Mac. Transcription runs fully on-device.
- Remark encrypts each meeting's notes and the derived profile with AES-GCM, keyed from your login Keychain.
- Writing a question sends the rolling transcript text to your own Claude subscription. That text is the only thing that leaves the machine.
- `learnings.md` and the thumbs journal stay in plain text on your Mac, and git ignores them.
- While Remark captures audio, macOS shows its small recording indicator. That is the OS privacy floor, and no app can turn it off.

## Status

Remark is early and personal. Known rough edges, which double as the list above of places to help:

- The ChatGPT/Codex engine option routes to Claude.
- The UI falls back to the system font unless you install Geist.
- You fetch the Parakeet model separately; it is not bundled (the build fetches the sherpa-onnx library for you).

## License

MIT. See [LICENSE](LICENSE).

## Credits

Remark stands on [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) and the Parakeet model for on-device transcription, and on the [Claude CLI](https://docs.claude.com/en/docs/claude-code) to write the questions.
