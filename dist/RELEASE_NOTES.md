# Lidless 1.1.0

Lidless now fails safe at the battery cutoff and after process failures. A 10% cutoff means 10% or below: normal lid sleep is restored immediately instead of waiting for a later poll. If the app quits, crashes, is force-killed, or stops responding, recovery restores normal lid sleep within 30 seconds.

This release also adds:

- Clear **Off / 10% / 20% / 30%** battery-cutoff choices.
- The original, easy-to-see menu-bar sparkle.
- Plain setup language without internal service terminology.
- Detection of keep-awake settings owned by another tool, without silently changing them.
- Signed, checksum-verified, read-only updates with automatic rollback if the new app cannot launch.
- Universal support for Apple Silicon and Intel on macOS 13 or newer.

After installing, open the Lidless menu and choose **Finish Setup…**. If macOS asks, choose **Allow Lidless in System Settings…** and approve Lidless once under Background Items. There is no recurring password prompt.
