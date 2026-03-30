SwiftUI macOS Alert Action Bug
When using `.alert` or `.confirmationDialog` in macOS, occasionally a `Button` action is dropped. Replacing `role: .destructive` often fixes it, but if it doesn't:
- Sometimes wrapping the action in `DispatchQueue.main.async { ... }` prevents the state changes from conflicting with the alert's dismiss animation.
- Sometimes the button needs an explicit `.keyboardShortcut(.defaultAction)` to register correctly.
