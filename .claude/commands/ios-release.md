Build the Flutter iOS IPA (release), auto-incrementing the build number, and upload to App Store Connect.

Steps:
1. Read `pubspec.yaml` line 6 to get the current version (format: `X.Y.Z+buildNumber`)
2. Increment ONLY the buildNumber by 1. Do NOT change the versionName (X.Y.Z).
   - Example: `1.0.0+482` becomes `1.0.0+483`
   - IMPORTANT: Never decrease the buildNumber — App Store rejects it
3. Edit `pubspec.yaml` with the new version
4. Report the version change to the user (e.g. "Build: 482 → 483")
5. Run `flutter build ipa --release --flavor prod` with a 10-minute timeout
6. Report success/failure and the .ipa file size
7. Read Apple credentials from `.claude/ios-credentials.env` (contains APPLE_ID and APP_SPECIFIC_PASSWORD)
8. Upload to App Store Connect using:
   ```
   xcrun altool --upload-app --type ios -f build/ios/ipa/Maity.ipa -u $APPLE_ID -p $APP_SPECIFIC_PASSWORD
   ```
   Use a 5-minute timeout for the upload.
9. Report upload result (success/failure, transfer speed)
10. If upload succeeded, commit the version bump with message: `chore(release): bump build number to {N} for App Store submission`
