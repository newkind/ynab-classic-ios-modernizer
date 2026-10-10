# YNAB Classic 3.4.3 — iOS App modernization patch

Makes the 2017 YNAB Classic iOS app fill the screen on modern iPhones and iPads instead of running
letterboxed in iPhone 6/6 Plus compatibility mode. It also fixes the layouts that ignore safe areas
or assume a 320pt-wide screen, and adds a **Default cleared status** setting.

## How to use it

You need:

- a **decrypted** YNAB 3.4.3 IPA (see the [FAQ](#faq));
- **Python 3**. Macs ask to install it the first time you run `python3`; on Windows, get it from
  [python.org](https://www.python.org/downloads/) and tick "Add python.exe to PATH" in the installer;
- a sideloading tool such as [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or
  [Sideloadly](https://sideloadly.io) to install the result on your iPhone.

Steps:

1. Download this repository (green **Code** button → **Download ZIP**) and unzip it.
2. Put your **decrypted** YNAB `.ipa` in the unzipped folder, next to `patch.py`.
3. Open a terminal: on a Mac, **Terminal** (search for it with Spotlight); on Windows, **Command
   Prompt** (search the Start menu for `cmd`).
4. Type `python3` (Windows: `python`) and a space, drag `patch.py` into the terminal window, and
   press Enter.
5. The patched app appears in the `build` folder, ending in `-modernized.ipa`. Install that one with
   your sideloading tool.

You can also pass an IPA from anywhere else: `python3 patch.py path/to/YNAB.ipa`.

Before patching, it checks that the IPA is YNAB 3.4.3 (build 263) and decrypted, and stops with an
explanation if not. If the app binary differs from the copy the patch was tested with (usually just
a different decryption tool), it prints a note and carries on.

It installs as a separate app called **YNAB Classic**, next to the original YNAB if you still have it.

Options:

| Option              | Default                             | Effect                                                                                     |
| ------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------ |
| `-o FILE.ipa`       | `build/<input name>-modernized.ipa` | where to write the result                                                                  |
| `--bundle-id ID`    | `com.ynab.ynab-modernized`          | the app's bundle ID; the default installs alongside the original `com.youneedabudget.ynab` |
| `--name NAME`       | `YNAB Classic`                      | home-screen name                                                                           |
| `--version VERSION` | `3.5.0-modernized`                  | version shown in Settings and by sideloading tools                                         |

## Building it yourself

`patch.py` uses the prebuilt `YNABModern.dylib` in this folder. To rebuild it from the sources in
`src/` (needs Xcode):

```
./modernize.sh          # -> YNABModern.dylib, and build/YNAB-modern.ipa
./modernize.sh --sim    # also -> build/sim/YNAB.app for the iOS Simulator (Apple Silicon)
```

`modernize.sh` compiles the library, then runs `patch.py` on the decrypted IPA in this folder (put
one there first; `*.ipa` files are ignored by git). `BUNDLE_ID=…`, `VERSION=…` and `DISPLAY_NAME=…`
are passed on to `patch.py`.

## Sync

Sync code is untouched.

## Testing in the Simulator with a budget

The simulator build (`--sim`) also includes `src/YNABFakeDropbox.m`, which serves a local folder as
Dropbox so a budget can be opened without signing in. It does nothing unless the environment variable
below is set, and it is never in the device IPA. Use a copy of a test budget, never a real one:

```
mkdir -p /tmp/fakedropbox/YNAB && cp -R Test~XXXX.ynab4 /tmp/fakedropbox/YNAB/
xcrun simctl install <device> build/sim/YNAB.app
SIMCTL_CHILD_YNAB_FAKE_DROPBOX_ROOT=/tmp/fakedropbox xcrun simctl launch <device> com.ynab.ynab-modernized
```

Then choose "Yes, I've set up YNAB for Desktop" → "Link Dropbox". The app writes sync files back into the copy.

To test the UI while a sync is running, add `SIMCTL_CHILD_YNAB_FAKE_DROPBOX_DELAY=30` to the launch
command: every fake Dropbox response is then held back for that many seconds, keeping the
"Syncing..." banner up (pull the list down to start a sync).

## Caveats

- Tested on real device iPhone 15 Pro Max on iOS 27.0.1
- Tested in the simulator on iOS 17.4 (iPhone 15 Pro, iPhone 15 Pro Max) and on
  iOS 26.3 (iPhone 17 Pro). Other real devices haven't been tested.

## FAQ

### Which version do I need?

YNAB 3.4.3 (build 263), the last release of the YNAB Classic iOS app, in a **decrypted** IPA.

### Where do I find a decrypted IPA?

This repository doesn’t include the YNAB IPA file itself. You need your own **decrypted** copy of YNAB Classic 3.4.3. You can use a jailbroken iPhone or iPad to extract a decrypted copy with a various publicly available decryption tools.

## Legal Stuff

**IMPORTANT NOTE:** This script is not affiliated with YNAB in any way, and YNAB has not endorsed it. You Need a Budget and YNAB are registered trademarks of You Need a Budget LLC and/or one of its subsidiaries.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
