# Building IrohServer

The Xcode project is **generated**, not committed. [`project.yml`](project.yml)
is the source of truth; `IrohServer.xcodeproj` is a build artifact and is
gitignored. Never edit the project in Xcode's Build Settings pane — the next
`xcodegen generate` silently discards it. Edit `project.yml` instead.

## One-time setup

```bash
brew install xcodegen swiftlint
```

SwiftLint is optional for a build — the lint phase degrades to a warning when
it is missing — but CI and the build phase both assume it, so install it.

Xcode must be the active developer directory. A machine with only Command Line
Tools installed fails with `tool 'xcodebuild' requires Xcode`:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

To avoid the `sudo` — or to build against a specific Xcode — set `DEVELOPER_DIR`
per-command instead. Every `xcodebuild` line below was verified this way:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Generate

After every edit to `project.yml`, and after a fresh clone:

```bash
cd app
xcodegen generate
```

This writes `IrohServer.xcodeproj` **and** `Sources/Info.plist` — both
gitignored, both derived from `project.yml`. Then:

```bash
open IrohServer.xcodeproj
```

## Build and test

```bash
cd app

xcodebuild -project IrohServer.xcodeproj -scheme IrohServer \
           -configuration Debug build

xcodebuild -project IrohServer.xcodeproj -scheme IrohServer \
           -destination 'platform=macOS' test
```

`test` is noisy: `Unable to get synchronousRemoteObjectProxy … com.apple.linkd`
appears repeatedly and is harmless simulator/XPC chatter, not a failure. Filter
to the outcome:

```bash
xcodebuild -project IrohServer.xcodeproj -scheme IrohServer \
           -destination 'platform=macOS' test 2>&1 \
  | grep -E 'error|✔|✘|BUILD|TEST'
```

## Lint

Rules live in [`.swiftlint.yml`](.swiftlint.yml) at the repo root — one config
for `app/Sources` and `app/Tests` both. Run it directly from the repo root:

```bash
swiftlint                 # lint
swiftlint --fix           # autocorrect what can be corrected
swiftlint rules           # the full catalog, with each rule's default state
```

The same rules run as a `SwiftLint` build phase on the `IrohServer` target, so
violations show up as Xcode warnings. That phase is declared in `project.yml`,
**not** added through Xcode's UI — a hand-added run script disappears at the
next `xcodegen generate`, exactly like a hand-edited build setting. It needs
`ENABLE_USER_SCRIPT_SANDBOXING: NO` (already set) to read the config at the
repo root, and it `cd`s to the root first so the command line and Xcode resolve
the same paths.

The phase also prepends the Homebrew prefixes to `PATH`. Xcode.app does not
inherit your shell's `PATH`, so without that line a Homebrew-installed
SwiftLint is invisible to the build and the phase takes its "not installed"
branch — the build still succeeds, and nothing is linted. If you install
SwiftLint somewhere else (Mint, an SPM plugin, `/usr/local` on Intel), add that
directory to the `export PATH` line in `project.yml`. To confirm lint is really
running inside Xcode, check the build log for the `SwiftLint` phase: the
"not installed" warning means it silently skipped.

To change what is enforced, edit `.swiftlint.yml` — no regeneration needed,
since the phase reads the config at build time. Regenerate only if you change
the phase itself.

Violations are warnings by default. To make them fail a build instead:

```bash
swiftlint --strict
```

## Verify bundle identity

The settings most worth checking after a regeneration — a stray `LSUIElement`
silently strips the Dock icon rather than failing the build, which is why
[`Tests/BundleConfigurationTests.swift`](Tests/BundleConfigurationTests.swift)
asserts it too:

```bash
plutil -p ~/Library/Developer/Xcode/DerivedData/IrohServer-*/Build/Products/Debug/IrohServer.app/Contents/Info.plist \
  | grep -E 'CFBundleIdentifier|CFBundleShortVersion|LSUIElement'
```

Expected — two matches, and no `LSUIElement` line at all:

```
"CFBundleIdentifier" => "dev.irohserver.app"
"CFBundleShortVersionString" => "0.1.0"
```

Confirm the generated project stays out of git:

```bash
git check-ignore -v app/IrohServer.xcodeproj/project.pbxproj
```

## Clean

```bash
xcodebuild -project IrohServer.xcodeproj -scheme IrohServer clean
rm -rf ~/Library/Developer/Xcode/DerivedData/IrohServer-*
rm -rf IrohServer.xcodeproj Sources/Info.plist   # fully regenerable
```

## Signing

The default is **ad-hoc** (`CODE_SIGN_IDENTITY: "-"`), so a clean clone builds
with no Apple account configured. Xcode notes `Disabling hardened runtime with
ad-hoc codesigning` — expected, and fine until M0.

Ad-hoc cannot carry an entitlement that requires a provisioning profile. The
shared keychain access group is one, so it is commented out in `project.yml`;
enabling it before setting a Team ID fails with `"IrohServer" requires a
provisioning profile`. At M0, change both together:

```yaml
CODE_SIGN_STYLE: Automatic
DEVELOPMENT_TEAM: <10-char Team ID>
CODE_SIGN_IDENTITY: "Developer ID Application"
```

then uncomment the `entitlements:` block. The Team ID is also what the daemon's
XPC peer validation pins (§2.3), so M0 needs it regardless.
