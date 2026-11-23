# Mac app

Doppler is a menu bar app: use your shortcut, talk, and the text is pasted where your cursor is.
While you talk, a black island grows out of the notch with an animation that follows your voice
and, if enabled, the text so far. When transcription finishes, it shows a check and the result.

```bash
cd apps/macos && ./build.sh --install     # needs Xcode; no Apple Developer account
open "/Applications/Doppler.app"
```

## Settings

Click the Doppler icon in the menu bar, then **Settings…**.

### General

- **Shortcut**: click and press any combo (⌥Space, ⌃⇧D, F5…) or tap a lone modifier
  (Right ⌥, Right ⌘, Fn).
- **Mode**: Hold to talk or Tap to toggle.
- **Notch**: choose Doppler rings, Waveform or Wave line. **Preview** plays a sample.
- **Input**: language, microphone and maximum transcription time (1–25 minutes).
- **Transcribe audio from apps**: use audio playing in an app instead of your microphone.
  macOS needs System Audio Recording permission for this.
- **After transcribing**: paste the text, restore your clipboard, show live text and play sounds.
- **App**: launch at login and show in the Dock.

### Server

- **Server URL**: `http://127.0.0.1:8000` locally, or your Tailscale `https://…ts.net` URL.
- **Token**: the device token, stored in the Keychain. Leave it empty if the server has no tokens.
- **Model**: optional. Set it for an OpenAI-compatible server that requires a model name.

The connection status updates when Settings opens, and the refresh button checks it again.
Live text needs Doppler Server. Other OpenAI-compatible servers return the text after you stop.

### Permissions

- **Microphone**: records your voice.
- **Accessibility**: pastes the text and detects lone-modifier shortcuts.

## If streaming fails

The app uploads the whole recording to the server instead. If that upload also fails, Doppler
shows an error and the recording is not kept.

## Keep permissions across rebuilds

Ad-hoc signed apps get a new identity every build, so macOS asks for permissions again. To stop
that, create a free local signing certificate once with `apps/macos/Scripts/make_signing_cert.sh`
(a self-signed "Doppler Local" identity in your login keychain). `build.sh` uses it
automatically from then on.
