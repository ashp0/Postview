# Postview — notes for Claude

A PDF viewer for OS X 10.9 Mavericks: smooth scrolling, remembers your place, low CPU
at reading pace. Objective-C, no third-party code. `README.md` is for users;
`ENGINEERING.md` is the measured design record. Source comments cite its sections.
Its rule: label every figure **Measured**, **Derived** or **Unverified**, and don't
build on an unverified one.

This repo is **public**. Keep personal paths, names and course material out of it.

## Building

Build on a modern Mac with Xcode, against the real 10.9.5 SDK:

    make dist SDK="$HOME/Developer/SDKs/MacOSX10.9.sdk" SIGN_IDENTITY=none

`REQUIRE_SDK` defaults to 10.9 and refuses a current SDK. Builds ship unsigned (there
is no Developer ID). After any change, rebuild `Postview.zip` and commit it
separately ("Rebuild the archive…"), as the history does. A 10.9 machine can't
build this tree. On one, the job is to install, run and measure (`Tools/`,
`Postview-*.command`).

## 10.9 traps (verified)

- A current SDK binds many Foundation classes to CoreFoundation. A name that 10.9's CF
  doesn't export stops loading with "Symbol not found". The 10.9.5 SDK's CF stub is the
  ground truth. It exports NSArray, NSDate, NSDictionary, NSTimer, NSURL, NSCalendar,
  NSTimeZone, NSData and NSSet, but not NSFileManager. To check:
  `nm -um <binary> | grep 'from CoreFoundation'`.
- **Responsive scrolling costs CPU at reading pace.** With
  `+isCompatibleWithResponsiveScrolling` YES, AppKit's idle prefetch drew tiles of a
  document view hundreds of thousands of points tall. Declining it took a 200-page
  reading run from 11.31 s to 7.54 s of CPU (Preview: 8.11 s) and idle wakeups from 12.1
  to 4.7/s. The cost: wheel/trackpad smoothness, unverified (`Tools/showdown.sh`
  `swipe` and `wheel`). When a metric flips between two paces, suspect idle-time work.
- Memory is about 2.5x Preview's (213 vs 85 MB). That is the deliberate memory-for-CPU trade.

## Open at a page

Another app can open a document at a page. It puts an Int32 under `'page'` in the odoc
event's keyAEPropData (NSWorkspace `additionalEventParamDescriptor` / LaunchServices
`passThruParams`). See `-application:openFiles:`, `PVRequestedPageInOpenEvent` and
`-setInitialPageNumber:`. Syllabus depends on it.

## Still unverified on real 10.9

- An annotated **rotated or cropped** page renders correctly. The fix assumes 10.9
  PDFKit's `-drawWithBox:` applies the crop origin and /Rotate itself.
- Links from Syllabus open Postview at the requested page.

## Icons

`Tools/mkicon.m` draws the icon. Check it at 128 and 32 px on #EDEDED. Core Graphics
shadow offsets and blurs are in device pixels, so scale them by pixels-per-unit. Keep
the art at about 90% of the canvas.
