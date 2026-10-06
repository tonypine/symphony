### Playbook: android_app

Use the Android app the way a user would and judge what is on screen, not what the code says.
Do not run the project's test suite, `make all`, coverage or static analysis: CI already ran them.
You build the APK yourself, in your own sandbox, with the build command under "Android app"
below. Your sandbox cannot run the emulator, so Symphony runs it on the host and gives you these
tools. They only act on Symphony's emulator and on the application IDs listed below:

- `qa_android_install`: installs the APKs the build wrote at the APK paths, with fresh app data,
  and reports the application IDs each one installed. Pass `apk` to install only one of them.
  Every install first uninstalls every configured app, so when the walkthrough uses more than
  one app (say the app and a catalog), install them all at once.
- `qa_android_launch` and `qa_android_stop`: start an app (and wait until it is in the
  foreground) and force-stop it, by `application_id`.
- `qa_android_ui_tree`: what is on screen, as a flat list of nodes with a `path` (like `0.2.1`),
  class, text, content-desc, resource-id, `bounds` in display pixels and flags, plus the
  foreground package. Pass `text`, `resource_id` or `class` to list only matching nodes.
- `qa_android_tap` (a node `path` from the last tree, or `x`, `y`), `qa_android_type` (into the
  focused field) and `qa_android_key` (`back`, `ime_action`, `enter`, `tab`, `del`, the d-pad,
  `escape`): act on the app.
- `qa_android_rotate`, `qa_android_dark_mode` and `qa_android_font_scale`: change the device.
  Symphony resets them when the pass ends.
- `qa_android_screenshot`: saves the screen to `qa-evidence/<name>.png`. Each name can be used
  once; it never replaces an existing file.
- `qa_android_put_file`: puts a file you wrote under `qa-evidence/` or `$TMPDIR` (at most 1 MB)
  into the emulator's `Download/` folder, where the system file picker lists it under Downloads.
  `dest` is `Download/<name>` and defaults to the file's own name. A reinstall wipes app data,
  not Downloads, so the file stays until the pass ends.

Do not edit tracked files in the worktree: `qa_android_install` refuses a modified checkout. The
build's own outputs (gitignored files) are fine.

1. Run the build command in your shell, from the worktree root, in the foreground with a time
   limit. A build that fails on a change that should build is a failing step; quote the end of
   the output. A build that cannot start (no JDK, no Android SDK, dependencies that cannot
   download) is `blocked`, with the error as the reason.
2. Run `qa_android_install`, then `qa_android_launch` with the application ID of the app the
   walkthrough step uses (the install result says which APK installed which ID).
3. Follow the ticket's `## User walkthrough` step by step, then check the acceptance criteria.
   When there is no walkthrough, open each screen the change touches (from the acceptance
   criteria and the changed files) and use the controls it adds or changes. Find nodes with
   `qa_android_ui_tree` and act with `qa_android_tap`, `qa_android_type` and `qa_android_key`.
   Use made-up values, never real credentials. To test an import, write a synthetic file (a
   CSV with made-up rows, or a malformed one for the error path) under `qa-evidence/`, put it in
   `Download/` with `qa_android_put_file`, then pick it in the app's file picker under Downloads.
4. Let every screen settle before you judge it. Screens animate in, load data and lay out
   again, so a tree read right after a tap proves nothing: wait 3 to 5 seconds after each
   navigation or action (`sleep 3` in your shell), then read `qa_android_ui_tree`. When the tree
   still changes between two reads a few seconds apart, wait and read it again.
5. Judge the settled screen from the tree:
   - the foreground package is still the app (the tree reports it and warns when it is not);
   - the controls and text the ticket describes are present, with sensible text, content-desc
     and enabled or checked state;
   - their `bounds` have a real size and lie on the display, and nothing the user needs is
     clipped under the status bar, the navigation bar or the on-screen keyboard (IME): when a
     field has focus, the field and the button that submits it stay visible above the keyboard.
6. Take a `qa_android_screenshot` of every step you judge, named after the step in order (for
   example `01-login-open`), and after every action that changes the UI.
7. Where the walkthrough or the change touches them, also check:
   - back: `qa_android_key` `back` leaves the screen or closes the dialog as the ticket says, and
     does not exit the app early;
   - the keyboard action: `qa_android_key` `ime_action` in a field submits or moves to the next
     field as the ticket says;
   - rotation: `qa_android_rotate` `landscape`, settle, judge the screen again (typed text and
     state kept, nothing clipped), then `portrait`;
   - dark mode: `qa_android_dark_mode` `on`, settle, judge that text stays readable and nothing
     disappears, take a screenshot, then `off`.
8. Run `qa_android_stop` when you are done.
9. Attach the screenshots that show each step's result with `linear_attach_file`
   (`make_public: false`) and list the returned URLs in that step's `evidence`.

Verdicts for this playbook:

- A missing control or text, a control that does nothing, a broken layout (a node with no size,
  off the display, or under a system bar or the keyboard) or text that contradicts the ticket is
  a failing step. In `details` quote the relevant part of the settled tree (the nodes with their
  `bounds`) and attach the screenshot of that screen.
- The app crashing or leaving the foreground (`qa_app_exited`, or the tree's warning that
  another package is in the foreground) during the walkthrough is a failing step; quote the
  logcat the tool returned.
- When a tool returns `qa_android_unavailable`, stop this playbook: mark each app step you could
  not check `blocked` with the tool's message in `details`. Then continue with the steps of the
  other playbooks offered to you (such as `cli` or `web`) and report each of them as `pass` or
  `fail`. Answer `blocked` with the tool's message as `reason`. Never start the emulator, `qemu-*`
  or `adb start-server` yourself to get around it: your sandbox cannot run them.
