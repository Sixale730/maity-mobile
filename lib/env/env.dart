import 'package:omi/env/dev_env.dart';

abstract class Env {
  static late final EnvFields _instance;

  static void init([EnvFields? instance]) {
    _instance = instance ?? DevEnv() as EnvFields;
  }

  static String? get openAIAPIKey => _instance.openAIAPIKey;

  static String? get mixpanelProjectToken => _instance.mixpanelProjectToken;

  // static String? get apiBaseUrl => 'https://omi-backend.ngrok.app/';
  static String? get apiBaseUrl => _instance.apiBaseUrl;

  static String? get growthbookApiKey => _instance.growthbookApiKey;

  static String? get googleMapsApiKey => _instance.googleMapsApiKey;

  static String? get intercomAppId => _instance.intercomAppId;

  static String? get intercomIOSApiKey => _instance.intercomIOSApiKey;

  static String? get intercomAndroidApiKey => _instance.intercomAndroidApiKey;

  static String? get googleClientId => _instance.googleClientId;

  static String? get googleClientSecret => _instance.googleClientSecret;

  static bool get useWebAuth => _instance.useWebAuth ?? false;

  static bool get useAuthCustomToken => _instance.useAuthCustomToken ?? false;

  static String? get deepgramApiKey => _instance.deepgramApiKey;

  static String? get maityBackendUrl {
    final url = _instance.maityBackendUrl;
    if (url != null && url.endsWith('/')) {
      return url.substring(0, url.length - 1);
    }
    return url;
  }

  // Supabase
  static String? get supabaseUrl => _instance.supabaseUrl;

  static String? get supabaseAnonKey => _instance.supabaseAnonKey;
}

abstract class EnvFields {
  String? get openAIAPIKey;

  String? get mixpanelProjectToken;

  String? get apiBaseUrl;

  String? get growthbookApiKey;

  String? get googleMapsApiKey;

  String? get intercomAppId;

  String? get intercomIOSApiKey;

  String? get intercomAndroidApiKey;

  String? get googleClientId;

  String? get googleClientSecret;

  bool? get useWebAuth;

  bool? get useAuthCustomToken;

  String? get deepgramApiKey;

  String? get maityBackendUrl;

  // Supabase
  String? get supabaseUrl;

  String? get supabaseAnonKey;
}
