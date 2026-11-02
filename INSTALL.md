# Installing Overlap

Overlap needs macOS 27.

1. Download **Overlap.zip** from <https://chasingux.github.io/Overlap/> and open it.
2. Drag **Overlap** into your **Applications** folder.
3. Open it. macOS says it can't check Overlap for malicious software, because Overlap isn't registered with Apple.
   Click **Done**.
4. Open **System Settings > Privacy & Security**, scroll down to the message about Overlap, and click
   **Open Anyway**. Confirm with your password.

You only do this once. After that Overlap opens like any other app, and new versions install themselves: Overlap
checks once a day, or choose **Overlap > Check for Updates…**.

If you're comfortable with Terminal, this does steps 3 and 4 in one go, after step 2:

```bash
xattr -dr com.apple.quarantine /Applications/Overlap.app
```
