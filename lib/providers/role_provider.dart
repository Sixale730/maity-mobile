import 'package:flutter/material.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/models/user_role.dart';
import 'package:omi/providers/base_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Provider that manages the current user's role.
///
/// Source of truth: Supabase RPC `get_user_role`.
/// Falls back to email-domain heuristic if the RPC call fails.
/// Caches the resolved role in SharedPreferences so that subsequent
/// cold-starts have a role available immediately.
class RoleProvider extends BaseProvider {
  static const String _cacheKey = 'cachedUserRole';

  UserRole _role = UserRole.user;

  UserRole get role => _role;
  bool get isAdmin => _role.isAdmin;
  bool get isManager => _role.isManager;
  bool get isUser => _role.isUser;

  RoleProvider() {
    _loadRole();
  }

  /// Loads the role: first from cache (instant), then from RPC (async).
  Future<void> _loadRole() async {
    // 1. Restore from cache for instant availability
    final cached = SharedPreferencesUtil().getString(_cacheKey);
    if (cached.isNotEmpty) {
      _role = _parseRole(cached);
      notifyListeners();
    }

    // 2. Fetch from Supabase RPC (source of truth)
    await _fetchRoleFromRpc();
  }

  /// Calls `get_user_role` RPC and updates the role.
  /// Falls back to email-domain heuristic on failure.
  Future<void> _fetchRoleFromRpc() async {
    try {
      final response = await Supabase.instance.client.rpc('get_user_role');

      // The RPC returns a text value like 'admin', 'manager', or 'user'
      if (response != null) {
        final roleString = response.toString().toLowerCase().trim();
        _role = _parseRole(roleString);
        _cacheRole(_role);
        notifyListeners();
        debugPrint('[RoleProvider] Role from RPC: $_role');
        return;
      }
    } catch (e) {
      debugPrint('[RoleProvider] RPC get_user_role failed: $e');
    }

    // 3. Fallback: derive from email domain
    final email = SharedPreferencesUtil().email;
    _role = getUserRoleFromEmail(email);
    _cacheRole(_role);
    notifyListeners();
    debugPrint('[RoleProvider] Role from email fallback: $_role');
  }

  /// Force-refresh the role (e.g. after a role change server-side).
  Future<void> refreshRole() async {
    await _fetchRoleFromRpc();
  }

  /// Persist the role string to SharedPreferences.
  void _cacheRole(UserRole role) {
    SharedPreferencesUtil().saveString(_cacheKey, role.name);
  }

  /// Parse a string into a [UserRole], defaulting to [UserRole.user].
  UserRole _parseRole(String value) {
    switch (value) {
      case 'admin':
        return UserRole.admin;
      case 'manager':
        return UserRole.manager;
      default:
        return UserRole.user;
    }
  }
}
