import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/utils/logger.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// AuthService - Wrapper sobre SupabaseAuthService para compatibilidad
/// Toda la autenticación ahora usa Supabase Auth
class AuthService {
  static final AuthService _instance = AuthService._internal();
  static AuthService get instance => _instance;

  AuthService._internal();

  SupabaseAuthService get _supabaseAuth => SupabaseAuthService.instance;

  /// Verifica si el usuario está autenticado
  bool isSignedIn() => _supabaseAuth.isSignedIn;

  /// Obtiene el usuario actual de Supabase
  User? getFirebaseUser() => _supabaseAuth.currentUser;

  /// Alias para compatibilidad
  User? get currentUser => _supabaseAuth.currentUser;

  /// Google Sign In usando Supabase Auth
  Future<AuthResponse?> signInWithGoogleMobile() async {
    try {
      debugPrint('[AuthService] Starting Google Sign In via Supabase');
      final response = await _supabaseAuth.signInWithGoogleNative();

      if (response.user != null) {
        await _updateUserPreferencesFromSupabase(response.user!);
      }

      return response;
    } catch (e) {
      debugPrint('[AuthService] Google Sign In error: $e');
      Logger.handle(e, null, message: 'Error al iniciar sesión con Google');
      return null;
    }
  }

  /// Apple Sign In usando Supabase Auth
  /// TODO: Implementar Apple Sign In con Supabase
  Future<AuthResponse?> signInWithAppleMobile() async {
    debugPrint('[AuthService] Apple Sign In not yet implemented for Supabase');
    // Por ahora, Apple Sign In no está implementado en SupabaseAuthService
    // Se puede agregar siguiendo el mismo patrón que Google Sign In
    throw UnimplementedError('Apple Sign In con Supabase aún no implementado');
  }

  /// Supabase no soporta autenticación anónima de la misma forma
  /// Esta función ahora es un no-op
  Future<void> signInAnonymously() async {
    debugPrint('[AuthService] Anonymous sign in not supported with Supabase');
    // Supabase no tiene sign-in anónimo como Firebase
    // Se puede implementar con magic link si es necesario
  }

  /// Cierra la sesión
  Future<void> signOut() async {
    try {
      await _supabaseAuth.signOut();
      // Limpiar preferencias locales
      SharedPreferencesUtil().uid = '';
      SharedPreferencesUtil().authToken = '';
      SharedPreferencesUtil().email = '';
      debugPrint('[AuthService] Sign out successful');
    } catch (e) {
      debugPrint('[AuthService] Sign out error: $e');
    }
  }

  /// Obtiene el token de acceso de Supabase
  Future<String?> getIdToken() async {
    try {
      final token = await _supabaseAuth.getAccessToken();
      if (token != null) {
        SharedPreferencesUtil().authToken = token;

        // Actualizar UID si está disponible
        final user = _supabaseAuth.currentUser;
        if (user != null) {
          SharedPreferencesUtil().uid = _supabaseAuth.maityUserId ?? '';
          if (SharedPreferencesUtil().email.isEmpty) {
            SharedPreferencesUtil().email = user.email ?? '';
          }
        }
      }
      return token;
    } catch (e) {
      debugPrint('[AuthService] getIdToken error: $e');
      return SharedPreferencesUtil().authToken;
    }
  }

  /// Actualiza las preferencias del usuario desde Supabase User
  Future<void> _updateUserPreferencesFromSupabase(User user) async {
    try {
      SharedPreferencesUtil().uid = _supabaseAuth.maityUserId ?? '';
      SharedPreferencesUtil().email = user.email ?? '';

      // Obtener nombre de los metadatos
      final metadata = user.userMetadata;
      if (metadata != null) {
        final fullName = metadata['full_name'] as String? ??
                        metadata['name'] as String? ?? '';
        if (fullName.isNotEmpty) {
          final parts = fullName.split(' ');
          SharedPreferencesUtil().givenName = parts.isNotEmpty ? parts[0] : '';
          SharedPreferencesUtil().familyName = parts.length > 1 ? parts.sublist(1).join(' ') : '';
        }
      }

      // Obtener y guardar el token
      await getIdToken();

      debugPrint('[AuthService] User preferences updated:');
      debugPrint('  UID: ${SharedPreferencesUtil().uid}');
      debugPrint('  Email: ${SharedPreferencesUtil().email}');
      debugPrint('  Name: ${SharedPreferencesUtil().givenName} ${SharedPreferencesUtil().familyName}');
    } catch (e) {
      debugPrint('[AuthService] Error updating preferences: $e');
    }
  }

  /// Actualiza el nombre del usuario
  Future<void> updateGivenName(String fullName) async {
    try {
      SharedPreferencesUtil().givenName = fullName.split(' ')[0];
      if (fullName.split(' ').length > 1) {
        SharedPreferencesUtil().familyName = fullName.split(' ').sublist(1).join(' ');
      }

      // Actualizar en Supabase si es posible
      try {
        await Supabase.instance.client.auth.updateUser(
          UserAttributes(data: {'full_name': fullName}),
        );
        debugPrint('[AuthService] Supabase profile updated');
      } catch (e) {
        debugPrint('[AuthService] Could not update Supabase profile: $e');
      }
    } catch (e) {
      debugPrint('[AuthService] Error in updateGivenName: $e');
    }
  }

  /// Vincula cuenta con Google (no soportado actualmente en Supabase de esta forma)
  Future<AuthResponse?> linkWithGoogle() async {
    debugPrint('[AuthService] linkWithGoogle not implemented for Supabase');
    return null;
  }

  /// Vincula cuenta con Apple (no soportado actualmente en Supabase de esta forma)
  Future<AuthResponse?> linkWithApple() async {
    debugPrint('[AuthService] linkWithApple not implemented for Supabase');
    return null;
  }
}
