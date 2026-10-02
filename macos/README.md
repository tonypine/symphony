# Symphony menu bar app

A macOS menu bar app for Symphony. For now it shows a status icon and a menu with Quit.

Requires macOS 13+ and Xcode or the Command Line Tools.

```bash
cd macos
make        # builds an ad-hoc-signed build/Symphony.app
make run    # builds and opens it
make test   # runs swift test
make clean  # removes build/ and .build/
```

The app is ad-hoc signed, so on first open Gatekeeper may ask you to confirm it
(right-click the app and choose Open).

`SymphonyBarCore` holds pure logic that is unit tested without AppKit; `SymphonyBar` is the AppKit app.
