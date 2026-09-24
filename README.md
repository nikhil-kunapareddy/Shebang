# Shebang

> An AI desktop assistant for macOS and Windows. Focus an app, press the chord, and say what to do.

Shebang reads the accessible UI controls of the app you are working in, picks each next action with the **Jev** decision model (`typesafe-ai/jev`) via **Vercel AI Gateway**, then clicks, types, and verifies the outcome in real time.

| | macOS | Windows |
|---|---|---|
| **Chord** | **Control + Command** (⌃⌘) | **Ctrl + Win** |
| **Source** | [`macos/`](macos) (Swift package) | [`windows/`](windows) (.NET 8 solution) |
| **Requires** | macOS 14 or later | Windows 10 (build 19041+) or Windows 11 |

Both builds share the configuration template [`.env.example`](.env.example) and need a Vercel AI Gateway API key.

---

## macOS

### Requirements

- macOS 14 Sonoma or later, Apple Silicon or Intel.
- A Vercel AI Gateway API key.
- To build from source: a Swift 6 toolchain (Xcode 16 or later, or its Command Line Tools).

### Installation

**From a release:** download `Shebang-v<version>-macos-arm64.zip` (Apple Silicon) from the [Releases](https://github.com/nikhil-kunapareddy/Shebang/releases/latest) page, unzip it, and move `Shebang.app` to `/Applications`. Release builds are not notarized; if macOS refuses to open the app, allow it under **System Settings > Privacy & Security > Open Anyway**. On an Intel Mac, build from source.

**From source:**

```bash
git clone https://github.com/nikhil-kunapareddy/Shebang.git
cd Shebang/macos

swift build                        # debug build of the app and the shebang CLI
./Scripts/test.sh                  # run the Swift Testing suites
./Scripts/build-app.sh             # build and sign dist/Shebang.app
./Scripts/build-app.sh --install   # also replace /Applications/Shebang.app
./Scripts/build-app.sh --zip       # also write dist/Shebang-v<version>-macos-<arch>.zip (+ .sha256)
```

`test.sh` also works with only the Command Line Tools installed. `build-app.sh` bundles the menu bar app and the `shebang` CLI (`Shebang.app/Contents/Helpers/shebang`).

**Signing caveat:** `build-app.sh` signs with `SIGN_IDENTITY` if set, otherwise with the first "Developer ID Application" or "Apple Development" identity in your keychain. Without one it falls back to ad-hoc signing, which works locally but macOS forgets the Accessibility grant every time the binary changes: re-grant Accessibility after each rebuild or update (remove the old Shebang entry and add it again). A stable identity keeps the grant:

```bash
SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./Scripts/build-app.sh --install
```

### First Launch

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
| `ZERO_DATA_RETENTION` | `false` | Request zero data retention from the gateway (`AI_GATEWAY_ZERO_DATA_RETENTION` also works) |
| `DECISION_CONFIDENCE_THRESHOLD` | `0.0` | Below this confidence Jev asks you instead of acting |
| `DRY_RUN`, `MAX_STEPS_PER_RUN` | CLI: dry-run, 10 steps | Execution mode and step limit for `shebang run` |

### Permissions

Grant these in **System Settings > Privacy & Security**:

| Permission | Used for | Required |
|---|---|---|
| **Accessibility** | Reading controls, clicking and typing, and the ⌃⌘ hotkey | Yes |
| **Screen Recording** | OCR fallback (Vision) for apps that expose no accessible controls | Optional |
| **Microphone** | Spoken instructions | Optional |
| **Speech Recognition** | Transcribing spoken instructions | Optional |

When you run the `shebang` CLI from a terminal, macOS applies these grants to the terminal app (Terminal, iTerm2, ...), not to Shebang.app.

### How to Use

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

### Developer CLI

`shebang` checks your setup, shows what Shebang perceives, and runs the agent loop from a terminal. Run it with `swift run shebang <command>` in `macos/`, or from the app bundle at `/Applications/Shebang.app/Contents/Helpers/shebang`.

```bash
shebang check                                    # API key (masked), permissions, live Jev call
shebang read --target Safari                     # ranked elements: id, role, state, frame, label, value, source
shebang read                                     # 3-second countdown, then the frontmost app
shebang run "search for Adele" --target Music    # dry-run unless DRY_RUN=false
shebang run "calculate 450 * 12 + 85" --target Calculator --live
shebang help
```

- `--target` (alias `--process`) takes an app name, bundle identifier, or pid of a running app. Without it, `read` and `run` count down 3 seconds and capture the frontmost app, so switch to the target app during the countdown; the CLI cannot skip the terminal it runs in, and refuses live runs against it.
- `run` simulates actions unless `DRY_RUN=false` is set; `--dry-run` and `--live` override the environment. `dry-run "<goal>"` is shorthand for `run --dry-run`. Runs stop after `--max-steps` (default `MAX_STEPS_PER_RUN`, else 10; 0 = unlimited) or when the screen stops changing.
- `run --confirm-risky` has Jev score each click and asks `[y/N]` in the terminal before high-risk ones.
- **Ctrl-C** cancels a run cleanly and prints the cancelled result; a second Ctrl-C quits immediately.
- `check` reads a key saved by the app from the Keychain; macOS may ask once to allow the CLI access.
- Exit status: 0 success, 1 failure, 2 usage error.

### Safety & Privacy

- **Secure text fields are never read:** password fields (`AXSecureTextField`) are dropped with their contents before any value is requested.
- **Secrets are redacted:** card numbers, API keys (`vck_`, `sk-`, `ghp_`), JWTs, and bearer tokens in visible text are replaced before anything reaches the model. API keys are never logged and are scrubbed from gateway error messages.
- **Password managers are never automated:** 1Password, Bitwarden, KeePass/KeePassXC, LastPass, Dashlane, Enpass, Authenticator, Keychain Access, and Passwords are deny-listed by app name or bundle identifier, checked at the start of a run and whenever the target app changes.
- **Deletion is prohibited:** a goal, target control, or typed text containing *delete, deletion, erase, wipe, destroy, truncate, format,* or *del* stops the run. The default policy asks for no confirmation otherwise, as on Windows.
- **Local audit log:** every decision (auto, confirmed, rejected, denied, prohibited) is appended as JSON lines to `~/Library/Application Support/Shebang/audit/audit-YYYY-MM-DD.jsonl` (UTC dates).
- **What leaves your Mac:** only the Jev requests, which carry the goal and a compact text description of the visible controls (no screenshots). OCR runs locally; speech recognition runs on-device when your Mac supports it for the language, otherwise it uses Apple's speech service.

### Architecture: Windows to macOS

| Concern | Windows | macOS |
|---|---|---|
| **Language & runtime** | C# on .NET 8 | Swift 6 toolchain (Swift 5 language mode), Swift Package Manager |
| **UI** | WPF acrylic popup + system tray | SwiftUI/AppKit menu bar app with a prompt panel |
| **Screen reading** | UI Automation (`FlaUI.UIA3`) with `CacheRequest` batching | Accessibility API (`AXUIElement`) with batched attribute reads; web trees of Chromium/Electron apps enabled on demand |
| **OCR fallback** | `Windows.Media.Ocr` | Vision (`VNRecognizeTextRequest`) on ScreenCaptureKit window captures |
| **Input & execution** | UIA control patterns with `SendInput` fallback | AX actions (`AXPress`, `AXValue`, `AXFocused`) with `CGEvent` fallback |
| **Global hotkey** | Low-level keyboard hook (`WH_KEYBOARD_LL`) | `CGEventTap` feeding the same pure chord state machine |
| **Credentials** | Windows Credential Manager | Keychain |
| **Speech** | Whisper.net (local `ggml-tiny` model) | `SFSpeechRecognizer` (on-device when supported) |
| **App launching** | `Process.Start` (shell execute) | NSWorkspace / Launch Services, Spotlight name lookup |
| **Audit log** | `%LOCALAPPDATA%\Shebang\audit` | `~/Library/Application Support/Shebang/audit` |
| **AI decision model** | `typesafe-ai/jev` via Vercel AI Gateway (`/v1/evaluate`) | Same |

The package splits into `ShebangCore` (models, Jev client, risk policy, agent loop; no AppKit), `ShebangPlatform` (Accessibility, Vision, CGEvent, Keychain, speech), `ShebangApp` (menu bar app), and `ShebangCLI` (`shebang`).

---

## Windows

> A Windows-native AI desktop assistant. Focus an app, press **Ctrl + Win**, and tell it what to do.

Shebang reads accessible UI controls via Windows UI Automation, selects actions with Jev via Vercel AI Gateway, types, clicks, and verifies the outcome in real time.

### Download & Installation

1. **Download the latest release:**
   Download `Shebang-v0.1.0-win-x64.zip` from the [Releases](https://github.com/nikhil-kunapareddy/Shebang/releases/latest) page.
2. **Extract the archive:**
   Extract the zip file to any folder on your PC (e.g. `C:\Shebang`).
   *(No .NET runtime installation required: everything is self-contained and compiled with ReadyToRun.)*
3. **Configure your API key:**
   Copy `.env.example` to `.env` in the extracted folder and add your Vercel AI Gateway API key:
   ```ini
   AI_GATEWAY_API_KEY=vck_your_api_key_here
   AI_GATEWAY_ZERO_DATA_RETENTION=false
   ```
4. **Test your setup:**
   Double-click `CHECK_CONNECTION.bat` (or run `Shebang.Cli.exe check`). It tests the connection to Jev via Vercel AI Gateway.
5. **Start Shebang:**
   Double-click `START_SHEBANG.bat` (or run `Shebang.App.exe`). Shebang runs silently in your Windows System Tray.

### How to Use

1. **Focus any application** on your PC (Notepad, Calculator, Google Chrome, Microsoft Edge, Spotify, etc.).
2. Press the global chord **Ctrl + Win**.
3. The dark acrylic Shebang popup appears immediately above your target app.
4. Type your instruction, for example:
   - *"Write a meeting agenda for tomorrow's sprint review"*
   - *"Calculate 450 * 12 + 85"*
   - *"Search for Adele on Spotify"*
5. Press **Enter** to submit.
6. **Kill Switch:** press **Ctrl + Win** again, press **Esc**, or click **Stop** at any moment to cancel automation immediately.

### Safety & Invariants

- **Risk policy:** safe actions run automatically; deletion operations (*delete, erase, wipe, destroy, truncate, format, del*) are strictly prohibited.
- **Confirmation dialog:** when an action is flagged for approval, the dialog shows the exact action, target control, and window title. Press **Enter** to approve or **Esc** to reject.
- **Privacy & redaction:** password fields (`IsPassword=true`) and credit cards / tokens are never captured or sent to the model.
- **App deny-list:** password managers (1Password, Bitwarden, KeePass, etc.) are strictly blocked from automation.
- **Local audit log:** every action, decision, and risk score is logged locally to `%LOCALAPPDATA%\Shebang\audit`.

### Architecture & Windows Stack

| Concern | Windows Implementation |
|---|---|
| **Language & Runtime** | C# on .NET 8 LTS (`net8.0-windows10.0.19041.0`) |
| **UI** | WPF acrylic popup + system tray integration |
| **Screen Reading** | Windows UI Automation (`FlaUI.UIA3`) with `CacheRequest` batching |
| **OCR Fallback** | `Windows.Media.Ocr` (built-in, private, local on-device) |
| **Input & Execution** | UIA Control Patterns (Invoke, Value, Toggle, Scroll) with `SendInput` fallback |
| **Global Hotkey** | Low-level keyboard hook (`WH_KEYBOARD_LL`) with pure chord state machine & Start-menu suppression |
| **AI Decision Model** | `typesafe-ai/jev` via Vercel AI Gateway (`/v1/evaluate`) |

### Building from Source

**Prerequisites**
- Windows 10 (build 19041+) or Windows 11 (x64 or ARM64)
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)

**Build & Test**
```powershell
git clone https://github.com/nikhil-kunapareddy/Shebang.git
cd Shebang

# Run all 71 unit and integration tests
dotnet test windows/Shebang.sln

# Publish self-contained ReadyToRun release
dotnet publish windows/src/Shebang.App/Shebang.App.csproj -c Release -r win-x64 --self-contained true -p:PublishReadyToRun=true -o dist/Shebang-win-x64
```

---

## License

Licensed under the [MIT License](LICENSE).
