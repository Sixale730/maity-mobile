import 'package:flutter/material.dart';
import 'package:omi/backend/http/api/speech_profile.dart';
import 'package:omi/backend/http/api/users.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/analytics/analytics_manager.dart';

class HomeProvider extends ChangeNotifier {
  int selectedIndex = 0;
  Function(int idx)? onSelectedIndexChanged;
  final FocusNode chatFieldFocusNode = FocusNode();
  final FocusNode appsSearchFieldFocusNode = FocusNode();
  final FocusNode convoSearchFieldFocusNode = FocusNode();
  final FocusNode memoriesSearchFieldFocusNode = FocusNode();
  bool isAppsSearchFieldFocused = false;
  bool isChatFieldFocused = false;
  bool isConvoSearchFieldFocused = false;
  bool isMemoriesSearchFieldFocused = false;
  bool hasSpeakerProfile = true;
  bool isLoading = false;
  String userPrimaryLanguage = SharedPreferencesUtil().userPrimaryLanguage;
  bool hasSetPrimaryLanguage = SharedPreferencesUtil().hasSetPrimaryLanguage;

  // Available languages ordered by popularity
  final Map<String, String> availableLanguages = {
    // Top languages first
    'English': 'en',
    'Spanish': 'es',
    'Chinese (Mandarin, Simplified)': 'zh',
    'Hindi': 'hi',
    'Portuguese': 'pt',
    'Russian': 'ru',
    'Japanese': 'ja',
    'German': 'de',
    // Other languages alphabetically
    'Bulgarian': 'bg',
    'Catalan': 'ca',
    'Chinese (Mandarin, Traditional)': 'zh-TW',
    'Chinese (Cantonese, Traditional)': 'zh-HK',
    'Czech': 'cs',
    'Danish': 'da',
    'Dutch': 'nl',
    'Estonian': 'et',
    'Finnish': 'fi',
    'Flemish': 'nl-BE',
    'French': 'fr',
    'German (Switzerland)': 'de-CH',
    'Greek': 'el',
    'Hungarian': 'hu',
    'Indonesian': 'id',
    'Italian': 'it',
    'Korean': 'ko',
    'Latvian': 'lv',
    'Lithuanian': 'lt',
    'Malay': 'ms',
    'Norwegian': 'no',
    'Polish': 'pl',
    'Romanian': 'ro',
    'Slovak': 'sk',
    'Swedish': 'sv',
    'Thai': 'th',
    'Turkish': 'tr',
    'Ukrainian': 'uk',
    'Vietnamese': 'vi',
  };

  HomeProvider() {
    chatFieldFocusNode.addListener(_onFocusChange);
    appsSearchFieldFocusNode.addListener(_onFocusChange);
    convoSearchFieldFocusNode.addListener(_onFocusChange);
    memoriesSearchFieldFocusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    isChatFieldFocused = chatFieldFocusNode.hasFocus;
    isAppsSearchFieldFocused = appsSearchFieldFocusNode.hasFocus;
    isConvoSearchFieldFocused = convoSearchFieldFocusNode.hasFocus;
    isMemoriesSearchFieldFocused = memoriesSearchFieldFocusNode.hasFocus;
    notifyListeners();
  }

  /// Maps nav bar index to IndexedStack index.
  /// Nav: 0=Home, 1=Conversations, 2=FAB(intercepted), 3=Tasks, 4=Insights
  /// Stack: 0=Dashboard, 1=Conversations, 2=Tasks, 3=Insights
  int get stackIndex {
    switch (selectedIndex) {
      case 0:
        return 0;
      case 1:
        return 1;
      case 3:
        return 2;
      case 4:
        return 3;
      default:
        return 0;
    }
  }

  void setIndex(int index) {
    // Index 2 is FAB, don't change tab for it
    if (index == 2) return;
    selectedIndex = index;
    notifyListeners();
  }

  void setIsLoading(bool loading) {
    isLoading = loading;
    notifyListeners();
  }

  void setSpeakerProfile(bool? value) {
    hasSpeakerProfile = value ?? SharedPreferencesUtil().hasSpeakerProfile;
    notifyListeners();
  }

  Future setupHasSpeakerProfile() async {
    setIsLoading(true);
    var res = await userHasSpeakerProfile();
    setSpeakerProfile(res);
    SharedPreferencesUtil().hasSpeakerProfile = res;
    debugPrint('_setupHasSpeakerProfile: ${SharedPreferencesUtil().hasSpeakerProfile}');
    AnalyticsManager().setUserAttribute('Speaker Profile', SharedPreferencesUtil().hasSpeakerProfile);

    setIsLoading(false);
    notifyListeners();
  }

  Future<void> setupUserPrimaryLanguage() async {
    // Use local storage only - api.omi.me doesn't accept our Firebase tokens
    final storedLanguage = SharedPreferencesUtil().userPrimaryLanguage;
    final hasSet = SharedPreferencesUtil().hasSetPrimaryLanguage;

    if (hasSet && storedLanguage.isNotEmpty) {
      userPrimaryLanguage = storedLanguage;
      hasSetPrimaryLanguage = true;
      AnalyticsManager().setUserAttribute('Primary Language', storedLanguage);
      debugPrint('setupUserPrimaryLanguage: loaded from local storage: $storedLanguage');
      notifyListeners();
      return;
    }

    // User hasn't set a primary language yet - use 'multi' (auto-detect) as default
    // User can change this manually in Settings → Profile → Primary Language
    userPrimaryLanguage = 'multi';
    hasSetPrimaryLanguage = true;
    SharedPreferencesUtil().userPrimaryLanguage = 'multi';
    SharedPreferencesUtil().hasSetPrimaryLanguage = true;
    AnalyticsManager().setUserAttribute('Primary Language', 'multi');

    debugPrint('setupUserPrimaryLanguage: no language set, using multi (auto-detect) as default');
    notifyListeners();
  }

  Future<bool> updateUserPrimaryLanguage(String languageCode) async {
    // Save locally only - api.omi.me doesn't accept our Firebase tokens
    try {
      userPrimaryLanguage = languageCode;
      hasSetPrimaryLanguage = true;
      SharedPreferencesUtil().userPrimaryLanguage = languageCode;
      SharedPreferencesUtil().hasSetPrimaryLanguage = true;
      AnalyticsManager().setUserAttribute('Primary Language', languageCode);
      debugPrint('updateUserPrimaryLanguage: saved $languageCode to local storage');
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error setting user primary language: $e');
      return false;
    }
  }

  String getLanguageName(String code) {
    return availableLanguages.entries.firstWhere((element) => element.value == code).key;
  }

  Future setUserPeople() async {
    SharedPreferencesUtil().cachedPeople = await getAllPeople();
    notifyListeners();
  }

  @override
  void dispose() {
    chatFieldFocusNode.removeListener(_onFocusChange);
    appsSearchFieldFocusNode.removeListener(_onFocusChange);
    convoSearchFieldFocusNode.removeListener(_onFocusChange);
    memoriesSearchFieldFocusNode.removeListener(_onFocusChange);
    memoriesSearchFieldFocusNode.dispose();
    chatFieldFocusNode.dispose();
    appsSearchFieldFocusNode.dispose();
    convoSearchFieldFocusNode.dispose();
    onSelectedIndexChanged = null;
    super.dispose();
  }
}
