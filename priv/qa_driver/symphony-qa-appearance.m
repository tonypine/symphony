// Loaded into an app QA launches with `appearance` (DYLD_INSERT_LIBRARIES), so
// any macOS app draws light or dark whatever the QA host's appearance. AppKit
// reads the system appearance from the global defaults only, so a launch
// argument such as `-AppleInterfaceStyle Dark` leaves the app light; setting
// the app's own appearance is what QA can do without switching the host's.
//
// It reads SYMPHONY_BAR_QA_APPEARANCE (`light` or `dark`), sets NSApp's
// appearance as the app finishes launching, and prints
// `symphony-qa-appearance: <light|dark>` to the app's output once it has. An
// app built with the hardened runtime ignores DYLD_INSERT_LIBRARIES, so that
// line never appears. The library takes DYLD_INSERT_LIBRARIES out of the app's
// environment, so the tools the app runs load nothing.
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSAppearanceName requestedAppearance(const char *value) {
  if (value == NULL) return nil;
  if (strcmp(value, "dark") == 0) return NSAppearanceNameDarkAqua;
  if (strcmp(value, "light") == 0) return NSAppearanceNameAqua;
  return nil;
}

__attribute__((constructor)) static void symphonyQaAppearance(void) {
  unsetenv("DYLD_INSERT_LIBRARIES");
  const char *value = getenv("SYMPHONY_BAR_QA_APPEARANCE");
  NSAppearanceName name = requestedAppearance(value);
  if (name == nil) return;

  NSString *label = [NSString stringWithUTF8String:value];
  // Set at both points: an app that picks its own appearance as it finishes
  // launching would otherwise win.
  void (^apply)(NSNotification *) = ^(NSNotification *note) {
    NSApp.appearance = [NSAppearance appearanceNamed:name];
    fprintf(stderr, "symphony-qa-appearance: %s\n", label.UTF8String);
  };
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [center addObserverForName:NSApplicationWillFinishLaunchingNotification object:nil queue:nil usingBlock:apply];
  [center addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:apply];
}
