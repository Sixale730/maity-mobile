import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en'), Locale('es')];

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @profile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profile;

  /// No description provided for @planAndUsage.
  ///
  /// In en, this message translates to:
  /// **'Plan & Usage'**
  String get planAndUsage;

  /// No description provided for @usageInsights.
  ///
  /// In en, this message translates to:
  /// **'Usage Insights'**
  String get usageInsights;

  /// No description provided for @storage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get storage;

  /// No description provided for @deviceSettings.
  ///
  /// In en, this message translates to:
  /// **'Device Settings'**
  String get deviceSettings;

  /// No description provided for @chatTools.
  ///
  /// In en, this message translates to:
  /// **'Chat Tools'**
  String get chatTools;

  /// No description provided for @shareOmiIphone.
  ///
  /// In en, this message translates to:
  /// **'Share Omi for iPhone'**
  String get shareOmiIphone;

  /// No description provided for @shareOmiAndroid.
  ///
  /// In en, this message translates to:
  /// **'Share Omi for Android'**
  String get shareOmiAndroid;

  /// No description provided for @getOmiMac.
  ///
  /// In en, this message translates to:
  /// **'Get Omi for Mac'**
  String get getOmiMac;

  /// No description provided for @referralProgram.
  ///
  /// In en, this message translates to:
  /// **'Referral Program'**
  String get referralProgram;

  /// No description provided for @feedbackBug.
  ///
  /// In en, this message translates to:
  /// **'Feedback / Bug'**
  String get feedbackBug;

  /// No description provided for @helpCenter.
  ///
  /// In en, this message translates to:
  /// **'Help Center'**
  String get helpCenter;

  /// No description provided for @dataPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Data & Privacy'**
  String get dataPrivacy;

  /// No description provided for @developerSettings.
  ///
  /// In en, this message translates to:
  /// **'Developer Settings'**
  String get developerSettings;

  /// No description provided for @aboutOmi.
  ///
  /// In en, this message translates to:
  /// **'About Omi'**
  String get aboutOmi;

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign Out'**
  String get signOut;

  /// No description provided for @signOutQuestion.
  ///
  /// In en, this message translates to:
  /// **'Sign Out?'**
  String get signOutQuestion;

  /// No description provided for @signOutConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to sign out?'**
  String get signOutConfirmation;

  /// No description provided for @appDeviceDetailsCopied.
  ///
  /// In en, this message translates to:
  /// **'App and device details copied'**
  String get appDeviceDetailsCopied;

  /// No description provided for @beta.
  ///
  /// In en, this message translates to:
  /// **'BETA'**
  String get beta;

  /// No description provided for @new_.
  ///
  /// In en, this message translates to:
  /// **'NEW'**
  String get new_;

  /// No description provided for @needHelpChat.
  ///
  /// In en, this message translates to:
  /// **'Need Help? Chat with us'**
  String get needHelpChat;

  /// No description provided for @unknownDevice.
  ///
  /// In en, this message translates to:
  /// **'Unknown Device'**
  String get unknownDevice;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @home.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get home;

  /// No description provided for @chat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get chat;

  /// No description provided for @conversations.
  ///
  /// In en, this message translates to:
  /// **'Conversations'**
  String get conversations;

  /// No description provided for @apps.
  ///
  /// In en, this message translates to:
  /// **'Apps'**
  String get apps;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @yes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get yes;

  /// No description provided for @no.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get no;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @continueText.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueText;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get loading;

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;

  /// No description provided for @success.
  ///
  /// In en, this message translates to:
  /// **'Success'**
  String get success;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// No description provided for @noConversations.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get noConversations;

  /// No description provided for @startRecording.
  ///
  /// In en, this message translates to:
  /// **'Start Recording'**
  String get startRecording;

  /// No description provided for @stopRecording.
  ///
  /// In en, this message translates to:
  /// **'Stop Recording'**
  String get stopRecording;

  /// No description provided for @processing.
  ///
  /// In en, this message translates to:
  /// **'Processing...'**
  String get processing;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get connecting;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get disconnected;

  /// No description provided for @notConnected.
  ///
  /// In en, this message translates to:
  /// **'Not Connected'**
  String get notConnected;

  /// No description provided for @selectLanguage.
  ///
  /// In en, this message translates to:
  /// **'Select Language'**
  String get selectLanguage;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @spanish.
  ///
  /// In en, this message translates to:
  /// **'Spanish'**
  String get spanish;

  /// No description provided for @transcription.
  ///
  /// In en, this message translates to:
  /// **'Transcription'**
  String get transcription;

  /// No description provided for @summary.
  ///
  /// In en, this message translates to:
  /// **'Summary'**
  String get summary;

  /// No description provided for @actionItems.
  ///
  /// In en, this message translates to:
  /// **'Action Items'**
  String get actionItems;

  /// No description provided for @noActionItems.
  ///
  /// In en, this message translates to:
  /// **'No action items'**
  String get noActionItems;

  /// No description provided for @today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get today;

  /// No description provided for @yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get yesterday;

  /// No description provided for @thisWeek.
  ///
  /// In en, this message translates to:
  /// **'This Week'**
  String get thisWeek;

  /// No description provided for @thisMonth.
  ///
  /// In en, this message translates to:
  /// **'This Month'**
  String get thisMonth;

  /// No description provided for @older.
  ///
  /// In en, this message translates to:
  /// **'Older'**
  String get older;

  /// No description provided for @speakerProfile.
  ///
  /// In en, this message translates to:
  /// **'Speaker Profile'**
  String get speakerProfile;

  /// No description provided for @setupSpeakerProfile.
  ///
  /// In en, this message translates to:
  /// **'Set up your speaker profile'**
  String get setupSpeakerProfile;

  /// No description provided for @people.
  ///
  /// In en, this message translates to:
  /// **'People'**
  String get people;

  /// No description provided for @speechProfile.
  ///
  /// In en, this message translates to:
  /// **'Speech Profile'**
  String get speechProfile;

  /// No description provided for @voiceProfileTrained.
  ///
  /// In en, this message translates to:
  /// **'Trained'**
  String get voiceProfileTrained;

  /// No description provided for @identifyingOthers.
  ///
  /// In en, this message translates to:
  /// **'Identifying Others'**
  String get identifyingOthers;

  /// No description provided for @conversationTimeout.
  ///
  /// In en, this message translates to:
  /// **'Conversation Timeout'**
  String get conversationTimeout;

  /// No description provided for @importData.
  ///
  /// In en, this message translates to:
  /// **'Import Data'**
  String get importData;

  /// No description provided for @maityNeedsToLearnVoice.
  ///
  /// In en, this message translates to:
  /// **'Maity needs to learn your voice to be able to recognise you.'**
  String get maityNeedsToLearnVoice;

  /// No description provided for @howToTakeGoodSample.
  ///
  /// In en, this message translates to:
  /// **'How to take a good sample?'**
  String get howToTakeGoodSample;

  /// No description provided for @howToTakeGoodSampleDesc.
  ///
  /// In en, this message translates to:
  /// **'1. Make sure you are in a quiet place.\n2. Speak clearly and naturally.\n3. Make sure your device is in it\'s natural position, on your neck.\n\nOnce it\'s created, you can always improve it or do it again.'**
  String get howToTakeGoodSampleDesc;

  /// No description provided for @introduceYourself.
  ///
  /// In en, this message translates to:
  /// **'Introduce\nyourself'**
  String get introduceYourself;

  /// No description provided for @doItAgain.
  ///
  /// In en, this message translates to:
  /// **'Do it again'**
  String get doItAgain;

  /// No description provided for @listenToMySpeechProfile.
  ///
  /// In en, this message translates to:
  /// **'Listen to my speech profile'**
  String get listenToMySpeechProfile;

  /// No description provided for @recognizingOthers.
  ///
  /// In en, this message translates to:
  /// **'Recognizing others'**
  String get recognizingOthers;

  /// No description provided for @allDone.
  ///
  /// In en, this message translates to:
  /// **'All done!'**
  String get allDone;

  /// No description provided for @skipForNow.
  ///
  /// In en, this message translates to:
  /// **'Skip for now'**
  String get skipForNow;

  /// No description provided for @multipleSpeakersDetected.
  ///
  /// In en, this message translates to:
  /// **'Multiple speakers detected'**
  String get multipleSpeakersDetected;

  /// No description provided for @multipleSpeakersDesc.
  ///
  /// In en, this message translates to:
  /// **'It seems like there are multiple speakers in the recording. Please make sure you are in a quiet location and try again.'**
  String get multipleSpeakersDesc;

  /// No description provided for @tryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try Again'**
  String get tryAgain;

  /// No description provided for @invalidRecordingDetected.
  ///
  /// In en, this message translates to:
  /// **'Invalid recording detected'**
  String get invalidRecordingDetected;

  /// No description provided for @notEnoughSpeech.
  ///
  /// In en, this message translates to:
  /// **'There is not enough speech detected. Please speak more and try again.'**
  String get notEnoughSpeech;

  /// No description provided for @invalidRecordingDesc.
  ///
  /// In en, this message translates to:
  /// **'Please make sure you speak for at least 5 seconds and not more than 90.'**
  String get invalidRecordingDesc;

  /// No description provided for @authenticationRequired.
  ///
  /// In en, this message translates to:
  /// **'Authentication Required'**
  String get authenticationRequired;

  /// No description provided for @authRequiredDesc.
  ///
  /// In en, this message translates to:
  /// **'You need to be signed in to create your voice profile. Please sign in and try again.'**
  String get authRequiredDesc;

  /// No description provided for @voiceProfileError.
  ///
  /// In en, this message translates to:
  /// **'Voice Profile Error'**
  String get voiceProfileError;

  /// No description provided for @voiceProfileErrorDesc.
  ///
  /// In en, this message translates to:
  /// **'Could not save your voice profile. Please check your internet connection and try again.'**
  String get voiceProfileErrorDesc;

  /// No description provided for @verificationError.
  ///
  /// In en, this message translates to:
  /// **'Verification Error'**
  String get verificationError;

  /// No description provided for @verificationErrorDesc.
  ///
  /// In en, this message translates to:
  /// **'Your voice profile was not saved correctly. Please try again.'**
  String get verificationErrorDesc;

  /// No description provided for @deviceDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Device Disconnected'**
  String get deviceDisconnected;

  /// No description provided for @deviceDisconnectedDesc.
  ///
  /// In en, this message translates to:
  /// **'Please make sure your device is turned on and nearby, and try again.'**
  String get deviceDisconnectedDesc;

  /// No description provided for @deviceUpdateRequired.
  ///
  /// In en, this message translates to:
  /// **'Device Update Required'**
  String get deviceUpdateRequired;

  /// No description provided for @deviceUpdateRequiredDesc.
  ///
  /// In en, this message translates to:
  /// **'Your current device has an old firmware version (1.0.2). Please check our guide on how to update it.'**
  String get deviceUpdateRequiredDesc;

  /// No description provided for @viewGuide.
  ///
  /// In en, this message translates to:
  /// **'View Guide'**
  String get viewGuide;

  /// No description provided for @connectionError.
  ///
  /// In en, this message translates to:
  /// **'Connection Error'**
  String get connectionError;

  /// No description provided for @connectionErrorDesc.
  ///
  /// In en, this message translates to:
  /// **'Failed to start speech profile recording. Please check your internet connection and try again.'**
  String get connectionErrorDesc;

  /// No description provided for @notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// No description provided for @permissionsRequired.
  ///
  /// In en, this message translates to:
  /// **'Permissions Required'**
  String get permissionsRequired;

  /// No description provided for @enableNotifications.
  ///
  /// In en, this message translates to:
  /// **'Enable Notifications'**
  String get enableNotifications;

  /// No description provided for @enableLocation.
  ///
  /// In en, this message translates to:
  /// **'Enable Location'**
  String get enableLocation;

  /// No description provided for @welcomeToMaity.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Maity'**
  String get welcomeToMaity;

  /// No description provided for @yourAiCompanion.
  ///
  /// In en, this message translates to:
  /// **'Your AI Companion'**
  String get yourAiCompanion;

  /// No description provided for @getStarted.
  ///
  /// In en, this message translates to:
  /// **'Get Started'**
  String get getStarted;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @speakTranscribeSummarize.
  ///
  /// In en, this message translates to:
  /// **'Speak. Transcribe. Summarize.'**
  String get speakTranscribeSummarize;

  /// No description provided for @signInWithApple.
  ///
  /// In en, this message translates to:
  /// **'Sign in with Apple'**
  String get signInWithApple;

  /// No description provided for @signInWithGoogle.
  ///
  /// In en, this message translates to:
  /// **'Sign in with Google'**
  String get signInWithGoogle;

  /// No description provided for @byContinuingYouAgree.
  ///
  /// In en, this message translates to:
  /// **'By continuing, you agree to our '**
  String get byContinuingYouAgree;

  /// No description provided for @privacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get privacyPolicy;

  /// No description provided for @termsOfUse.
  ///
  /// In en, this message translates to:
  /// **'Terms of Use'**
  String get termsOfUse;

  /// No description provided for @maityYourAiCompanion.
  ///
  /// In en, this message translates to:
  /// **'Maity – Your AI Companion'**
  String get maityYourAiCompanion;

  /// No description provided for @captureEveryMoment.
  ///
  /// In en, this message translates to:
  /// **'Capture every moment. Get AI-powered\nsummaries. Never take notes again.'**
  String get captureEveryMoment;

  /// No description provided for @permissionsRequiredMessage.
  ///
  /// In en, this message translates to:
  /// **'This app needs Bluetooth and Location permissions to function properly. Please enable them in the settings.'**
  String get permissionsRequiredMessage;

  /// No description provided for @openSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get openSettings;

  /// No description provided for @connectDevice.
  ///
  /// In en, this message translates to:
  /// **'Connect Omi / OmiGlass'**
  String get connectDevice;

  /// No description provided for @continueWithoutDevice.
  ///
  /// In en, this message translates to:
  /// **'Continue Without Device'**
  String get continueWithoutDevice;

  /// No description provided for @selectYourPrimaryLanguage.
  ///
  /// In en, this message translates to:
  /// **'Select your primary language'**
  String get selectYourPrimaryLanguage;

  /// No description provided for @languageDescription.
  ///
  /// In en, this message translates to:
  /// **'Set your language for sharper transcriptions and a personalized experience'**
  String get languageDescription;

  /// No description provided for @searchLanguageByNameOrCode.
  ///
  /// In en, this message translates to:
  /// **'Search language by name or code'**
  String get searchLanguageByNameOrCode;

  /// No description provided for @noLanguagesFound.
  ///
  /// In en, this message translates to:
  /// **'No languages found'**
  String get noLanguagesFound;

  /// No description provided for @whatsYourPrimaryLanguage.
  ///
  /// In en, this message translates to:
  /// **'What\'s your primary language?'**
  String get whatsYourPrimaryLanguage;

  /// No description provided for @selectYourLanguage.
  ///
  /// In en, this message translates to:
  /// **'Select your language'**
  String get selectYourLanguage;

  /// No description provided for @whatsYourName.
  ///
  /// In en, this message translates to:
  /// **'What\'s your name?'**
  String get whatsYourName;

  /// No description provided for @wantDifferentName.
  ///
  /// In en, this message translates to:
  /// **'Want to go by something else?'**
  String get wantDifferentName;

  /// No description provided for @enterYourName.
  ///
  /// In en, this message translates to:
  /// **'Enter your name'**
  String get enterYourName;

  /// No description provided for @grantPermissions.
  ///
  /// In en, this message translates to:
  /// **'Grant permissions'**
  String get grantPermissions;

  /// No description provided for @backgroundActivity.
  ///
  /// In en, this message translates to:
  /// **'Background activity'**
  String get backgroundActivity;

  /// No description provided for @backgroundActivityDesc.
  ///
  /// In en, this message translates to:
  /// **'Let the app run in the background for better stability'**
  String get backgroundActivityDesc;

  /// No description provided for @locationAccess.
  ///
  /// In en, this message translates to:
  /// **'Location access'**
  String get locationAccess;

  /// No description provided for @locationAccessDesc.
  ///
  /// In en, this message translates to:
  /// **'Enable background location for the full experience'**
  String get locationAccessDesc;

  /// No description provided for @notificationsDesc.
  ///
  /// In en, this message translates to:
  /// **'Enable notifications to stay informed'**
  String get notificationsDesc;

  /// No description provided for @insights.
  ///
  /// In en, this message translates to:
  /// **'Insights'**
  String get insights;

  /// No description provided for @thisYear.
  ///
  /// In en, this message translates to:
  /// **'This Year'**
  String get thisYear;

  /// No description provided for @allTime.
  ///
  /// In en, this message translates to:
  /// **'All Time'**
  String get allTime;

  /// No description provided for @unlimitedPlan.
  ///
  /// In en, this message translates to:
  /// **'Unlimited Plan'**
  String get unlimitedPlan;

  /// No description provided for @basicPlan.
  ///
  /// In en, this message translates to:
  /// **'Basic Plan'**
  String get basicPlan;

  /// No description provided for @managePlan.
  ///
  /// In en, this message translates to:
  /// **'Manage Plan'**
  String get managePlan;

  /// No description provided for @upgrade.
  ///
  /// In en, this message translates to:
  /// **'Upgrade'**
  String get upgrade;

  /// No description provided for @upgradeToUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Upgrade to Unlimited'**
  String get upgradeToUnlimited;

  /// No description provided for @planWillCancel.
  ///
  /// In en, this message translates to:
  /// **'Your plan will cancel on {date}.'**
  String planWillCancel(String date);

  /// No description provided for @planRenews.
  ///
  /// In en, this message translates to:
  /// **'Your plan renews on {date}.'**
  String planRenews(String date);

  /// No description provided for @planIncludesMinutes.
  ///
  /// In en, this message translates to:
  /// **'Your plan includes {minutes} free minutes per month. Upgrade to go unlimited.'**
  String planIncludesMinutes(int minutes);

  /// No description provided for @minsUsedOf.
  ///
  /// In en, this message translates to:
  /// **'{used} of {limit} mins used'**
  String minsUsedOf(String used, int limit);

  /// No description provided for @notAvailable.
  ///
  /// In en, this message translates to:
  /// **'N/A'**
  String get notAvailable;

  /// No description provided for @noActivityYet.
  ///
  /// In en, this message translates to:
  /// **'No Activity Yet'**
  String get noActivityYet;

  /// No description provided for @startConversationPrompt.
  ///
  /// In en, this message translates to:
  /// **'Start a conversation with Maity\nto see your usage insights here.'**
  String get startConversationPrompt;

  /// No description provided for @listening.
  ///
  /// In en, this message translates to:
  /// **'Listening'**
  String get listening;

  /// No description provided for @thinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get thinking;

  /// No description provided for @muted.
  ///
  /// In en, this message translates to:
  /// **'Muted'**
  String get muted;

  /// No description provided for @paused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get paused;

  /// No description provided for @listeningDesc.
  ///
  /// In en, this message translates to:
  /// **'Total time Maity has actively listened.'**
  String get listeningDesc;

  /// No description provided for @understanding.
  ///
  /// In en, this message translates to:
  /// **'Understanding'**
  String get understanding;

  /// No description provided for @understandingDesc.
  ///
  /// In en, this message translates to:
  /// **'Words understood from your conversations.'**
  String get understandingDesc;

  /// No description provided for @providing.
  ///
  /// In en, this message translates to:
  /// **'Providing'**
  String get providing;

  /// No description provided for @providingDesc.
  ///
  /// In en, this message translates to:
  /// **'Action items, and notes automatically captured.'**
  String get providingDesc;

  /// No description provided for @remembering.
  ///
  /// In en, this message translates to:
  /// **'Remembering'**
  String get remembering;

  /// No description provided for @rememberingDesc.
  ///
  /// In en, this message translates to:
  /// **'Facts and details remembered for you.'**
  String get rememberingDesc;

  /// No description provided for @listeningMins.
  ///
  /// In en, this message translates to:
  /// **'Listening (mins)'**
  String get listeningMins;

  /// No description provided for @understandingWords.
  ///
  /// In en, this message translates to:
  /// **'Understanding (words)'**
  String get understandingWords;

  /// No description provided for @insightsLabel.
  ///
  /// In en, this message translates to:
  /// **'Insights'**
  String get insightsLabel;

  /// No description provided for @memoriesLabel.
  ///
  /// In en, this message translates to:
  /// **'Memories'**
  String get memoriesLabel;

  /// No description provided for @minUsedThisMonth.
  ///
  /// In en, this message translates to:
  /// **'{used} of {limit} min used this month'**
  String minUsedThisMonth(String used, int limit);

  /// No description provided for @wordsUsedThisMonth.
  ///
  /// In en, this message translates to:
  /// **'{used} of {limit} words used this month'**
  String wordsUsedThisMonth(String used, String limit);

  /// No description provided for @insightsGainedThisMonth.
  ///
  /// In en, this message translates to:
  /// **'{used} of {limit} insights gained this month'**
  String insightsGainedThisMonth(String used, String limit);

  /// No description provided for @memoriesCreatedThisMonth.
  ///
  /// In en, this message translates to:
  /// **'{used} of {limit} memories created this month'**
  String memoriesCreatedThisMonth(String used, String limit);

  /// No description provided for @shareBaseText.
  ///
  /// In en, this message translates to:
  /// **'Sharing my Maity stats!'**
  String get shareBaseText;

  /// No description provided for @todayMaityHas.
  ///
  /// In en, this message translates to:
  /// **'Today, Maity has:'**
  String get todayMaityHas;

  /// No description provided for @thisMonthMaityHas.
  ///
  /// In en, this message translates to:
  /// **'This month, Maity has:'**
  String get thisMonthMaityHas;

  /// No description provided for @thisYearMaityHas.
  ///
  /// In en, this message translates to:
  /// **'This year, Maity has:'**
  String get thisYearMaityHas;

  /// No description provided for @soFarMaityHas.
  ///
  /// In en, this message translates to:
  /// **'So far, Maity has:'**
  String get soFarMaityHas;

  /// No description provided for @maityHas.
  ///
  /// In en, this message translates to:
  /// **'Maity has:'**
  String get maityHas;

  /// No description provided for @listenedMinutes.
  ///
  /// In en, this message translates to:
  /// **'🎧 Listened for {minutes} minutes'**
  String listenedMinutes(String minutes);

  /// No description provided for @understoodWords.
  ///
  /// In en, this message translates to:
  /// **'🧠 Understood {words} words'**
  String understoodWords(String words);

  /// No description provided for @providedInsights.
  ///
  /// In en, this message translates to:
  /// **'✨ Provided {count} insights'**
  String providedInsights(String count);

  /// No description provided for @rememberedMemories.
  ///
  /// In en, this message translates to:
  /// **'📚 Remembered {count} memories'**
  String rememberedMemories(String count);

  /// No description provided for @nMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count} minutes'**
  String nMinutes(String count);

  /// No description provided for @nWords.
  ///
  /// In en, this message translates to:
  /// **'{count} words'**
  String nWords(String count);

  /// No description provided for @nInsights.
  ///
  /// In en, this message translates to:
  /// **'{count} insights'**
  String nInsights(String count);

  /// No description provided for @nMemories.
  ///
  /// In en, this message translates to:
  /// **'{count} memories'**
  String nMemories(String count);

  /// No description provided for @deletingMessages.
  ///
  /// In en, this message translates to:
  /// **'Deleting your messages from Maity\'s memory...'**
  String get deletingMessages;

  /// No description provided for @noMessagesYet.
  ///
  /// In en, this message translates to:
  /// **'No messages yet!\nWhy don\'t you start a conversation?'**
  String get noMessagesYet;

  /// No description provided for @checkInternetConnection.
  ///
  /// In en, this message translates to:
  /// **'Please check your internet connection and try again'**
  String get checkInternetConnection;

  /// No description provided for @messageCopied.
  ///
  /// In en, this message translates to:
  /// **'Message copied to clipboard.'**
  String get messageCopied;

  /// No description provided for @thankYouFeedback.
  ///
  /// In en, this message translates to:
  /// **'Thank you for your feedback!'**
  String get thankYouFeedback;

  /// No description provided for @cannotReportOwnMessage.
  ///
  /// In en, this message translates to:
  /// **'You cannot report your own messages.'**
  String get cannotReportOwnMessage;

  /// No description provided for @messageReported.
  ///
  /// In en, this message translates to:
  /// **'Message reported successfully.'**
  String get messageReported;

  /// No description provided for @reportMessage.
  ///
  /// In en, this message translates to:
  /// **'Report Message'**
  String get reportMessage;

  /// No description provided for @reportMessageConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to report this message?'**
  String get reportMessageConfirm;

  /// No description provided for @clearChat.
  ///
  /// In en, this message translates to:
  /// **'Clear Chat'**
  String get clearChat;

  /// No description provided for @clearChatQuestion.
  ///
  /// In en, this message translates to:
  /// **'Clear Chat?'**
  String get clearChatQuestion;

  /// No description provided for @clearChatConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to clear the chat? This action cannot be undone.'**
  String get clearChatConfirm;

  /// No description provided for @enableApps.
  ///
  /// In en, this message translates to:
  /// **'Enable Apps'**
  String get enableApps;

  /// No description provided for @selected.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get selected;

  /// No description provided for @syncingMessages.
  ///
  /// In en, this message translates to:
  /// **'Syncing messages with server...'**
  String get syncingMessages;

  /// No description provided for @askAnything.
  ///
  /// In en, this message translates to:
  /// **'Ask anything'**
  String get askAnything;

  /// No description provided for @maxFilesLimit.
  ///
  /// In en, this message translates to:
  /// **'You can only upload 4 files at a time'**
  String get maxFilesLimit;

  /// No description provided for @takePhoto.
  ///
  /// In en, this message translates to:
  /// **'Take Photo'**
  String get takePhoto;

  /// No description provided for @photoLibrary.
  ///
  /// In en, this message translates to:
  /// **'Photo Library'**
  String get photoLibrary;

  /// No description provided for @chooseFile.
  ///
  /// In en, this message translates to:
  /// **'Choose File'**
  String get chooseFile;

  /// No description provided for @dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

  /// No description provided for @waitingForTranscript.
  ///
  /// In en, this message translates to:
  /// **'Waiting for transcript or photos...'**
  String get waitingForTranscript;

  /// No description provided for @noSummaryYet.
  ///
  /// In en, this message translates to:
  /// **'No summary yet'**
  String get noSummaryYet;

  /// No description provided for @finishedConversation.
  ///
  /// In en, this message translates to:
  /// **'Finished Conversation?'**
  String get finishedConversation;

  /// No description provided for @stopRecordingConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to stop recording and summarize the conversation now?'**
  String get stopRecordingConfirm;

  /// No description provided for @hints.
  ///
  /// In en, this message translates to:
  /// **'Hints'**
  String get hints;

  /// No description provided for @dontAskAgain.
  ///
  /// In en, this message translates to:
  /// **'Don\'t ask me again'**
  String get dontAskAgain;

  /// No description provided for @conversationSummarizedAfter.
  ///
  /// In en, this message translates to:
  /// **'Conversation is summarized after {minutes} minute{suffix} of no speech.'**
  String conversationSummarizedAfter(int minutes, String suffix);

  /// No description provided for @conversationEndsManually.
  ///
  /// In en, this message translates to:
  /// **'Conversation will only end manually.'**
  String get conversationEndsManually;

  /// No description provided for @searchConversations.
  ///
  /// In en, this message translates to:
  /// **'Search Conversations'**
  String get searchConversations;

  /// No description provided for @semanticSearchAI.
  ///
  /// In en, this message translates to:
  /// **'Semantic search (AI)'**
  String get semanticSearchAI;

  /// No description provided for @textSearch.
  ///
  /// In en, this message translates to:
  /// **'Text search'**
  String get textSearch;

  /// No description provided for @filterByDate.
  ///
  /// In en, this message translates to:
  /// **'Filter by date'**
  String get filterByDate;

  /// No description provided for @filteredByDate.
  ///
  /// In en, this message translates to:
  /// **'Filtered by {date} - Tap to clear'**
  String filteredByDate(String date);

  /// No description provided for @noInternetConnection.
  ///
  /// In en, this message translates to:
  /// **'No internet connection. Please check your connection.'**
  String get noInternetConnection;

  /// No description provided for @internetRestored.
  ///
  /// In en, this message translates to:
  /// **'Internet connection is restored.'**
  String get internetRestored;

  /// No description provided for @searching.
  ///
  /// In en, this message translates to:
  /// **'Searching'**
  String get searching;

  /// No description provided for @setYourName.
  ///
  /// In en, this message translates to:
  /// **'Set Your Name'**
  String get setYourName;

  /// No description provided for @changeYourName.
  ///
  /// In en, this message translates to:
  /// **'Change Your Name'**
  String get changeYourName;

  /// No description provided for @primaryLanguage.
  ///
  /// In en, this message translates to:
  /// **'Primary Language'**
  String get primaryLanguage;

  /// No description provided for @persona.
  ///
  /// In en, this message translates to:
  /// **'Persona'**
  String get persona;

  /// No description provided for @helpImproveApp.
  ///
  /// In en, this message translates to:
  /// **'Help improve Maity by sharing anonymized analytics data'**
  String get helpImproveApp;

  /// No description provided for @userId.
  ///
  /// In en, this message translates to:
  /// **'User ID'**
  String get userId;

  /// No description provided for @userIdCopied.
  ///
  /// In en, this message translates to:
  /// **'User ID copied to clipboard'**
  String get userIdCopied;

  /// No description provided for @deleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Delete Account'**
  String get deleteAccount;

  /// No description provided for @deleteAccountDesc.
  ///
  /// In en, this message translates to:
  /// **'Delete your account and all data'**
  String get deleteAccountDesc;

  /// No description provided for @copiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get copiedToClipboard;

  /// No description provided for @offline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offline;

  /// No description provided for @batteryLevel.
  ///
  /// In en, this message translates to:
  /// **'Battery Level'**
  String get batteryLevel;

  /// No description provided for @productUpdate.
  ///
  /// In en, this message translates to:
  /// **'Product Update'**
  String get productUpdate;

  /// No description provided for @deviceMustBeConnected.
  ///
  /// In en, this message translates to:
  /// **'Device must be connected'**
  String get deviceMustBeConnected;

  /// No description provided for @sdCardSync.
  ///
  /// In en, this message translates to:
  /// **'SD Card Sync'**
  String get sdCardSync;

  /// No description provided for @importAudioFiles.
  ///
  /// In en, this message translates to:
  /// **'Import audio files from SD Card'**
  String get importAudioFiles;

  /// No description provided for @chargingIssues.
  ///
  /// In en, this message translates to:
  /// **'Issues charging the device?'**
  String get chargingIssues;

  /// No description provided for @tapToSeeGuide.
  ///
  /// In en, this message translates to:
  /// **'Tap to see the guide'**
  String get tapToSeeGuide;

  /// No description provided for @unpair.
  ///
  /// In en, this message translates to:
  /// **'Unpair'**
  String get unpair;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @productName.
  ///
  /// In en, this message translates to:
  /// **'Product Name'**
  String get productName;

  /// No description provided for @modelNumber.
  ///
  /// In en, this message translates to:
  /// **'Model Number'**
  String get modelNumber;

  /// No description provided for @manufacturerName.
  ///
  /// In en, this message translates to:
  /// **'Manufacturer Name'**
  String get manufacturerName;

  /// No description provided for @firmwareVersion.
  ///
  /// In en, this message translates to:
  /// **'Firmware Version'**
  String get firmwareVersion;

  /// No description provided for @deviceIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Device ID'**
  String get deviceIdLabel;

  /// No description provided for @serialNumber.
  ///
  /// In en, this message translates to:
  /// **'Serial Number'**
  String get serialNumber;

  /// No description provided for @unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// No description provided for @generalStats.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get generalStats;

  /// No description provided for @communicationFeedback.
  ///
  /// In en, this message translates to:
  /// **'Communication'**
  String get communicationFeedback;

  /// No description provided for @yourStrengths.
  ///
  /// In en, this message translates to:
  /// **'Your Strengths'**
  String get yourStrengths;

  /// No description provided for @areasToImprove.
  ///
  /// In en, this message translates to:
  /// **'Areas to Improve'**
  String get areasToImprove;

  /// No description provided for @observations.
  ///
  /// In en, this message translates to:
  /// **'Observations'**
  String get observations;

  /// No description provided for @clarity.
  ///
  /// In en, this message translates to:
  /// **'Clarity'**
  String get clarity;

  /// No description provided for @structure.
  ///
  /// In en, this message translates to:
  /// **'Structure'**
  String get structure;

  /// No description provided for @callsToAction.
  ///
  /// In en, this message translates to:
  /// **'Calls to Action'**
  String get callsToAction;

  /// No description provided for @objectionHandling.
  ///
  /// In en, this message translates to:
  /// **'Objection Handling'**
  String get objectionHandling;

  /// No description provided for @basedOnConversations.
  ///
  /// In en, this message translates to:
  /// **'Based on {count} conversations'**
  String basedOnConversations(int count);

  /// No description provided for @noFeedbackYet.
  ///
  /// In en, this message translates to:
  /// **'No feedback yet. Start recording conversations to get insights about your communication style.'**
  String get noFeedbackYet;

  /// No description provided for @deleteConversation.
  ///
  /// In en, this message translates to:
  /// **'Delete Conversation?'**
  String get deleteConversation;

  /// No description provided for @deleteConversationConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this conversation? This action cannot be undone.'**
  String get deleteConversationConfirm;

  /// No description provided for @unableToDeleteConversation.
  ///
  /// In en, this message translates to:
  /// **'Unable to Delete Conversation'**
  String get unableToDeleteConversation;

  /// No description provided for @checkInternetAndTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Please check your internet connection and try again.'**
  String get checkInternetAndTryAgain;

  /// No description provided for @newBadge.
  ///
  /// In en, this message translates to:
  /// **'New 🚀'**
  String get newBadge;

  /// No description provided for @searchingConversations.
  ///
  /// In en, this message translates to:
  /// **'Searching your conversations'**
  String get searchingConversations;

  /// No description provided for @searchResults.
  ///
  /// In en, this message translates to:
  /// **'Search results'**
  String get searchResults;

  /// No description provided for @categoryPersonal.
  ///
  /// In en, this message translates to:
  /// **'Personal'**
  String get categoryPersonal;

  /// No description provided for @categoryEducation.
  ///
  /// In en, this message translates to:
  /// **'Education'**
  String get categoryEducation;

  /// No description provided for @categoryHealth.
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get categoryHealth;

  /// No description provided for @categoryFinance.
  ///
  /// In en, this message translates to:
  /// **'Finance'**
  String get categoryFinance;

  /// No description provided for @categoryLegal.
  ///
  /// In en, this message translates to:
  /// **'Legal'**
  String get categoryLegal;

  /// No description provided for @categoryPhilosophy.
  ///
  /// In en, this message translates to:
  /// **'Philosophy'**
  String get categoryPhilosophy;

  /// No description provided for @categorySpiritual.
  ///
  /// In en, this message translates to:
  /// **'Spiritual'**
  String get categorySpiritual;

  /// No description provided for @categoryScience.
  ///
  /// In en, this message translates to:
  /// **'Science'**
  String get categoryScience;

  /// No description provided for @categoryEntrepreneurship.
  ///
  /// In en, this message translates to:
  /// **'Entrepreneurship'**
  String get categoryEntrepreneurship;

  /// No description provided for @categoryParenting.
  ///
  /// In en, this message translates to:
  /// **'Parenting'**
  String get categoryParenting;

  /// No description provided for @categoryRomantic.
  ///
  /// In en, this message translates to:
  /// **'Romantic'**
  String get categoryRomantic;

  /// No description provided for @categoryTravel.
  ///
  /// In en, this message translates to:
  /// **'Travel'**
  String get categoryTravel;

  /// No description provided for @categoryInspiration.
  ///
  /// In en, this message translates to:
  /// **'Inspiration'**
  String get categoryInspiration;

  /// No description provided for @categoryTechnology.
  ///
  /// In en, this message translates to:
  /// **'Technology'**
  String get categoryTechnology;

  /// No description provided for @categoryBusiness.
  ///
  /// In en, this message translates to:
  /// **'Business'**
  String get categoryBusiness;

  /// No description provided for @categorySocial.
  ///
  /// In en, this message translates to:
  /// **'Social'**
  String get categorySocial;

  /// No description provided for @categoryWork.
  ///
  /// In en, this message translates to:
  /// **'Work'**
  String get categoryWork;

  /// No description provided for @categorySports.
  ///
  /// In en, this message translates to:
  /// **'Sports'**
  String get categorySports;

  /// No description provided for @categoryPolitics.
  ///
  /// In en, this message translates to:
  /// **'Politics'**
  String get categoryPolitics;

  /// No description provided for @categoryLiterature.
  ///
  /// In en, this message translates to:
  /// **'Literature'**
  String get categoryLiterature;

  /// No description provided for @categoryHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get categoryHistory;

  /// No description provided for @categoryArchitecture.
  ///
  /// In en, this message translates to:
  /// **'Architecture'**
  String get categoryArchitecture;

  /// No description provided for @categoryMusic.
  ///
  /// In en, this message translates to:
  /// **'Music'**
  String get categoryMusic;

  /// No description provided for @categoryWeather.
  ///
  /// In en, this message translates to:
  /// **'Weather'**
  String get categoryWeather;

  /// No description provided for @categoryNews.
  ///
  /// In en, this message translates to:
  /// **'News'**
  String get categoryNews;

  /// No description provided for @categoryEntertainment.
  ///
  /// In en, this message translates to:
  /// **'Entertainment'**
  String get categoryEntertainment;

  /// No description provided for @categoryPsychology.
  ///
  /// In en, this message translates to:
  /// **'Psychology'**
  String get categoryPsychology;

  /// No description provided for @categoryDesign.
  ///
  /// In en, this message translates to:
  /// **'Design'**
  String get categoryDesign;

  /// No description provided for @categoryFamily.
  ///
  /// In en, this message translates to:
  /// **'Family'**
  String get categoryFamily;

  /// No description provided for @categoryEconomics.
  ///
  /// In en, this message translates to:
  /// **'Economics'**
  String get categoryEconomics;

  /// No description provided for @categoryEnvironment.
  ///
  /// In en, this message translates to:
  /// **'Environment'**
  String get categoryEnvironment;

  /// No description provided for @categoryOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get categoryOther;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError('AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
