# Releasing Overlap

Overlap ships without an Apple developer account. Builds are signed with a certificate you make yourself, and
updates reach teammates through Sparkle, which checks each one against Overlap's own signing key. The one thing
Apple's account would add is a first launch with no warning; teammates approve Overlap once instead (see
[INSTALL.md](INSTALL.md)), and updates after that install without asking again.

Releases live on the repository's GitHub Pages, at <https://chasingux.github.io/Overlap/>:

| Path | What it is |
|---|---|
| `index.html` | The install page, from `Pages/index.html`, with a download button |
| `Overlap.zip` | The newest version, for first installs |
| `appcast.xml` | The update feed every installed copy checks once a day |
| `updates/Overlap-<version>.zip` | Every version, downloaded by Sparkle |

## One-time setup

### 1. A code-signing certificate

A certificate of your own gives every build the same identity, so macOS keeps a teammate's folder permissions
from one version to the next. Without one, releases are signed ad hoc and still work, but macOS may ask for
access again after each update.

1. Open **Keychain Access** (in /System/Library/CoreServices/Applications if it isn't in Applications).
2. Choose **Keychain Access > Certificate Assistant > Create a Certificate…**
3. Name it exactly **Overlap Code Signing**. Identity Type: **Self-Signed Root**. Certificate Type: **Code Signing**.
   Click **Create**.
4. Find it under **My Certificates**, double-click it, open **Trust**, and set **Code Signing** to
   **Always Trust**.

The first release you make asks whether codesign may use the key; choose **Always Allow**.

### 2. The update signing key

Updates are signed with a private key kept at
`~/Library/Application Support/Overlap Release/sparkle-private-key`. Its public half is in
`Config/Info.plist` as `SUPublicEDKey`, so every copy of Overlap only accepts updates signed with it.

**Back the private key up**, somewhere private such as a password manager. Without it, copies already installed
can't be updated, and everyone would have to reinstall by hand. Never commit it or share it.

To make releases from another Mac, copy the file to the same place there, or point `OVERLAP_SPARKLE_KEY` at it.

## Making a release

Commit first: each release needs a larger build number than the last, and the script uses the number of commits.

```bash
Scripts/make-release.sh 0.6.0
Scripts/publish-release.sh
```

The first builds Overlap in Release, signs it, zips it, and adds it to the feed in `build/Releases`, signed with
the update key. The second puts it all on GitHub Pages, which serves it within a minute or two; installed copies
find it at their next daily check, or straight away from **Check for Updates…**.

Keep `build/Releases/updates`: every zip there stays in the feed.

## Renaming the app or moving the feed

Every installed copy keeps the feed address in `SUFeedURL`, and GitHub Pages addresses don't follow a renamed
repository. So when the name or the feed's home changes:

1. Set up the new home first, and copy the current feed and zips there.
2. Change `SUFeedURL` in `Config/Info.plist`, and the addresses at the top of both scripts, to the new home.
3. Make a release and publish it to the **old** home as well as the new one.

Installed copies update to that release from the old address, and from then on check the new one. Leave the old
home up for a while for anyone who hasn't opened Overlap since.

The bundle ID, `com.chasingux.overlap`, never shows in the app, so it can stay as it is through a rename. Changing
it would reset everyone's settings.

## Trying a release before sharing it

A release can update from a feed on your own Mac:

```bash
cd build/Releases && python3 -m http.server 8765 --bind 127.0.0.1
```

Make two releases with `--bundle-id` set to a test identifier and `--download-url-prefix http://127.0.0.1:8765/updates/`,
so the test doesn't touch your own copy's settings. Then launch the older one with
`OVERLAP_FEED_URL=http://127.0.0.1:8765/appcast.xml OVERLAP_UPDATE_NOW=1`, and it updates itself straight away.
