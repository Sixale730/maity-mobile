import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/providers/base_provider.dart';
import 'package:omi/services/notifications.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// Provider de autenticación usando Supabase Auth
/// Reemplaza la versión anterior basada en Firebase Auth
class AuthenticationProvider extends BaseProvider {
  final SupabaseAuthService _authService = SupabaseAuthService.instance;

  User? user;
  String? authToken;
  String? maityUserId; // UUID de maity.users
  bool _loading = false;

  StreamSubscription<AuthState>? _authSubscription;

  @override
  bool get loading => _loading;

  AuthenticationProvider() {
    _initializeAuthListeners();
  }

  void _initializeAuthListeners() {
    Future.microtask(() async {
      // Restaurar sesión existente
      await _authService.restoreSession();

      // Actualizar estado inicial
      user = _authService.currentUser;
      maityUserId = _authService.maityUserId;
      if (_authService.currentSession != null) {
        authToken = _authService.currentSession!.accessToken;
      }

      // Escuchar cambios de autenticación
      _authSubscription = _authService.onAuthStateChange.listen((AuthState state) async {
        debugPrint('[AuthProvider] Auth state changed: ${state.event}');

        switch (state.event) {
          case AuthChangeEvent.signedIn:
          case AuthChangeEvent.tokenRefreshed:
            user = state.session?.user;
            authToken = state.session?.accessToken;
            if (user != null) {
              // Obtener maity.users.id
              maityUserId = await _authService.fetchMaityUserId();
              SharedPreferencesUtil().uid = maityUserId ?? '';
              SharedPreferencesUtil().email = user?.email ?? '';

              // Si el usuario ya existe en maity.users, significa que completó onboarding antes
              // Esto funciona como fallback si SharedPreferences pierde el flag
              if (maityUserId != null && !SharedPreferencesUtil().onboardingCompleted) {
                debugPrint('[AuthProvider] Usuario existente detectado, marcando onboarding como completado');
                SharedPreferencesUtil().onboardingCompleted = true;
              }

              // Obtener nombre del metadata
              final metadata = user?.userMetadata;
              if (metadata != null) {
                final fullName = metadata['full_name'] as String? ??
                    metadata['name'] as String? ??
                    '';
                if (fullName.isNotEmpty) {
                  final parts = fullName.split(' ');
                  SharedPreferencesUtil().givenName = parts.isNotEmpty ? parts[0] : '';
                  SharedPreferencesUtil().familyName =
                      parts.length > 1 ? parts.sublist(1).join(' ') : '';
                }
              }
            }
            break;

          case AuthChangeEvent.signedOut:
            user = null;
            authToken = null;
            maityUserId = null;
            SharedPreferencesUtil().uid = '';
            SharedPreferencesUtil().authToken = '';
            break;

          default:
            break;
        }

        notifyListeners();
      });
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  /// Verifica si el usuario está autenticado
  bool isSignedIn() => _authService.isSignedIn;

  void setLoading(bool value) {
    _loading = value;
    notifyListeners();
  }

  // ============================================================
  // Google Sign In
  // ============================================================

  Future<void> onGoogleSignIn(Function() onSignIn) async {
    if (!loading) {
      setLoadingState(true);
      try {
        final response = await _authService.signInWithGoogleNative();

        if (response.user != null && isSignedIn()) {
          await _onSignInSuccess(onSignIn);
        } else {
          AppSnackbar.showSnackbarError('Error al iniciar sesión con Google, intenta de nuevo.');
        }
      } catch (e) {
        debugPrint('[AuthProvider] Google sign in error: $e');
        if (e.toString().contains('cancelado')) {
          // Usuario canceló, no mostrar error
        } else {
          AppSnackbar.showSnackbarError('Error de autenticación. Intenta de nuevo.');
        }
      }
      setLoadingState(false);
    }
  }

  // ============================================================
  // Sign In Success Handler
  // ============================================================

  Future<void> _onSignInSuccess(Function() onSignIn) async {
    try {
      // Obtener token
      final token = await _authService.getAccessToken();
      if (token == null) {
        AppSnackbar.showSnackbarError('Error al obtener token, intenta de nuevo.');
        return;
      }

      authToken = token;

      // Obtener maity.users.id
      maityUserId = await _authService.fetchMaityUserId();
      if (maityUserId != null) {
        SharedPreferencesUtil().uid = maityUserId!;

        // Si el usuario ya existe en maity.users, significa que completó onboarding antes
        if (!SharedPreferencesUtil().onboardingCompleted) {
          debugPrint('[AuthProvider] Usuario existente detectado en sign-in, marcando onboarding como completado');
          SharedPreferencesUtil().onboardingCompleted = true;
        }
      }

      // Registrar token de notificaciones
      NotificationService.instance.saveNotificationToken();

      // Identificar en analytics
      MixpanelManager().identify();

      // Callback de éxito
      onSignIn();
    } catch (e, stackTrace) {
      debugPrint('[AuthProvider] Sign in success handler error: $e');
      PlatformManager.instance.crashReporter.reportCrash(e, stackTrace);
      AppSnackbar.showSnackbarError('Error inesperado al iniciar sesión.');
    }
  }

  // ============================================================
  // Sign Out
  // ============================================================

  Future<void> signOut() async {
    try {
      await _authService.signOut();
      notifyListeners();
    } catch (e) {
      debugPrint('[AuthProvider] Sign out error: $e');
      AppSnackbar.showSnackbarError('Error al cerrar sesión.');
    }
  }

  // ============================================================
  // Token Management
  // ============================================================

  Future<String?> getIdToken() async {
    try {
      return await _authService.getAccessToken();
    } catch (e) {
      debugPrint('[AuthProvider] Get token error: $e');
      return null;
    }
  }

  // ============================================================
  // Legal Links
  // ============================================================

  void openTermsOfService() {
    _launchUrl('https://www.omi.me/pages/terms-of-service');
  }

  void openPrivacyPolicy() {
    _launchUrl('https://www.omi.me/pages/privacy');
  }

  void _launchUrl(String url) async {
    if (!await launchUrl(Uri.parse(url))) throw 'Could not launch $url';
  }

  // ============================================================
  // Apple Sign In
  // ============================================================

  Future<void> onAppleSignIn(Function() onSignIn) async {
    if (!loading) {
      setLoadingState(true);
      try {
        final response = await _authService.signInWithAppleNative();

        if (response.user != null && isSignedIn()) {
          await _onSignInSuccess(onSignIn);
        } else {
          AppSnackbar.showSnackbarError('Error al iniciar sesión con Apple, intenta de nuevo.');
        }
      } catch (e) {
        debugPrint('[AuthProvider] Apple sign in error: $e');
        if (e.toString().contains('AuthorizationErrorCode.canceled')) {
          // Usuario canceló, no mostrar error
        } else {
          AppSnackbar.showSnackbarError('Error de autenticación. Intenta de nuevo.');
        }
      }
      setLoadingState(false);
    }
  }

  /// @deprecated Ya no soportamos usuarios anónimos
  Future<void> onAnonymousSignIn(Function() onSignIn) async {
    AppSnackbar.showSnackbarError('Por favor inicia sesión con Google');
  }

  /// @deprecated Ya no es necesario con Supabase Auth
  Future<void> linkWithGoogle() async {
    // No-op: Supabase maneja el linking automáticamente
  }

  /// @deprecated Ya no es necesario con Supabase Auth
  Future<void> linkWithApple() async {
    // No-op: Supabase maneja el linking automáticamente
  }
}
