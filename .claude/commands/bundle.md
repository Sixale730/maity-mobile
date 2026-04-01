Build the Flutter Android App Bundle (release), auto-incrementing the build number.

Steps:
1. Read `pubspec.yaml` line 6 to get the current version (format: `X.Y.Z+buildNumber`)
2. Increment ONLY the buildNumber by 1. Do NOT change the versionName (X.Y.Z).
   - Example: `1.0.0+477` becomes `1.0.0+478`
   - IMPORTANT: Never decrease the buildNumber — Google Play rejects it
3. Edit `pubspec.yaml` with the new version
4. Report the version change to the user (e.g. "Build: 477 → 478")
5. Run `flutter build appbundle` with a 10-minute timeout
6. Report success/failure and the .aab file size
7. Open the output folder using: `start "" "C:\\OMI\\build\\app\\outputs\\bundle\\release"`
   - IMPORTANT: Always use `start ""` on Windows. Do NOT use `explorer.exe` as it returns exit code 1.
