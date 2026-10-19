# Tunelet

A menu-bar guitar tuner for macOS 26. Guitar and chromatic modes, user-defined 6-string tunings, A4 calibration. The microphone is only on while the tuning popover is open. See [DESIGN.md](DESIGN.md) for the design and the reasoning behind it.

Builds with the Xcode Command Line Tools alone; Xcode isn't needed.

## Scripts

| Command | What it does |
|---|---|
| `scripts/test.sh` | Runs the test suite. Use this rather than a bare `swift test` (see DESIGN.md). |
| `scripts/bundle.sh [debug]` | Builds `build/Tunelet.app` (release by default) and signs it. |
| `scripts/install.sh [--open]` | Release build, quits a running Tunelet, installs to `~/Applications`, and optionally launches it. |
| `swift run tunelet-probe [seconds]` | Prints live pitch readings from the mic, for checking detection against a real guitar. |

## Code signing (one-time setup)

macOS remembers microphone permission against the app's signature. Ad-hoc signatures change on every build, so without a stable identity you'll be asked for mic access again after each rebuild.

1. Open **Keychain Access** and choose **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Set **Name** to `Tunelet Dev` (any name works), **Identity Type** to **Self Signed Root**, and **Certificate Type** to **Code Signing**, then click **Create**.
3. Tell the build scripts to use it:
   ```sh
   echo "Tunelet Dev" > .signing-identity
   ```
   `.signing-identity` is gitignored. Setting `TUNELET_SIGN_IDENTITY` works too and takes precedence.
4. Run `scripts/install.sh --open`. The first build signed with the certificate asks for mic access once, and later rebuilds don't.

The first time `codesign` uses the new key, Keychain may ask for permission. Choose **Always Allow**.
