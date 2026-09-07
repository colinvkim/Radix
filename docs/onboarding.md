# Onboarding and workspace tour

Radix's onboarding has three pages: welcome, Full Disk Access, and an optional
workspace tour. `OnboardingView` connects the app model to `OnboardingFlowView`;
`SignatureMapView` draws the welcome animation and respects Reduce Motion.

## Completion and restart

The existing `didCompleteOnboarding` preference controls automatic presentation.
Completed onboarding stays completed across upgrades. `onboardingPage` saves the
current page while onboarding is unfinished.

Opening Full Disk Access settings from onboarding marks onboarding incomplete.
Quit & Reopen returns to the saved access page; Continue leads to the tour
invitation. Start Quick Tour, Skip, or dismissing onboarding marks it complete.
Finishing the optional tour is not required. Settings can reopen onboarding, and
Help > Take a Quick Tour starts the tour directly.

## Tour behavior

`WorkspaceTourController` owns progression. Preparation and scan readiness are
internal states; the first tip appears when the practice scan is ready.
Informational tips advance with Next. Only adding items to the Discard Pile and
opening its review sheet advance in response to workspace actions. The removal
tip also advances with Next. Skip Exercise skips the remaining exercise, and
Stop Tour is available throughout.

`WorkspaceTourPresentation` attaches native popovers to the actual workspace
controls. If a control is unavailable, the same tip appears as a floating card.
Inside a folder, the folder lesson attaches to the breadcrumb path and explains
returning to a parent folder. The presenter chooses the visible breadcrumb
layout in the responsive header. Review-sheet tips appear within the sheet.
Anchors and decorative tints do not intercept input or accessibility focus.

## Practice files and restoration

`WorkspaceTourSessionController` saves the current scan, selection, focused
folder, navigation history, file-browser filters and sorting, Discard Pile marks,
and map style. The tour uses a fresh file browser, respects the current map and
Inspector preferences, and temporarily reveals the sidebar. Stopping or finishing
restores the previous workspace, map style, Inspector preference, and sidebar
visibility. Choosing another scan ends the tour first.

`TourPracticeDirectory` creates a temporary folder with small text files and a
nested Projects folder. Practice scans ignore exclusions and directory
summarization, and do not enter Recent Scans, the scan cache, or usage statistics.
The tour never invokes Move to Trash. Normal file actions still require explicit
user input and use the existing safety policy.

Each temporary directory has an ownership marker. Cleanup removes only owned
tour directories. Startup cleanup also removes abandoned directories whose
owning process is no longer running.

## Localization and validation

User-facing text lives in `Radix/Localizable.xcstrings`, with translations for
English, German, Spanish, French, Italian, and Simplified Chinese.

Follow `AGENTS.md` for core tests, app builds, and manual validation. Exercise
onboarding restart, tour completion and cancellation, workspace restoration,
both map styles, folder navigation, and the Discard Pile using this checkout's
exact Debug bundle.
