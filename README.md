# Shebang

> An AI desktop assistant for macOS. Focus an app, press **Control + Command** (⌃⌘), and say what to do.

Shebang reads the accessible UI controls of the app you are working in, picks each next action with the **Jev** decision model (`typesafe-ai/jev`) via **Vercel AI Gateway**, then clicks, types, and verifies the outcome in real time.

---

## Requirements

- macOS 14 Sonoma or later, Apple Silicon or Intel.
- A Vercel AI Gateway API key.
- To build from source: a Swift 6 toolchain (Xcode 16 or later, or its Command Line Tools).

## Installation

**From a release:** download `Shebang-v<version>-macos-arm64.dmg` (Apple Silicon) from the [Releases](https://github.com/nikhil-kunapareddy/Shebang/releases/latest) page, open it, and drag **Shebang** onto the **Applications** folder. A `.zip` of the same app is attached too. Release builds are ad-hoc signed and not notarized; if macOS refuses to open the app, allow it under **System Settings > Privacy & Security > Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Shebang.app`. On an Intel Mac, build from source.

CI publishes a release automatically when a push to `main` carries a new `CFBundleShortVersionString` in `macos/Resources/Info.plist`. Every CI run (including pull requests) also attaches the DMG and zip as a workflow artifact, downloadable from the run's page under **Actions**.

**From source:**

```bash
git clone https://github.com/nikhil-kunapareddy/Shebang.git
cd Shebang/macos

swift build                        # debug build of the app and the shebang CLI
./Scripts/test.sh                  # run the Swift Testing suites
./Scripts/build-app.sh             # build and sign dist/Shebang.app
./Scripts/build-app.sh --install   # also replace /Applications/Shebang.app
./Scripts/build-app.sh --zip       # also write dist/Shebang-v<version>-macos-<arch>.zip (+ .sha256)
./Scripts/build-app.sh --dmg       # also write the drag-to-install dist/Shebang-v<version>-macos-<arch>.dmg (+ .sha256)
```

`test.sh` also works with only the Command Line Tools installed. `build-app.sh` bundles the menu bar app and the `shebang` CLI (`Shebang.app/Contents/Helpers/shebang`). It assembles and signs the bundle in a temporary folder, because iCloud Drive (for example `~/Documents`) adds Finder metadata that code signing rejects; `--install`, `--zip`, and `--dmg` use that clean copy. `--dmg` needs [dmgbuild](https://github.com/dmgbuild/dmgbuild) (`pip install dmgbuild`, Python 3.10 or later); `Scripts/make-dmg-background.swift` redraws the DMG window background.

**Signing caveat:** `build-app.sh` signs with `SIGN_IDENTITY` if set, otherwise with the first "Developer ID Application" or "Apple Development" identity in your keychain. Without one it falls back to ad-hoc signing, which works locally but macOS forgets the Accessibility grant every time the binary changes: re-grant Accessibility after each rebuild or update (remove the old Shebang entry and add it again). A stable identity keeps the grant:

```bash
SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./Scripts/build-app.sh --install
```

## First Launch

Shebang runs in the menu bar (no Dock icon). On first launch it asks for your Vercel AI Gateway API key and stores it in your login Keychain (service `com.shebang.mac`, account `AI_GATEWAY_API_KEY`).

Alternatively, use a `.env` file. Shebang applies the first `.env` it finds in:

1. the current working directory (useful for the CLI),
2. `~/Library/Application Support/Shebang/.env`,
3. the folder containing `Shebang.app` (or the `shebang` binary).

Variables already set in the environment are never overridden, and `AI_GATEWAY_API_KEY` from the environment or `.env` takes precedence over the Keychain.

```bash
mkdir -p ~/Library/Application\ Support/Shebang
cp .env.example ~/Library/Application\ Support/Shebang/.env   # then set AI_GATEWAY_API_KEY
```

| Variable | Default | Purpose |
|---|---|---|
| `AI_GATEWAY_API_KEY` | (none) | Vercel AI Gateway API key |
| `AI_GATEWAY_BASE_URL` | `https://ai-gateway.vercel.sh` | Gateway endpoint |
| `JEV_MODEL` | `typesafe-ai/jev` | Decision model |
| `ZERO_DATA_RETENTION` | `false` | Request zero data retention from the gateway |
| `DECISION_CONFIDENCE_THRESHOLD` | `0.0` | Below this confidence Jev asks you instead of acting |
| `DRY_RUN` | app: `false`, CLI: `true` | `true` simulates actions without clicking or typing |
| `MAX_STEPS_PER_RUN` | app: unlimited, CLI: 10 | Step limit per run (`0` = unlimited) |

## Permissions

Grant these in **System Settings > Privacy & Security**:

| Permission | Used for | Required |
|---|---|---|
| **Accessibility** | Reading controls, clicking and typing, and the ⌃⌘ hotkey | Yes |
| **Screen Recording** | OCR fallback (Vision) for apps that expose no accessible controls | Optional |
| **Microphone** | Spoken instructions | Optional |
| **Speech Recognition** | Transcribing spoken instructions | Optional |

When you run the `shebang` CLI from a terminal, macOS applies these grants to the terminal app (Terminal, iTerm2, ...), not to Shebang.app.

## How to Use

1. **Focus any app** (Safari, Notes, Calculator, Music, etc.).
2. Press and release **Control + Command** (⌃⌘) together. The chord only fires when no other key is pressed with it, so shortcuts such as ⌃⌘Q, ⌃⌘Space, and ⌃⌘F keep working.
3. Type (or speak) your instruction in the prompt panel, for example:
   - *"Write a meeting agenda for tomorrow's sprint review"*
   - *"Calculate 450 * 12 + 85"*
   - *"Search for Adele in Music"*
4. Press **Return** to run.
5. **Kill switch:** press **Esc** or **⌃⌘** again at any moment to cancel the run immediately.

While a run is active, a click-through status line near the bottom of the target window shows each step.

The menu bar icon (✋) offers **Run on Current App** (**Stop Run** while running), **Status & Permissions…**, **Set API Key…**, **Open Audit Log Folder**, **Launch at Login**, and **Quit Shebang**.

## Developer CLI

`shebang` checks your setup, shows what Shebang perceives, and runs the agent loop from a terminal. Run it with `swift run shebang <command>` in `macos/`, or from the app bundle at `/Applications/Shebang.app/Contents/Helpers/shebang`.

```bash
shebang check                                    # API key (masked), permissions, live Jev call
shebang read --target Safari                     # ranked elements: id, role, state, frame, label, value, source
shebang read                                     # 3-second countdown, then the frontmost app
shebang run "search for Adele" --target Music    # dry-run unless DRY_RUN=false
shebang run "calculate 450 * 12 + 85" --target Calculator --live
shebang help
```

- `--target` (`-t`) takes an app name, bundle identifier, or pid of a running app. Without it, `read` and `run` count down 3 seconds and capture the frontmost app, so switch to the target app during the countdown; the CLI cannot skip the terminal it runs in, and refuses live runs against it.
- `run` simulates actions unless `DRY_RUN=false` is set; `--dry-run` and `--live` override the environment. `dry-run "<goal>"` is shorthand for `run --dry-run`. Runs stop after `--max-steps` (default `MAX_STEPS_PER_RUN`, else 10; 0 = unlimited) or when the screen stops changing.
- `run --confirm-risky` has Jev score each click and asks `[y/N]` in the terminal before high-risk ones.
- **Ctrl-C** cancels a run cleanly and prints the cancelled result; a second Ctrl-C quits immediately.
- `check` reads a key saved by the app from the Keychain; macOS may ask once to allow the CLI access.
- Exit status: 0 success, 1 failure, 2 usage error.

## Safety & Privacy

- **Secure text fields are never read:** password fields (`AXSecureTextField`) are dropped with their contents before any value is requested.
- **Secrets are redacted:** card numbers, API keys (`vck_`, `sk-`, `ghp_`), JWTs, and bearer tokens in visible text are replaced before anything reaches the model. API keys are never logged and are scrubbed from gateway error messages.
- **Password managers are never automated:** 1Password, Bitwarden, KeePass/KeePassXC, LastPass, Dashlane, Enpass, Authenticator, Keychain Access, and Passwords are deny-listed by app name or bundle identifier, checked at the start of a run and whenever the target app changes.
- **Deletion is prohibited:** a goal, target control, or typed text containing *delete, erase, wipe, destroy, truncate, format, del, rm, rmdir, unlink, shred, srm, Move to Trash, Empty Trash,* or diskutil's *eraseDisk/eraseVolume* stops the run. Other actions run without confirmation.
- **Only offered actions run:** Jev picks from a list of actions Shebang built from the screen and your goal; an answer outside that list makes Shebang ask you instead of acting.
- **Local audit log:** every decision (auto, confirmed, rejected, denied, prohibited) is appended as JSON lines to `~/Library/Application Support/Shebang/audit/audit-YYYY-MM-DD.jsonl` (UTC dates).
- **What leaves your Mac:** only the Jev requests, which carry the goal and a compact text description of the visible controls (no screenshots). OCR runs locally; speech recognition runs on-device when your Mac supports it for the language, otherwise it uses Apple's speech service.

## Architecture

| Concern | Implementation |
|---|---|
| **Language & build** | Swift 6 toolchain (Swift 5 language mode), Swift Package Manager, Swift Testing |
| **UI** | SwiftUI/AppKit menu bar app with a non-activating prompt panel and a click-through run HUD |
| **Screen reading** | Accessibility API (`AXUIElement`) with batched attribute reads; web trees of Chromium/Electron apps enabled on demand |
| **OCR fallback** | Vision (`VNRecognizeTextRequest`) on ScreenCaptureKit window captures |
| **Input & execution** | AX actions (`AXPress`, `AXValue`, `AXFocused`) with `CGEvent` fallback and layout-aware shortcuts |
| **Global hotkey** | `CGEventTap` feeding a pure chord state machine |
| **Credentials** | Keychain |
| **Speech** | `SFSpeechRecognizer` (on-device when supported) |
| **App launching** | NSWorkspace / Launch Services, Spotlight name lookup |
| **AI decision model** | `typesafe-ai/jev` via Vercel AI Gateway (`/v1/evaluate`) |

The package in [`macos/`](macos) splits into `ShebangCore` (models, Jev client, risk policy, agent loop; no AppKit), `ShebangPlatform` (Accessibility, Vision, CGEvent, Keychain, speech), `ShebangApp` (menu bar app), and `ShebangCLI` (`shebang`).

## License

Licensed under the [MIT License](LICENSE).
