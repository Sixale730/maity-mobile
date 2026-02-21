enum UserRole { admin, manager, user }

const List<String> adminDomains = ['asertio.mx', 'maity.cloud'];

UserRole getUserRoleFromEmail(String? email) {
  if (email == null || email.isEmpty) return UserRole.user;
  final domain = email.split('@').last.toLowerCase();
  return adminDomains.contains(domain) ? UserRole.admin : UserRole.user;
}

extension UserRoleExtension on UserRole {
  bool get isAdmin => this == UserRole.admin;
  bool get isManager => this == UserRole.manager;
  bool get isUser => this == UserRole.user;

  String get displayName {
    switch (this) {
      case UserRole.admin:
        return 'Admin';
      case UserRole.manager:
        return 'Manager';
      case UserRole.user:
        return 'User';
    }
  }
}
