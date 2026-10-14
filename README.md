# Unbox

Unbox installs apps from disk images without the usual Finder window. Double-click a `.dmg` and a small window shows the app inside (icon, name, version, size, signature) with **Install** and **Cancel**.

- **Install** copies the app to `/Applications`, ejects the image and moves it to the Trash.
- **Cancel** ejects the image and keeps the file.
- An image without an app, with a license agreement, or with several apps is opened the normal macOS way.
- An app that is already installed is never overwritten silently. The button changes to **Replace** and the old version goes to the Trash.

## Setup

Open Unbox once and choose **Use Unbox** under Disk images. macOS asks you to confirm the change. **Use macOS Default** reverses it at any time.

## Notes

- Disk images are mounted hidden and read-only (`hdiutil attach -nobrowse -noautoopen -readonly`), so no Finder window appears.
- A quarantine flag on the image is carried over to the installed app, so Gatekeeper still checks it. Unbox never removes quarantine.
- Unbox is unsigned. The first launch needs one confirmation in System Settings, Privacy & Security.
- Updates come from the GitHub releases, with a Stable or Beta channel.

Requires macOS 14 or later.
