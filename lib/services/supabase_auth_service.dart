import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/logger.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Servicio de autenticación con Supabase Auth
/// Reemplaza AuthService (Firebase) para unificar auth con la plataforma web
class SupabaseAuthService {
  static final SupabaseAuthService _instance = SupabaseAuthService._internal();
  static SupabaseAuthService get instance => _instance;

  SupabaseAuthService._internal();

  SupabaseClient get _supabase => Supabase.instance.client;

  /// Pending refresh future to avoid concurrent refreshSession() calls
  Future<AuthResponse>? _pendingRefresh;

  /// Usuario actual de Supabase Auth
  User? get currentUser => _supabase.auth.currentUser;

  /// Sesión actual
  Session? get currentSession => _supabase.auth.currentSession;

  /// auth.users.id (UUID)
  String? get authId => currentUser?.id;

  /// maity.users.id (UUID) - cacheado después del login
  String? _maityUserId;
  String? get maityUserId {
    if (_maityUserId != null && _maityUserId!.isNotEmpty) {
      return _maityUserId;
    }
    // Fallback a SharedPreferences si el cache está vacío
    // Esto resuelve el timing issue cuando el chat se abre antes de que
    // restoreSession() complete async
    final stored = SharedPreferencesUtil().uid;
    if (stored.isNotEmpty) {
      _maityUserId = stored;
      return _maityUserId;
    }
    return null;
  }

  /// Verifica si el usuario está autenticado
  bool get isSignedIn => currentUser != null;

  /// Stream de cambios de autenticación
  Stream<AuthState> get onAuthStateChange => _supabase.auth.onAuthStateChange;

  // ============================================================
  // Google Sign In
  // ============================================================

  /// Google Sign In nativo para iOS/Android
  /// Usa google_sign_in para obtener el idToken y lo intercambia con Supabase
  Future<AuthResponse> signInWithGoogleNative() async {
    debugPrint('[SupabaseAuth] Iniciando Google Sign In nativo');

    // 1. Obtener credenciales de Google
    final googleSignIn = GoogleSignIn(
      scopes: ['email', 'profile', 'openid'],
      // Importante: usar el clientId web para obtener idToken válido para Supabase
      serverClientId: Env.googleClientId,
    );

    final googleUser = await googleSignIn.signIn();
    if (googleUser == null) {
      throw Exception('Google Sign In cancelado por el usuario');
    }

    debugPrint('[SupabaseAuth] Google User: ${googleUser.email}');

    final googleAuth = await googleUser.authentication;
    if (googleAuth.idToken == null) {
      throw Exception('No se recibió idToken de Google');
    }

    debugPrint('[SupabaseAuth] idToken obtenido, intercambiando con Supabase...');

    // 2. Intercambiar idToken con Supabase
    final response = await _supabase.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: googleAuth.idToken!,
      accessToken: googleAuth.accessToken,
    );

    if (response.user == null) {
      throw Exception('Supabase no retornó usuario después del sign in');
    }

    debugPrint('[SupabaseAuth] Sign in exitoso: ${response.user!.email}');

    // 3. Actualizar preferencias locales
    await _updateLocalPreferences(response);

    // 4. Obtener maity.users.id
    await _fetchMaityUserId();

    return response;
  }

  // ============================================================
  // Apple Sign In
  // ============================================================

  /// Apple Sign In - nativo en iOS/macOS, OAuth via browser en Android
  Future<AuthResponse> signInWithAppleNative() async {
    if (Platform.isIOS || Platform.isMacOS) {
      return _signInWithAppleNativeIOS();
    } else {
      return _signInWithAppleOAuth();
    }
  }

  /// Apple Sign In nativo para iOS/macOS
  /// Usa sign_in_with_apple para obtener credenciales y las intercambia con Supabase
  Future<AuthResponse> _signInWithAppleNativeIOS() async {
    debugPrint('[SupabaseAuth] Iniciando Apple Sign In nativo');

    // 1. Obtener credenciales de Apple
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );

    if (credential.identityToken == null) {
      throw Exception('No se recibió identityToken de Apple');
    }

    debugPrint('[SupabaseAuth] Apple credential obtenida, intercambiando con Supabase...');

    // 2. Intercambiar identityToken con Supabase
    final response = await _supabase.auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: credential.identityToken!,
    );

    if (response.user == null) {
      throw Exception('Supabase no retornó usuario después del sign in');
    }

    debugPrint('[SupabaseAuth] Apple Sign in exitoso: ${response.user!.email}');

    // 3. Actualizar nombre si Apple lo proporcionó (solo en primer sign-in)
    if (credential.givenName != null || credential.familyName != null) {
      final fullName = [credential.givenName, credential.familyName]
          .where((s) => s != null && s.isNotEmpty)
          .join(' ');
      if (fullName.isNotEmpty) {
        try {
          await _supabase.auth.updateUser(
            UserAttributes(data: {'full_name': fullName}),
          );
        } catch (e) {
          debugPrint('[SupabaseAuth] Error actualizando nombre de Apple: $e');
        }
      }
    }

    // 4. Actualizar preferencias locales
    await _updateLocalPreferences(response);

    // 5. Obtener maity.users.id
    await _fetchMaityUserId();

    return response;
  }

  /// Apple Sign In via OAuth para Android
  /// Abre el browser para el flujo OAuth de Apple, Supabase intercepta el redirect
  Future<AuthResponse> _signInWithAppleOAuth() async {
    debugPrint('[SupabaseAuth] Iniciando Apple Sign In via OAuth (Android)');

    final completer = Completer<AuthResponse>();
    StreamSubscription<AuthState>? subscription;

    subscription = _supabase.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.signedIn && data.session != null) {
        subscription?.cancel();
        if (!completer.isCompleted) {
          completer.complete(AuthResponse(session: data.session, user: data.session!.user));
        }
      }
    });

    final launched = await _supabase.auth.signInWithOAuth(
      OAuthProvider.apple,
      redirectTo: 'maity://login-callback',
    );

    if (!launched) {
      subscription.cancel();
      throw Exception('No se pudo abrir el navegador para Apple Sign In');
    }

    try {
      final response = await completer.future.timeout(const Duration(minutes: 5));
      await _updateLocalPreferences(response);
      await _fetchMaityUserId();
      return response;
    } on TimeoutException {
      subscription.cancel();
      throw Exception('Apple Sign In cancelado o expirado');
    }
  }

  // ============================================================
  // Token Management
  // ============================================================

  /// Obtiene el access token actual, renovándolo si es necesario.
  /// Returns null if the token is expired and refresh fails (caller should handle re-auth).
  Future<String?> getAccessToken() async {
    final session = _supabase.auth.currentSession;
    if (session == null) {
      debugPrint('[SupabaseAuth] No hay sesión activa');
      return null;
    }

    // Verificar si el token está por expirar (5 minutos de buffer)
    final expiresAt = session.expiresAt;
    if (expiresAt != null) {
      final expiryTime = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
      final now = DateTime.now();
      const buffer = Duration(minutes: 5);

      if (expiryTime.isBefore(now.add(buffer))) {
        debugPrint('[SupabaseAuth] Token por expirar, renovando...');
        try {
          // Reuse pending refresh to avoid concurrent refreshSession() calls
          _pendingRefresh ??= _supabase.auth.refreshSession();
          final refreshed = await _pendingRefresh!;
          _pendingRefresh = null;
          if (refreshed.session != null) {
            await _updateLocalPreferences(refreshed);
            return refreshed.session!.accessToken;
          }
        } catch (e) {
          _pendingRefresh = null;
          debugPrint('[SupabaseAuth] Error renovando token: $e');
          // If the token is already expired, do NOT return it — caller gets null
          if (expiryTime.isBefore(now)) {
            debugPrint('[SupabaseAuth] Token already expired and refresh failed, returning null');
            return null;
          }
        }
      }
    }

    return session.accessToken;
  }

  /// Obtiene el ID token (JWT) para validación en backend
  Future<String?> getIdToken() async {
    return await getAccessToken();
  }

  // ============================================================
  // User Management
  // ============================================================

  /// Obtiene el UUID de maity.users para el usuario actual
  Future<String?> fetchMaityUserId() async {
    return await _fetchMaityUserId();
  }

  Future<String?> _fetchMaityUserId() async {
    final authId = currentUser?.id;
    if (authId == null) {
      debugPrint('[SupabaseAuth] No hay usuario autenticado');
      _maityUserId = null;
      return null;
    }

    const maxRetries = 3;
    const delays = [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)];

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final response = await _supabase
            .schema('maity')
            .from('users')
            .select('id')
            .eq('auth_id', authId)
            .maybeSingle();

        if (response != null && response['id'] != null) {
          _maityUserId = response['id'] as String;
          SharedPreferencesUtil().uid = _maityUserId!;
          debugPrint('[SupabaseAuth] maity.users.id: $_maityUserId (attempt ${attempt + 1})');
          return _maityUserId;
        } else {
          debugPrint('[SupabaseAuth] Usuario no encontrado en maity.users (attempt ${attempt + 1}/$maxRetries)');
        }
      } catch (e) {
        debugPrint('[SupabaseAuth] Error obteniendo maity.users.id (attempt ${attempt + 1}/$maxRetries): $e');
      }

      if (attempt < maxRetries - 1) {
        await Future.delayed(delays[attempt]);
      }
    }

    debugPrint('[SupabaseAuth] ALERTA: maityUserId null después de $maxRetries intentos para authId=$authId');
    return null;
  }

  /// Actualiza el nombre del usuario
  Future<void> updateUserName(String fullName) async {
    try {
      // Actualizar en SharedPreferences
      final parts = fullName.split(' ');
      SharedPreferencesUtil().givenName = parts.isNotEmpty ? parts[0] : '';
      SharedPreferencesUtil().familyName = parts.length > 1 ? parts.sublist(1).join(' ') : '';

      // Actualizar en Supabase Auth
      await _supabase.auth.updateUser(
        UserAttributes(
          data: {'full_name': fullName},
        ),
      );

      // Actualizar en maity.users
      if (_maityUserId != null) {
        await _supabase
            .schema('maity')
            .from('users')
            .update({'name': fullName})
            .eq('id', _maityUserId!);
      }

      debugPrint('[SupabaseAuth] Nombre actualizado: $fullName');
    } catch (e) {
      debugPrint('[SupabaseAuth] Error actualizando nombre: $e');
    }
  }

  // ============================================================
  // Sign Out
  // ============================================================

  /// Cierra la sesión
  Future<void> signOut() async {
    try {
      // Desconectar de Google
      try {
        await GoogleSignIn().signOut();
      } catch (e) {
        debugPrint('[SupabaseAuth] Error en Google signOut: $e');
      }

      // Cerrar sesión en Supabase
      await _supabase.auth.signOut();

      // Limpiar datos locales
      _maityUserId = null;
      _clearLocalPreferences();

      debugPrint('[SupabaseAuth] Sesión cerrada');
    } catch (e) {
      debugPrint('[SupabaseAuth] Error cerrando sesión: $e');
      Logger.handle(e, null, message: 'Error al cerrar sesión');
    }
  }

  // ============================================================
  // Session Restoration
  // ============================================================

  /// Restaura la sesión desde el almacenamiento local
  /// Llamar después de inicializar Supabase
  Future<bool> restoreSession() async {
    try {
      final session = _supabase.auth.currentSession;
      if (session != null) {
        debugPrint('[SupabaseAuth] Sesión restaurada: ${session.user.email}');
        await _updateLocalPreferences(AuthResponse(session: session, user: session.user));
        await _fetchMaityUserId();
        return true;
      }
    } catch (e) {
      debugPrint('[SupabaseAuth] Error restaurando sesión: $e');
    }
    return false;
  }

  // ============================================================
  // Helpers Privados
  // ============================================================

  /// Actualiza las preferencias locales después del login
  Future<void> _updateLocalPreferences(AuthResponse response) async {
    final user = response.user;
    final session = response.session;

    if (user == null) return;

    // Token y expiración
    if (session != null) {
      SharedPreferencesUtil().authToken = session.accessToken;
      SharedPreferencesUtil().tokenExpirationTime =
          (session.expiresAt ?? 0) * 1000; // Convertir a milliseconds
    }

    // Email
    if (user.email != null && user.email!.isNotEmpty) {
      SharedPreferencesUtil().email = user.email!;
    }

    // Nombre
    final userMetadata = user.userMetadata;
    if (userMetadata != null) {
      final fullName = userMetadata['full_name'] as String? ??
          userMetadata['name'] as String? ??
          '';

      if (fullName.isNotEmpty) {
        final parts = fullName.split(' ');
        SharedPreferencesUtil().givenName = parts.isNotEmpty ? parts[0] : '';
        SharedPreferencesUtil().familyName =
            parts.length > 1 ? parts.sublist(1).join(' ') : '';
      }
    }

    debugPrint('[SupabaseAuth] Preferencias actualizadas:');
    debugPrint('  Email: ${SharedPreferencesUtil().email}');
    debugPrint('  Nombre: ${SharedPreferencesUtil().givenName} ${SharedPreferencesUtil().familyName}');
  }

  void _clearLocalPreferences() {
    SharedPreferencesUtil().uid = '';
    SharedPreferencesUtil().authToken = '';
    SharedPreferencesUtil().tokenExpirationTime = 0;
    SharedPreferencesUtil().email = '';
    SharedPreferencesUtil().givenName = '';
    SharedPreferencesUtil().familyName = '';
  }
}
