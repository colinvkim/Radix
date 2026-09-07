# Onboarding planning app

`RadixOnboardingPlanning` is a separate native macOS app target in
`Radix.xcodeproj`. It opens with **Version 3**: intro, Full Disk Access,
then an optional tour invitation. The current onboarding and first proposal remain
available. Comparison places either earlier design beside Version 3; at smaller
window widths, the comparison stacks vertically.

## Build and open

```sh
rtk proxy xcodebuild -project Radix.xcodeproj -scheme RadixOnboardingPlanning \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode-derived-data build
rtk proxy open -n '.build/xcode-derived-data/Build/Products/Debug/Radix Onboarding Planning.app'
```

Quit any existing planning-app instance before launching another. For Computer
Use, target the full absolute path to this Debug bundle. Its bundle identifier
is `com.colinkim.Radix.OnboardingPlanning`.

## Preview controls

- **Current**, **Proposed**, **Version 3**, and **Compare** select the design
  being reviewed. The sidebar supports standard selection and arrow keys.
- The screen pickers jump to any stage of the proposed or Version 3 flow.
- **Compare with** chooses the earlier design to place beside Version 3.
- **Disk Access** switches between not enabled, enabled, and unknown states.
- **Appearance** previews the system appearance, light mode, or dark mode.
- **Animate entrance** controls the sunburst assembly. The system's Reduce
  Motion preference always takes precedence.
- **Replay** (`⌘R`) restarts all flows, retaining
  the chosen access and appearance settings.
- **Present Current/Proposed/Version 3** (`⌘Return`) opens the selected design
  as a native sheet. Press Escape to return to the planning workspace.

Permission buttons open a simulation sheet. Choosing a state there previews
returning from System Settings. Completion buttons finish the preview.
No preview action opens System Settings, scans files, moves files to Trash,
or changes Radix's saved preferences.

## Version 3

1. **Intro:** the signature map with an empty center, “Make space for what
   matters.”, and a centered Get Started button leading to Full Disk Access.
2. **Full Disk Access:** a compact 360-point screen with a lock above a centered
   heading, an explanation of how protected folders give a more complete view
   of the disk, and instructions to enable Radix under Full Disk Access in
   System Settings. A secondary note explains Quit & Reopen. Open System Settings
   offers setup through the permission simulator. Skip for Now skips setup.
   Enabled access changes the primary action to Continue. Either continuation
   leads to the tour invitation.
3. **Optional quick tour:** Start Quick Tour and Skip both close onboarding
   and enter the actual workspace. Help can offer the tour again later.

The planner stops at this handoff and shows an explicitly labeled planning
note. The note outlines the workspace tour; it does not run the tour or open
the production app. The former miniature workspace and sample-file exercises
have been removed. Version 3 is also integrated into Radix, where Start Quick Tour opens the live workspace tour.

## Workspace tour design

The tour belongs to the real workspace. Use one small prompt at a time and
let the user operate the normal controls. The app remains usable;
avoid a modal overlay that intercepts drag gestures. Stop Tour is always
available. Informational tips advance only with Next. Selecting files, opening
folders, changing the map, toggling the Inspector, searching, or rescanning
does not advance the tip. Discard Pile is the only hands-on exercise: adding
sample files or folders and opening the pile advances that sequence. Skip
Exercise skips the remaining exercise and shows the completion tip. The removal
tip is informational and advances with Next, whether or not the user removes an item.

Preparation and scan readiness remain internal states with no tour prompt.
The first tip appears when the practice scan is ready. Completion uses an
arrowless card floating at the top right of the main workspace.
The card has a definite text width and
does not participate in the workspace layout. Its overlay is limited to the
card's bounds, leaving the file rows and sidebar drag destination available.
The first tip points to Sunburst's right edge or Treemap's center, leaving room
for the popover beside the anchor in the full-width Treemap. Its pointer follows
the chart as the window is resized. The folder tip points directly to a folder
row in Contents, with a soft background tint.
Tour tips use native popover pointers without dots or pulse animations.
The map-style picker, Inspector, and Rescan have capsule-shaped tints and
pointers centered below their controls. Search uses a centered pointer
above its field. Both Discard Pile popovers appear above the center of its
sidebar button, with no tour tint. Decorations do not receive mouse or
accessibility focus. Control anchors remain mounted
throughout the tour. If the target is hidden or AppKit cannot show the popover
during layout, the same tip remains available as an arrowless card.
At the practice folder's root, the folder tip targets the selected openable
folder row, or the first openable folder in the current results. Inside a folder,
the same lesson becomes “Folder contents” and stays in a popover attached to the
path's first ancestor button. It explains the new view and how to return to a
parent folder. The path anchor stays mounted while file rows change, and the
presenter chooses the visible breadcrumb layout in the responsive header.
Next still advances the lesson; returning to the root restores the opening tip.

| Stop | Actual interface | Completion |
| --- | --- | --- |
| Prepare the practice scan (no tip) | A temporary Practice Folder is created and scanned automatically | A scan snapshot is ready and the chart is usable. |
| Explore results | Chart and file rows in `ActiveWorkspaceView` | Explain shared selection and folder navigation; Next continues. |
| Switch views | Sunburst/Treemap picker in `WorkspaceView` | Explain the two map styles; Next continues. |
| Use workspace controls | Rescan and Inspector in the workspace toolbar; search in the file list | Explain each control; Next continues. |
| Drag to the Discard Pile | A file or folder in the disk map or Contents, and `DiscardPileSidebarButton` | The existing drop handler accepts the dragged item. |
| Review the pile | The real `DiscardPileReviewSheet` | Explain that the minus button clears the item's deletion mark and restores it to the folder view; Next continues. |

The drag lesson must teach the gesture itself. Its popover points to the
Discard Pile above the drop target. Inline tips in the review sheet have a subtle
rounded background. The Discard Pile lessons add no tour tints or row highlights
to the source file, sidebar button, or review rows.
The tour reveals the sidebar before using it and restores
the previous sidebar visibility on completion. The normal
**Add to Discard Pile** action remains available for keyboard and assistive
technology users. Explain that adding only marks an item for review. Moving
to Trash remains a separate, explicit action and is never performed by the
tour. Existing pile entries must not be changed by the lesson.

Quick Look, saved scans, and comparison explanations can appear when those
features become relevant. They should use the actual feature controls rather
than extending the introductory screens.

The production integration uses `WorkspaceTourController` for progress and
`WorkspaceTourPresentation` for workspace cards and native control popovers.
Progress observes scan readiness and committed pile additions. The presenter
uses the current folder to adapt the folder tip without advancing it. The existing workspace actions and
safety policy remain responsible for scans and file operations. The planning
target still ends at the handoff; it does not link these production services.

`WorkspaceTourSessionController` saves the current scan, selection, open folder,
navigation history, file-browser filters and sorting, Discard Pile marks, and
disk-map style for restoration. The tour starts with a fresh file browser.
`TourPracticeDirectory` creates a separate directory for each tour, containing
small text files of different sizes and a nested Projects folder. The practice
scan ignores exclusions and does not enter Recent Scans, the completed-scan
cache, or usage statistics. Inspector and sidebar visibility are restored with the workspace.
Stopping or completing the tour restores that workspace and removes its practice
directory. Choosing another scan ends the tour before opening the chosen target.
Tours start only when the current scan and file operations are idle.

Temporary directories contain an ownership marker. Cleanup only removes marked
directories inside Radix's dedicated temporary location. On launch, Radix also
removes abandoned tour directories whose owning process is no longer running.

Radix saves the current onboarding page so Quit & Reopen returns to the access
step. Existing users keep their completed-onboarding preference. Settings can
show the welcome screen again, and Help > Take a Quick Tour starts a new tour.
Stopping or skipping a tour does not remove the user's existing Discard Pile marks.
The marking lesson advances only for newly added marks, and never invokes Trash.

## Source and localization

The Current design is preserved in `OnboardingPlanning/LegacyOnboardingView.swift`.
`LegacyOnboardingAdapter.swift` supplies its small model interface. Version 3
compiles the same `OnboardingFlowView`, `SignatureMapView`, and `OnboardingPage`
as Radix. The planning target also uses Radix's icon, asset catalog, and
localization catalog.

The proposed flows and the planning workspace live in `OnboardingPlanning/`.
Planning controls use `Planning.xcstrings`; the shared onboarding and live tour
use Radix's `Localizable.xcstrings`. Both are translated into English, German,
Spanish, French, Italian, and Simplified Chinese. The app follows the selected
macOS app language.

To validate changes, run the core suite, build both app schemes, and manually
exercise the production onboarding and tour using this checkout's exact Debug
bundle. Use a temporary folder for selection and drag/drop checks, remove only
the practice marks, and verify that the files remain on disk. Also check the
planning app's shared preview and retained comparisons.
