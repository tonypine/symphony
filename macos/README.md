# Symphony menu bar app

A macOS menu bar app for Symphony. For now it shows a status icon and a menu with Settings… and Quit.

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

## Settings

Settings… (⌘,) opens the Settings window. It also opens on first launch, while no checkout folder is set.

- Checkout folder, `symphony.yml` path, optional command prefix (for example `mise exec --`), stop timeout
  and "Start Symphony when the app opens" are stored in UserDefaults (`defaults read com.tonypine.symphony.bar`).
- `LINEAR_API_KEY` and any extra environment variables are stored only in the login Keychain, as generic
  passwords under service `symphony` with the variable name as the account:

  ```bash
  security find-generic-password -s symphony -a LINEAR_API_KEY
  ```

Because the app is ad-hoc signed, its signature changes on every rebuild, so macOS may ask again for
Keychain access after a rebuild. Choose Always Allow to stop the prompt for that build.

`SymphonyBarCore` holds pure logic that is unit tested without AppKit; `SymphonyBar` is the AppKit app.
