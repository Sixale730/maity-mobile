// Firebase options for MaityOmi prod environment
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for windows - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAbtuCVwbM6_aNfgJSyYnLCvrRkBRmo3FQ',
    appId: '1:7874727378:android:8cb93e0b78451c8b5f0c0b',
    messagingSenderId: '7874727378',
    projectId: 'maityomi-fb601',
    storageBucket: 'maityomi-fb601.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAbtuCVwbM6_aNfgJSyYnLCvrRkBRmo3FQ',
    appId: '1:7874727378:android:8cb93e0b78451c8b5f0c0b',
    messagingSenderId: '7874727378',
    projectId: 'maityomi-fb601',
    storageBucket: 'maityomi-fb601.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAbtuCVwbM6_aNfgJSyYnLCvrRkBRmo3FQ',
    appId: '1:7874727378:android:8cb93e0b78451c8b5f0c0b',
    messagingSenderId: '7874727378',
    projectId: 'maityomi-fb601',
    storageBucket: 'maityomi-fb601.firebasestorage.app',
    iosBundleId: 'com.maity.app',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyAbtuCVwbM6_aNfgJSyYnLCvrRkBRmo3FQ',
    appId: '1:7874727378:android:8cb93e0b78451c8b5f0c0b',
    messagingSenderId: '7874727378',
    projectId: 'maityomi-fb601',
    storageBucket: 'maityomi-fb601.firebasestorage.app',
    iosBundleId: 'com.maity.app',
  );
}
