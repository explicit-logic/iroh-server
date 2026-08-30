# Building IrohServer

The Xcode project is **generated**, not committed. [`project.yml`](project.yml)
is the source of truth; `IrohServer.xcodeproj` is a build artifact and is
gitignored. Never edit the project in Xcode's Build Settings pane — the next
`xcodegen generate` silently discards it. Edit `project.yml` instead.

## One-time setup

```bash
brew install xcodegen
```

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
