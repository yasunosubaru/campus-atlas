import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Hand-rolled localisation.
///
/// Flutter's `gen_l10n` would work too, but it adds a codegen step and a
/// generated-ARB pipeline to a project that must stay inspectable by anyone who
/// clones it. A plain map keeps translations reviewable in one file and makes
/// missing keys a test failure rather than a runtime surprise.
class AppLocalizations {
  AppLocalizations(this.locale);

  final Locale locale;

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations)!;

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static const List<Locale> supportedLocales = [
    Locale('zh'),
    Locale('en'),
  ];

  /// Exposed so a test can assert the two tables stay in lockstep. Without
  /// this, a key added to one locale and forgotten in the other only surfaces
  /// as a silently untranslated string at runtime.
  static Set<String> get zhKeys => _zh.keys.toSet();
  static Set<String> get enKeys => _en.keys.toSet();

  String _t(String key) {
    final table = switch (locale.languageCode) {
      'en' => _en,
      _ => _zh,
    };
    final value = table[key];
    if (value == null) {
      final fallback = _zh[key];
      assert(
        fallback != null,
        'Missing translation for "$key" in zh and ${locale.languageCode}',
      );
      return fallback ?? key;
    }
    return value;
  }

  /// Test-only raw-key lookup, so a table sweep does not need one typed
  /// accessor per key.
  String debugValueFor(String key) => _t(key);

  // ---------------------------------------------------------------- shell
  String get appTitle => _t('app.title');
  String get navHome => _t('nav.home');
  String get navWeather => _t('nav.weather');
  String get navTimetable => _t('nav.timetable');
  String get navAgenda => _t('nav.agenda');
  String get navMore => _t('nav.more');
  String get navMap => _t('nav.map');
  String get navAi => _t('nav.ai');
  String get navSettings => _t('nav.settings');

  // ---------------------------------------------------------------- common
  String get retry => _t('common.retry');
  String get cancel => _t('common.cancel');
  String get save => _t('common.save');
  String get delete => _t('common.delete');
  String get search => _t('common.search');
  String get close => _t('common.close');
  String get emptyTitle => _t('common.empty.title');
  String get emptyBody => _t('common.empty.body');
  String get loading => _t('common.loading');

  // ---------------------------------------------------------------- errors
  String get errNetwork => _t('error.network');
  String get errTimeout => _t('error.timeout');
  String get errUnauthorized => _t('error.unauthorized');
  String get errChallenge => _t('error.challenge');
  String get errRateLimited => _t('error.rateLimited');
  String get errProtocol => _t('error.protocol');
  String get errServer => _t('error.server');
  String get errInvalidData => _t('error.invalidData');
  String get errValidation => _t('error.validation');
  String get errUnsupported => _t('error.unsupported');
  String get errUnknown => _t('error.unknown');
  String get errorGenericTitle => _t('error.title');

  String errorFor(Object failureKindName) => switch (failureKindName) {
        'network' => errNetwork,
        'timeout' => errTimeout,
        'unauthorized' => errUnauthorized,
        'challengeRequired' => errChallenge,
        'rateLimited' => errRateLimited,
        'protocol' => errProtocol,
        'server' => errServer,
        'invalidData' => errInvalidData,
        'validation' => errValidation,
        'unsupported' => errUnsupported,
        _ => errUnknown,
      };

  // ---------------------------------------------------------------- weather
  String get weatherTitle => _t('weather.title');
  String get weatherUpdated => _t('weather.updated');
  String get weatherFeelsLike => _t('weather.feelsLike');
  String get weatherHumidity => _t('weather.humidity');
  String get weatherWind => _t('weather.wind');
  String get weatherPrecipitation => _t('weather.precipitation');
  String get weatherAqi => _t('weather.aqi');
  String get weatherForecast7 => _t('weather.forecast7');
  String get weatherNoLocation => _t('weather.noLocation');

  // ---------------------------------------------------------------- map
  String get mapTitle => _t('map.title');
  String get mapHint => _t('map.hint');
  String get mapNoResults => _t('map.noResults');
  String get mapCampusTab => _t('map.campusTab');
  String get mapSearchTab => _t('map.searchTab');
  String get mapAll => _t('map.all');
  String get mapCatTeaching => _t('map.cat.teaching');
  String get mapCatLibrary => _t('map.cat.library');
  String get mapCatFood => _t('map.cat.food');
  String get mapCatSport => _t('map.cat.sport');
  String get mapCatDorm => _t('map.cat.dorm');
  String get mapCatMedical => _t('map.cat.medical');
  String get mapSearchCampus => _t('map.searchCampus');
  String get mapAttribution => _t('map.attribution');
  String get mapCoordinates => _t('map.coordinates');
  String get mapOpenOsm => _t('map.openOsm');
  String get mapNoFacility => _t('map.noFacility');
  String get mapPlacesCount => _t('map.placesCount');

  // ------------------------------------------------------------- timetable
  String get ttTitle => _t('timetable.title');
  String get ttToday => _t('timetable.today');
  String get ttEmpty => _t('timetable.empty');
  String get ttAdd => _t('timetable.add');
  String get ttName => _t('timetable.name');
  String get ttTeacher => _t('timetable.teacher');
  String get ttLocation => _t('timetable.location');
  String get ttWeekday => _t('timetable.weekday');
  String get ttStartPeriod => _t('timetable.startPeriod');
  String get ttPeriodCount => _t('timetable.periodCount');
  String get ttWeeks => _t('timetable.weeks');
  String get ttPeriodN => _t('timetable.periodN');
  String get ttValidationName => _t('timetable.validation.name');
  String get ttValidationWeeks => _t('timetable.validation.weeks');
  String get ttWeekView => _t('timetable.weekView');
  String get ttMonthView => _t('timetable.monthView');
  String get ttWeekN => _t('timetable.weekN');
  String get ttProfiles => _t('timetable.profiles');
  String get ttDefaultProfile => _t('timetable.defaultProfile');
  String get ttNewProfile => _t('timetable.newProfile');
  String get ttManageProfiles => _t('timetable.manageProfiles');
  String get ttProfileName => _t('timetable.profileName');
  String get ttDeleteProfile => _t('timetable.deleteProfile');
  String get ttDeleteProfileBody => _t('timetable.deleteProfileBody');
  String get ttEdit => _t('timetable.edit');
  String get ttPeriods => _t('timetable.periods');
  String get ttWeeksLabel => _t('timetable.weeksLabel');
  String get ttWeekdays => _t('timetable.weekdays');
  String get ttNothingOnDay => _t('timetable.nothingOnDay');
  String get ttStartTime => _t('timetable.startTime');
  String get ttStartTimeHint => _t('timetable.startTimeHint');
  String get ttTimeInvalid => _t('timetable.timeInvalid');
  String get ttPrevious => _t('timetable.previous');
  String get ttNext => _t('timetable.next');
  String get ttImport => _t('timetable.import');
  String get ttImportTitle => _t('timetable.importTitle');
  String get ttImportChannelJwgl => _t('timetable.importChannelJwgl');
  String get ttImportChannelJwglNote => _t('timetable.importChannelJwglNote');
  String get ttImportChannelYjs => _t('timetable.importChannelYjs');
  String get ttImportChannelYjsNote => _t('timetable.importChannelYjsNote');
  String get ttImportNeedSession => _t('timetable.importNeedSession');
  String get ttImportYear => _t('timetable.importYear');
  String get ttImportTerm => _t('timetable.importTerm');
  String get ttImportRun => _t('timetable.importRun');
  String get ttImportPreview => _t('timetable.importPreview');
  String get ttImportSkipped => _t('timetable.importSkipped');
  String get ttImportApply => _t('timetable.importApply');
  String get ttImportApplyBody => _t('timetable.importApplyBody');
  String get ttImportDone => _t('timetable.importDone');
  String get ttImportEmpty => _t('timetable.importEmpty');
  String get ttImportBrowser => _t('timetable.importBrowser');
  String get ttImportBrowserTitle => _t('timetable.importBrowserTitle');
  String get ttImportBrowserRead => _t('timetable.importBrowserRead');
  String get ttImportBrowserNoRows => _t('timetable.importBrowserNoRows');
  String get ttImportUnverified => _t('timetable.importUnverified');

  // ---------------------------------------------------------------- agenda
  String get agendaTitle => _t('agenda.title');
  String get agendaHint => _t('agenda.hint');
  String get agendaAdd => _t('agenda.add');
  String get agendaPlaceholder => _t('agenda.placeholder');
  String get agendaCompletedCount => _t('agenda.completedCount');
  String get agendaDue => _t('agenda.due');
  String get agendaNoDue => _t('agenda.noDue');
  String get agendaRepeatNone => _t('agenda.repeatNone');
  String get agendaRepeatDaily => _t('agenda.repeatDaily');
  String get agendaRepeatWeekly => _t('agenda.repeatWeekly');
  String get agendaRepeatMonthly => _t('agenda.repeatMonthly');
  String get agendaRepeatUntil => _t('agenda.repeatUntil');
  String get agendaNeedDate => _t('agenda.needDate');

  // ------------------------------------------------------------------ home
  String get homeNextClass => _t('home.nextClass');
  String get homeNoUpcoming => _t('home.noUpcoming');
  String get homeInMinutes => _t('home.inMinutes');
  String get homeRunning => _t('home.running');
  String get homeStartsAt => _t('home.startsAt');
  String get homeNoAgendaToday => _t('home.noAgendaToday');
  String get homeReminderBody => _t('home.reminderBody');

  // ---------------------------------------------------------------- ai chat
  String get aiTitle => _t('ai.title');
  String get aiPlaceholder => _t('ai.placeholder');
  String get aiNotConfigured => _t('ai.notConfigured');
  String get aiNotConfiguredBody => _t('ai.notConfiguredBody');
  String get aiConfigure => _t('ai.configure');
  String get aiSend => _t('ai.send');
  String get aiNewChat => _t('ai.newChat');
  String get aiCheckFailed => _t('ai.checkFailed');

  // -------------------------------------------------------------- courses
  String get coursesTitle => _t('courses.title');
  String get coursesRatings => _t('courses.ratings');
  String get coursesMaster => _t('courses.master');
  String get coursesSearchHint => _t('courses.searchHint');
  String get coursesNoResults => _t('courses.noResults');
  String get coursesNoReviews => _t('courses.noReviews');
  String get coursesReviewCount => _t('courses.reviewCount');
  String get coursesRating => _t('courses.rating');
  String get coursesDifficulty => _t('courses.difficulty');
  String get coursesTeachingQuality => _t('courses.teachingQuality');
  String get coursesWorkload => _t('courses.workload');
  String get coursesInterest => _t('courses.interest');
  String get coursesRatingDifficult => _t('courses.ratingDifficult');
  String get coursesCredits => _t('courses.credits');
  String get coursesTeacher => _t('courses.teacher');
  String get coursesRoom => _t('courses.room');
  String get coursesPeriod => _t('courses.period');
  String get coursesWeeks => _t('courses.weeks');
  String get coursesTerm => _t('courses.term');
  String get coursesPickTerm => _t('courses.pickTerm');
  String get coursesLoadingTerms => _t('courses.loadingTerms');
  String get coursesStoreEmpty => _t('courses.storeEmpty');
  String get coursesFreeOnly => _t('courses.freeOnly');
  String get coursesBadgeFree => _t('courses.badgeFree');
  String get coursesBadgeClash => _t('courses.badgeClash');
  String get coursesNoConflictFree => _t('courses.noConflictFree');

  // -------------------------------------------------------------- grades
  String get gradesTitle => _t('grades.title');
  String get gradesSignInNeeded => _t('grades.signInNeeded');
  String get gradesSignInCta => _t('grades.signInCta');
  String get gradesFetch => _t('grades.fetch');
  String get gradesEmpty => _t('grades.empty');
  String get gradesTruncated => _t('grades.truncated');
  String get gradesYear => _t('grades.year');
  String get gradesTerm => _t('grades.term');
  String get gradesCredits => _t('grades.credits');
  String get gradesCreditTotal => _t('grades.creditTotal');
  String get gradesWeightedMean => _t('grades.weightedMean');
  String get gradesTermCount => _t('grades.termCount');

  // -------------------------------------------------------------- sign-in
  String get signInTitle => _t('signIn.title');
  String get signInCancel => _t('signIn.cancel');
  String get signInStatusCas => _t('signIn.statusCas');

  /// Shown once the WebView leaves CAS for a property.
  ///
  /// Deliberately does **not** say "signed in": leaving CAS only proves the
  /// redirect happened. Whether a grant was actually issued is not known until
  /// the cookie jar is read, which happens a moment later — so claiming success
  /// here produces the contradictory pair "signed in" / "sign-in incomplete".
  String get signInStatusReturned => _t('signIn.statusReturned');
  String get signInStatusFailed => _t('signIn.statusFailed');
  String get signInStatusUnsupported => _t('signIn.statusUnsupported');
  String get signInChallengeNeeded => _t('signIn.challengeNeeded');
  String get signInChallengeHint => _t('signIn.challengeHint');
  String get signInChallengeNeutral => _t('signIn.challengeNeutral');
  String get signInServiceMissing => _t('signIn.serviceMissing');
  String get signInNoGrant => _t('signIn.noGrant');
  String get signInNoSession => _t('signIn.noSession');
  String get signInRefresh => _t('signIn.refresh');

  // The fields of the native sign-in form. These replaced a WebView, so the
  // person now types into the app rather than into a rendered page.
  String get signInIdentifier => _t('signIn.identifier');
  String get signInPassword => _t('signIn.password');
  String get signInCaptcha => _t('signIn.captcha');
  String get signInSubmit => _t('signIn.submit');
  String get signInSubmitting => _t('signIn.submitting');
  String get signInNeedIdentifier => _t('signIn.needIdentifier');
  String get signInNeedPassword => _t('signIn.needPassword');
  String get signInNetwork => _t('signIn.network');
  String get signInSlider => _t('signIn.slider');
  String get signInCaptchaNeeded => _t('signIn.captchaNeeded');
  String get signInDiagnostics => _t('signIn.diagnostics');

  /// What happens to the password. Stated in the UI rather than only in a
  /// comment, because the person typing it is entitled to know.
  String get signInPrivacy => _t('signIn.privacy');

  // ------------------------------------------------------------- 账户登录
  String get accountTitle => _t('account.title');
  String get accountIntro => _t('account.intro');
  String get accountSignedOut => _t('account.signedOut');
  String get accountSignedIn => _t('account.signedIn');
  String get accountSignedInShort => _t('account.signedInShort');
  String get accountAcquiredAt => _t('account.acquiredAt');
  String get accountRemaining => _t('account.remaining');
  String get accountExpired => _t('account.expired');
  String get accountCapabilities => _t('account.capabilities');
  String get accountBrowserSignIn => _t('account.browserSignIn');
  String get accountBrowserTitle => _t('account.browserTitle');
  String get accountBrowserHint => _t('account.browserHint');
  String get accountChallengeNote => _t('account.challengeNote');
  String get accountHamNote => _t('account.hamNote');
  String get accountSignOut => _t('account.signOut');
  String get accountSignOutBody => _t('account.signOutBody');
  String get accountSignedOutDone => _t('account.signedOutDone');
  String get accountPasswordFallback => _t('account.passwordFallback');
  String get accountPasswordFallbackNote => _t('account.passwordFallbackNote');
  String get accountLoginSuccess => _t('account.loginSuccess');

  // ------------------------------------------------- 给分与评价 (Ham-backed)
  String get hamTitle => _t('ham.title');
  String get hamIntro => _t('ham.intro');
  String get hamApiKey => _t('ham.apiKey');
  String get hamApiKeyHint => _t('ham.apiKeyHint');
  String get hamCourseName => _t('ham.courseName');
  String get hamInstructor => _t('ham.instructor');
  String get hamByCourse => _t('ham.byCourse');
  String get hamByInstructor => _t('ham.byInstructor');
  String get hamSearch => _t('ham.search');
  String get hamSearching => _t('ham.searching');
  String get hamQueryNeeded => _t('ham.queryNeeded');
  String get hamKeyNeeded => _t('ham.keyNeeded');
  String get hamNoData => _t('ham.noData');
  String get hamAverage => _t('ham.average');
  String get hamSamples => _t('ham.samples');
  String get hamUnknownCourse => _t('ham.unknownCourse');
  String get hamQuickAuth => _t('ham.quickAuth');
  String get hamAuthorizing => _t('ham.authorizing');
  String get hamQuickAuthHint => _t('ham.quickAuthHint');
  String get hamTokenReady => _t('ham.tokenReady');
  String get hamTokenDays => _t('ham.tokenDays');
  String get hamClearAuth => _t('ham.clearAuth');
  String get hamOpenTokenPanel => _t('ham.openTokenPanel');
  String get hamTokenPanelHint => _t('ham.tokenPanelHint');
  String get hamOpenTokenPanelFailed => _t('ham.openTokenPanelFailed');
  String get hamReopenAuthorize => _t('ham.reopenAuthorize');
  String get hamWaitingHint => _t('ham.waitingHint');

  // ------------------------------------------------------- 我的 Ham（只读）
  String get hamCenter => _t('ham.center');
  String get hamCenterIntro => _t('ham.centerIntro');
  String get hamRank => _t('ham.rank');
  String get hamWant => _t('ham.want');
  String get hamMyComments => _t('ham.myComments');
  String get hamNoRank => _t('ham.noRank');
  String get hamNoWant => _t('ham.noWant');
  String get hamNoMyComments => _t('ham.noMyComments');
  String get hamTotalCount => _t('ham.totalCount');
  String get hamComments => _t('ham.comments');
  String get hamNoComments => _t('ham.noComments');
  String get hamSemesterStats => _t('ham.semesterStats');
  String get hamYear => _t('ham.year');
  String get hamSemester => _t('ham.semester');
  String get hamQuery => _t('ham.query');
  String get hamMedian => _t('ham.median');
  String get hamMissingCourseId => _t('ham.missingCourseId');
  String get hamNeedAuthTitle => _t('ham.needAuthTitle');
  String get hamNeedAuthBody => _t('ham.needAuthBody');
  String get hamNeedAuthShort => _t('ham.needAuthShort');
  String get hamSectionFailed => _t('ham.sectionFailed');
  String get hamLikes => _t('ham.likes');

  // -------------------------------------------------------------- grades query
  String get gqTitle => _t('gq.title');
  String get gqSignInNote => _t('gq.signInNote');
  String get gqSignInPrivacy => _t('gq.signInPrivacy');
  String get gqIdentifier => _t('gq.identifier');
  String get gqPassword => _t('gq.password');
  String get gqSubmit => _t('gq.submit');
  String get gqSubmitting => _t('gq.submitting');
  String get gqSignInFailed => _t('gq.signInFailed');
  String get gqInvalidInput => _t('gq.invalidInput');
  String get gqProtocolError => _t('gq.protocolError');
  String get gqFailed => _t('gq.failed');
  String get gqSearchHint => _t('gq.searchHint');
  String get gqNoResults => _t('gq.noResults');
  String get gqNoTeachers => _t('gq.noTeachers');
  String get gqNoOfferings => _t('gq.noOfferings');
  String get gqPickTeacher => _t('gq.pickTeacher');
  String get gqReviewCount => _t('gq.reviewCount');
  String get gqOverall => _t('gq.overall');
  String get gqTeachingQuality => _t('gq.teachingQuality');
  String get gqGradingScore => _t('gq.gradingScore');
  String get gqWorkload => _t('gq.workload');
  String get gqDifficulty => _t('gq.difficulty');
  String get gqDistribution => _t('gq.distribution');
  String get gqNoDistribution => _t('gq.noDistribution');
  String get gqReviews => _t('gq.reviews');
  String get gqNoReviews => _t('gq.noReviews');
  String get gqBackToList => _t('gq.backToList');
  String get gqSignOut => _t('gq.signOut');
  String get gqDiagnostics => _t('gq.diagnostics');
  String get gqRawResponse => _t('gq.rawResponse');
  String get gqCopy => _t('gq.copy');
  String get gqCopied => _t('gq.copied');
  String get gqNoRaw => _t('gq.noRaw');
  String get gqRawNote => _t('gq.rawNote');
  String get gqClear => _t('gq.clear');

  // ------------------------------------------------------------- 正方教务
  String get jwTitle => _t('jw.title');
  String get jwSignInNeeded => _t('jw.signInNeeded');
  String get jwSignInCta => _t('jw.signInCta');
  String get jwExplain => _t('jw.explain');
  String get jwFetchMenu => _t('jw.fetchMenu');
  String get jwMenuTitle => _t('jw.menuTitle');
  String get jwEmptyMenu => _t('jw.emptyMenu');
  String get jwNoEvaluation => _t('jw.noEvaluation');
  String get jwFoundEvaluation => _t('jw.foundEvaluation');
  String get jwOpened => _t('jw.opened');
  String get jwDiagnosticsNote => _t('jw.diagnosticsNote');

  /// Heading for the recorded sign-in hops in the diagnostics panel. The hop log
  /// is what says whether a session was actually established on this host.
  String get jwHandshake => _t('jw.handshake');
  String get jwGradesInBrowser => _t('jw.gradesInBrowser');
  String get jwTileSubtitle => _t('jw.tileSubtitle');
  String get jwGoToGrades => _t('jw.goToGrades');
  String get jwReadGrades => _t('jw.readGrades');
  String get jwNoGrades => _t('jw.noGrades');

  /// Takes the browser's cookies as the app's own session.
  String get jwAdoptSession => _t('jw.adoptSession');
  String get jwAdoptOk => _t('jw.adoptOk');
  String get jwAdoptFailed => _t('jw.adoptFailed');

  // ----------------------------------------------------------- 成绩档案与统计
  String get archiveTitle => _t('archive.title');
  String get archiveIntro => _t('archive.intro');
  String get archiveEmpty => _t('archive.empty');
  String get archiveEmptyBody => _t('archive.emptyBody');
  String get archiveStandard => _t('archive.standard');
  String get archiveStdWhu => _t('archive.stdWhu');
  String get archiveStdScale5 => _t('archive.stdScale5');
  String get archiveStdWeighted => _t('archive.stdWeighted');
  String get archiveRequiredOnly => _t('archive.requiredOnly');
  String get archiveGpa => _t('archive.gpa');
  String get archiveAvg => _t('archive.avg');
  String get archiveChipAvg => _t('archive.chipAvg');
  String get archiveChipCredits => _t('archive.chipCredits');
  String get archiveChipCounted => _t('archive.chipCounted');
  String get archiveChipPassed => _t('archive.chipPassed');
  String get archiveExcluded => _t('archive.excluded');
  String get archiveFailedCount => _t('archive.failedCount');
  String get archiveTrend => _t('archive.trend');
  String get archiveTrendNeedTwo => _t('archive.trendNeedTwo');
  String get archiveCourses => _t('archive.courses');
  String get archiveCreditsUnit => _t('archive.creditsUnit');
  String get archiveClear => _t('archive.clear');
  String get archiveClearBody => _t('archive.clearBody');
  String get archiveCleared => _t('archive.cleared');

  /// Sheet line shown after an automatic import: how many rows landed.
  String get archiveArchived => _t('archive.archived');

  /// Sheet line when a re-read produced nothing new.
  String get archiveUnchanged => _t('archive.unchanged');

  /// Sheet line when the read worked but keeping it did not.
  String get archiveFailed => _t('archive.failed');

  /// The archive entry point, on the academic-system screen.
  String get archiveOpen => _t('archive.open');

  /// Opens the statistics from the sheet that shows a freshly read grid.
  String get archiveViewStats => _t('archive.viewStats');

  // --------------------------------------------------------- 成绩档案 · 手工
  String get archiveAdd => _t('archive.add');
  String get archiveAddTitle => _t('archive.addTitle');
  String get archiveEditNote => _t('archive.editNote');
  String get archiveFieldYear => _t('archive.fieldYear');
  String get archiveFieldSemester => _t('archive.fieldSemester');
  String get archiveFieldName => _t('archive.fieldName');
  String get archiveFieldCode => _t('archive.fieldCode');
  String get archiveFieldTeacher => _t('archive.fieldTeacher');
  String get archiveFieldKind => _t('archive.fieldKind');
  String get archiveFieldCredits => _t('archive.fieldCredits');
  String get archiveFieldScore => _t('archive.fieldScore');
  String get archiveScoreHint => _t('archive.scoreHint');
  String get archiveNameRequired => _t('archive.nameRequired');
  String get archiveAdded => _t('archive.added');
  String get archiveUpdated => _t('archive.updated');
  String get archiveRemoved => _t('archive.removed');
  String get archiveManualTag => _t('archive.manualTag');

  // ------------------------------------------------------------- 学业状态
  String get statusTitle => _t('status.title');
  String get statusIntro => _t('status.intro');
  String get statusGpa => _t('status.gpa');
  String get statusWeighted => _t('status.weighted');
  String get statusPassed => _t('status.passed');
  String get statusFailed => _t('status.failed');
  String get statusProgress => _t('status.progress');
  String get statusProgressLine => _t('status.progressLine');
  String get statusSetTarget => _t('status.setTarget');
  String get statusNoTarget => _t('status.noTarget');
  String get statusTargetHint => _t('status.targetHint');
  String get statusTargetInvalid => _t('status.targetInvalid');
  String get statusSaved => _t('status.saved');
  String get statusCreditsByKind => _t('status.creditsByKind');
  String get statusKindRequired => _t('status.kind.required');
  String get statusKindElective => _t('status.kind.elective');
  String get statusKindOther => _t('status.kind.other');
  String get statusTerms => _t('status.terms');
  String get statusTermLine => _t('status.termLine');
  String get statusFailedTitle => _t('status.failedTitle');
  String get statusNoFailed => _t('status.noFailed');
  String get statusArchive => _t('status.archive');
  String get statusEmpty => _t('status.empty');
  String get statusEmptyBody => _t('status.emptyBody');

  // -------------------------------------------------------------- teaching eval
  String get evalTitle => _t('eval.title');
  String get evalPlanTitle => _t('eval.planTitle');
  String get evalVerified => _t('eval.verified');
  String get evalAssumed => _t('eval.assumed');
  String get evalRemaining => _t('eval.remaining');
  String get evalFetch => _t('eval.fetch');
  String get evalSignInFirst => _t('eval.signInFirst');
  String get evalEvidenceNote => _t('eval.evidenceNote');
  String get evalResponseTitle => _t('eval.responseTitle');
  String get evalSignInPage => _t('eval.signinPage');
  String get evalNoTable => _t('eval.noTable');
  String get evalLoaded => _t('eval.loaded');
  String get evalEntryTitle => _t('eval.entryTitle');
  String get evalEntryNote => _t('eval.entryNote');
  String get evalUserId => _t('eval.userId');
  String get evalResolve => _t('eval.resolve');
  String get evalResolved => _t('eval.resolved');
  String get evalOpenBrowser => _t('eval.openBrowser');
  String get evalNeedUserId => _t('eval.needUserId');
  String get evalNoSubmit => _t('eval.noSubmit');
  String get evalHamNote => _t('eval.hamNote');
  String get evalDrafts => _t('eval.drafts');

  // ------------------------------------------------------------- 评价草稿
  String get draftsTitle => _t('drafts.title');
  String get draftsIntro => _t('drafts.intro');
  String get draftsNew => _t('drafts.new');
  String get draftsEdit => _t('drafts.edit');
  String get draftsCourse => _t('drafts.course');
  String get draftsTeacher => _t('drafts.teacher');
  String get draftsRating => _t('drafts.rating');
  String get draftsText => _t('drafts.text');
  String get draftsSave => _t('drafts.save');
  String get draftsCopy => _t('drafts.copy');
  String get draftsCopied => _t('drafts.copied');
  String get draftsEmpty => _t('drafts.empty');
  String get draftsEmptyBody => _t('drafts.emptyBody');
  String get draftsNeedCourse => _t('drafts.needCourse');

  // -------------------------------------------------------------- settings
  String get settingsTitle => _t('settings.title');
  String get settingsAppearance => _t('settings.appearance');
  String get settingsThemeSystem => _t('settings.theme.system');
  String get settingsThemeLight => _t('settings.theme.light');
  String get settingsThemeDark => _t('settings.theme.dark');
  String get settingsLanguage => _t('settings.language');
  String get settingsLocation => _t('settings.location');
  String get settingsLocationName => _t('settings.locationName');
  String get settingsLatitude => _t('settings.latitude');
  String get settingsLongitude => _t('settings.longitude');
  String get settingsAi => _t('settings.ai');
  String get settingsAiBase => _t('settings.ai.base');
  String get settingsAiKey => _t('settings.ai.key');
  String get settingsAiModel => _t('settings.ai.model');
  String get settingsAiCheck => _t('settings.ai.check');
  String get settingsAiCheckOk => _t('settings.ai.checkOk');
  String get settingsAbout => _t('settings.about');
  String get settingsAboutBody => _t('settings.aboutBody');
  String get settingsDataSources => _t('settings.dataSources');
  String get settingsDataSourcesBody => _t('settings.dataSourcesBody');
  String get settingsFirstWeek => _t('settings.firstWeek');
  String get settingsFirstWeekBody => _t('settings.firstWeekBody');
  String get settingsTimetable => _t('settings.timetable');

  static const Map<String, String> _zh = {
    'app.title': 'Campus Atlas',
    'nav.home': '首页',
    'nav.weather': '天气',
    'nav.timetable': '课表',
    'nav.agenda': '日程',
    'nav.more': '更多',
    'nav.map': '地图',
    'nav.ai': '对话',
    'nav.settings': '设置',
    'common.retry': '重试',
    'common.cancel': '取消',
    'common.save': '保存',
    'common.delete': '删除',
    'common.search': '搜索',
    'common.close': '关闭',
    'common.empty.title': '暂无内容',
    'common.empty.body': '下拉或点击重试即可重新加载。',
    'common.loading': '加载中…',
    'error.title': '出了点问题',
    'error.network': '网络不可用，请检查连接',
    'error.timeout': '请求超时，请稍后重试',
    'error.unauthorized': '登录已过期，请重新登录',
    'error.challenge': '需要完成人机验证',
    'error.rateLimited': '请求过于频繁，请稍候',
    'error.protocol': '响应格式异常，可能是门户页拦截',
    'error.server': '服务端错误',
    'error.invalidData': '无法解析响应数据',
    'error.validation': '输入或请求不合法',
    'error.unsupported': '此构建暂不支持该功能',
    'error.unknown': '发生未知错误',
    'weather.title': '天气',
    'weather.updated': '更新于',
    'weather.feelsLike': '体感',
    'weather.humidity': '湿度',
    'weather.wind': '风速',
    'weather.precipitation': '降水',
    'weather.aqi': '空气质量指数',
    'weather.forecast7': '七日预报',
    'weather.noLocation': '请先在设置中配置位置',
    'map.title': '校园地图',
    'map.hint': '搜索地点、教学楼或食堂',
    'map.noResults': '没有找到相关结果',
    'map.campusTab': '校园地图',
    'map.searchTab': '地点搜索',
    'map.all': '全部',
    'map.cat.teaching': '教学楼',
    'map.cat.library': '图书馆',
    'map.cat.food': '食堂与商店',
    'map.cat.sport': '运动',
    'map.cat.dorm': '宿舍',
    'map.cat.medical': '医疗',
    'map.searchCampus': '搜索校园设施',
    'map.attribution': '© OpenStreetMap 贡献者（ODbL）',
    'map.coordinates': '坐标',
    'map.openOsm': '在 OpenStreetMap 打开',
    'map.noFacility': '没有匹配的设施',
    'map.placesCount': '%d 个设施',
    'timetable.title': '课表',
    'timetable.today': '今天',
    'timetable.empty': '本周还没有课程，点右下角添加',
    'timetable.add': '添加课程',
    'timetable.name': '课程名称',
    'timetable.teacher': '授课老师',
    'timetable.location': '上课地点',
    'timetable.weekday': '星期',
    'timetable.startPeriod': '起始节次',
    'timetable.periodCount': '连上节数',
    'timetable.weeks': '周次（如 1-16 表示每周，3,5,7 表示单周）',
    'timetable.periodN': '第 %d 节',
    'timetable.validation.name': '请填写课程名称',
    'timetable.validation.weeks': '周次格式不正确',
    'timetable.weekView': '周视图',
    'timetable.monthView': '月视图',
    'timetable.weekN': '第 %d 周',
    'timetable.profiles': '多课表',
    'timetable.defaultProfile': '我的课表',
    'timetable.newProfile': '新建课表',
    'timetable.manageProfiles': '管理课表',
    'timetable.profileName': '课表名称',
    'timetable.deleteProfile': '删除这张课表',
    'timetable.deleteProfileBody': '将删除这张课表里的全部课程，只影响本机。',
    'timetable.edit': '编辑',
    'timetable.periods': '节次',
    'timetable.weeksLabel': '周次',
    'timetable.weekdays': '一,二,三,四,五,六,日',
    'timetable.nothingOnDay': '这天没有课或日程',
    'timetable.startTime': '上课时间（如 08:00-09:40）',
    'timetable.startTimeHint': '填了时间才能收到上课提醒',
    'timetable.timeInvalid': '时间格式应为 08:00-09:40',
    'timetable.previous': '上一页',
    'timetable.next': '下一页',
    'timetable.import': '从教务导入',
    'timetable.importTitle': '导入课表',
    'timetable.importChannelJwgl': '本科教务（N2151）',
    'timetable.importChannelJwglNote': '读取所选学期的个人课表，导入后覆盖当前课表。'
        '教务现在要求先在课表页完成滑块验证，可用下面的「在浏览器中完成验证并读取」。',
    'timetable.importChannelYjs': '研究生系统',
    'timetable.importChannelYjsNote': '研究生系统的课表接口尚未取得（需要一次研究生账号的会话），暂不可用。',
    'timetable.importNeedSession': '先完成一次账户登录（设置 → 账户登录），才能读取教务课表。',
    'timetable.importYear': '学年（如 2026）',
    'timetable.importTerm': '学期',
    'timetable.importRun': '读取课表',
    'timetable.importPreview': '读到 %d 门课',
    'timetable.importSkipped': '跳过 %d 行（无法解析）',
    'timetable.importApply': '覆盖当前课表',
    'timetable.importApplyBody': '将用读到的 %d 门课替换「%s」中的全部课程。',
    'timetable.importDone': '已导入 %d 门课',
    'timetable.importEmpty':
        '没有读到课程。教务系统现在要求先在课表页点“查询”并完成滑块验证；请在浏览器中打开课表页，完成后再读取。',
    'timetable.importBrowser': '在浏览器中完成验证并读取',
    'timetable.importBrowserTitle': '课表查询',
    'timetable.importBrowserRead': '读取当前课表',
    'timetable.importBrowserNoRows':
        '没有读到课表。请先在页面点“查询”并完成滑块，等课表出现后（必要时切到“列表”视图），再点右上角读取。',
    'timetable.importUnverified': '解析规则来自正方教务的课表页，并已在本校实况核对（2026-10-20，20 门课）；'
        '导入前仍请核对下面的课程。',
    'agenda.title': '日程',
    'agenda.hint': '添加待办事项',
    'agenda.add': '添加',
    'agenda.placeholder': '要做什么？',
    'agenda.completedCount': '已完成 %d 项',
    'agenda.due': '截止',
    'agenda.noDue': '无日期',
    'agenda.repeatNone': '不重复',
    'agenda.repeatDaily': '每天',
    'agenda.repeatWeekly': '每周',
    'agenda.repeatMonthly': '每月',
    'agenda.repeatUntil': '重复至',
    'agenda.needDate': '重复的任务需要先选日期',
    'home.nextClass': '下一节课',
    'home.noUpcoming': '近期没有课',
    'home.inMinutes': '%d 分钟后开始',
    'home.running': '正在进行',
    'home.startsAt': '开始',
    'home.noAgendaToday': '今天没有日程',
    'home.reminderBody': '%d 分钟后有课：%s',
    'ai.title': '对话',
    'ai.placeholder': '输入消息…',
    'ai.notConfigured': '尚未配置对话服务',
    'ai.notConfiguredBody': '填入一个兼容 OpenAI 接口的地址即可开始使用。',
    'ai.configure': '去配置',
    'ai.send': '发送',
    'ai.newChat': '新对话',
    'ai.checkFailed': '连接测试失败',
    'courses.title': '课程',
    'courses.ratings': '课程评价',
    'courses.master': '总课表',
    'courses.searchHint': '搜索课程名或老师',
    'courses.noResults': '没有找到相关课程',
    'courses.noReviews': '暂无评价',
    'courses.reviewCount': '%d 条评价',
    'courses.rating': '总体评分',
    'courses.difficulty': '难度',
    'courses.teachingQuality': '教学质量',
    'courses.workload': '工作量',
    'courses.interest': '课程兴趣',
    'courses.ratingDifficult': '给分难度',
    'courses.credits': '学分',
    'courses.teacher': '教师',
    'courses.room': '地点',
    'courses.period': '节次',
    'courses.weeks': '周次',
    'courses.term': '学期',
    'courses.pickTerm': '选择学期',
    'courses.loadingTerms': '加载学期中…',
    'courses.storeEmpty': '该学期尚未发布课表数据',
    'courses.freeOnly': '只看不冲突的课',
    'courses.badgeFree': '可蹭课',
    'courses.badgeClash': '与我的课表冲突',
    'courses.noConflictFree': '没有与课表不冲突的课',
    'grades.title': '成绩',
    'grades.signInNeeded': '成绩查询需要登录统一身份认证',
    'grades.signInCta': '去登录',
    'grades.fetch': '查询',
    'grades.empty': '该学期没有成绩记录',
    'grades.truncated': '服务端声明 %s 条，本页仅解析到 %d 条，可能未分页',
    'grades.year': '学年',
    'grades.term': '学期',
    'grades.credits': '学分',
    'grades.creditTotal': '学分合计',
    'grades.weightedMean': '学分加权均分',
    'grades.termCount': '%d 门',
    'gq.title': '给分与评价',
    'gq.signInNote': '用自己的学校账号登录后，查询老师的给分与课程评价',
    'gq.signInPrivacy': '密码只用于本次登录，不写入磁盘，退出即丢弃',
    'gq.identifier': '学号或邮箱',
    'gq.password': '密码',
    'gq.submit': '登录',
    'gq.submitting': '登录中…',
    'gq.signInFailed': '登录失败，请检查账号密码',
    'gq.invalidInput': '输入不合法',
    'gq.protocolError': '服务端返回异常',
    'gq.failed': '查询失败',
    'gq.searchHint': '课程、老师或代码',
    'gq.noResults': '没有找到相关课程',
    'gq.noTeachers': '暂无授课教师数据',
    'gq.noOfferings': '该课程在服务端暂无给分数据（接口返回的 offerings 为空）。换一门课试试。',
    'gq.pickTeacher': '选择一位老师查看给分数据',
    'gq.reviewCount': '%d 条',
    'gq.overall': '总体评分',
    'gq.teachingQuality': '教学质量',
    'gq.generous': '给分',
    'gq.workload': '课程负担',
    'gq.difficulty': '课程难度',
    'gq.distribution': '给分分布',
    'gq.noDistribution': '该老师暂无给分分布',
    'gq.reviews': '评价',
    'gq.noReviews': '暂无评价',
    'gq.backToList': '返回课程列表',
    'gq.signOut': '退出登录',
    'gq.diagnostics': '诊断',
    'gq.rawResponse': '原始响应',
    'gq.copy': '复制',
    'gq.copied': '已复制',
    'gq.noRaw': '还没有拿到响应，先查询一次',
    'gq.rawNote': '接口的真实结构尚未确认。这里显示服务端原样返回的内容，不含登录凭据 —— 复制出来可以直接用来把字段定死。',
    'gq.clear': '清空',
    'jw.title': '正方教务',
    'jw.signInNeeded': '需要先完成一次账户登录（设置 → 账户登录），才能读取教务数据',
    'jw.signInCta': '账户登录',
    'jw.explain':
        '教务系统对每个路径返回同一个页面，所以接口无法靠探测发现。学生的功能清单是运行时按账号下发的 —— 先读菜单，才能知道你的账号里有哪些入口。',
    'jw.fetchMenu': '读取学生菜单',
    'jw.menuTitle': '学生功能菜单',
    'jw.emptyMenu': '菜单为空',
    'jw.noEvaluation': '这份菜单里没有评教/给分入口',
    'jw.foundEvaluation': '找到 %d 个评教/给分入口',
    'jw.opened': '已打开',
    'jw.diagnosticsNote': '菜单的真实结构尚未确认，这里显示服务端原样返回的内容，不含登录凭据。',
    'jw.handshake': '登录过程（票据已隐去，Cookie 只显示名字与作用域）',
    'jw.gradesInBrowser': '在应用内浏览器查成绩',
    'jw.tileSubtitle': '成绩、课表、评教都在这里；登录一次即可',
    'jw.goToGrades': '直达成绩查询（已登录时用）',
    'jw.readGrades': '读取成绩',
    'jw.noGrades': '页面上没有读到成绩表格。请先在页面里点「查询」，表格出来后我再读。',
    'jw.adoptSession': '设为应用会话（一次登录，其余功能通用）',
    'jw.adoptOk': '已接管这次登录，菜单、学业情况、评教入口现在都用它。',
    'jw.adoptFailed': '接管失败：',
    'archive.title': '成绩档案',
    'archive.intro': '从教务页面读过的成绩会保存在本机，统计和趋势不需要再联网。',
    'archive.empty': '还没有归档成绩',
    'archive.emptyBody': '在「正方教务」里打开成绩查询、读取一次表格，成绩就会出现在这里。',
    'archive.standard': 'GPA 算法',
    'archive.stdWhu': '武大 4.0',
    'archive.stdScale5': '五分制',
    'archive.stdWeighted': '百分制',
    'archive.requiredOnly': '只计必修课',
    'archive.gpa': '平均学分绩点',
    'archive.avg': '加权平均分',
    'archive.chipAvg': '均分 %s',
    'archive.chipCredits': '学分 %s',
    'archive.chipCounted': '计入 %d 门',
    'archive.chipPassed': '通过 %s 学分',
    'archive.excluded': '另有 %d 门未计入（等级制、退课、零学分或不在范围内）',
    'archive.failedCount': '其中 %d 门不及格',
    'archive.trend': '各学期趋势',
    'archive.trendNeedTwo': '归档两个学期以上，这里会显示各学期趋势。',
    'archive.courses': '课程明细',
    'archive.creditsUnit': '学分',
    'archive.clear': '清空本地成绩',
    'archive.clearBody': '只删除本机归档，学校系统里的成绩不受影响。',
    'archive.cleared': '已清空本地成绩',
    'archive.archived': '已归档 %d 条（新增 %n · 更新 %u），统计见「成绩档案」。',
    'archive.unchanged': '归档无变化（本机已有 %d 条）',
    'archive.failed': '读取成功，但归档失败：%s',
    'archive.open': '成绩档案与统计',
    'archive.viewStats': '查看成绩统计',
    'archive.add': '手动添加',
    'archive.addTitle': '手动添加一条成绩',
    'archive.editNote': '手工添加的成绩只保存在本机，和教务导入的成绩一起参与统计。',
    'archive.fieldYear': '学年',
    'archive.fieldSemester': '学期',
    'archive.fieldName': '课程名称',
    'archive.fieldCode': '课程代码（可空）',
    'archive.fieldTeacher': '任课教师（可空）',
    'archive.fieldKind': '课程性质',
    'archive.fieldCredits': '学分',
    'archive.fieldScore': '成绩',
    'archive.scoreHint': '如 90，或「优秀」「合格」',
    'archive.nameRequired': '课程名称不能为空',
    'archive.added': '已添加 %s',
    'archive.updated': '已更新 %s',
    'archive.removed': '已删除 %s',
    'archive.manualTag': '手工',
    'status.title': '学业状态',
    'status.intro': '由本地成绩档案计算，不需要联网；毕业学分要求可以自己设定。',
    'status.gpa': '平均学分绩点',
    'status.weighted': '加权平均分',
    'status.passed': '已通过学分',
    'status.failed': '不及格',
    'status.progress': '毕业学分进度',
    'status.progressLine': '已完成 %s%（%p / %t 学分）',
    'status.setTarget': '设置毕业学分要求',
    'status.noTarget': '还没有设置毕业学分要求，设置后这里显示进度条。',
    'status.targetHint': '毕业学分要求（如 160）',
    'status.targetInvalid': '请输入大于 0 的数字',
    'status.saved': '已保存',
    'status.creditsByKind': '学分构成',
    'status.kind.required': '必修',
    'status.kind.elective': '选修',
    'status.kind.other': '其他',
    'status.terms': '各学期',
    'status.termLine': '%s 学分 · GPA %g',
    'status.failedTitle': '不及格课程',
    'status.noFailed': '没有不及格课程',
    'status.archive': '查看成绩档案',
    'status.empty': '还没有成绩',
    'status.emptyBody': '先读取一次成绩表格，或手动添加成绩。',
    'eval.title': '评教',
    'eval.planTitle': '会话复用路径',
    'eval.verified': '已验证',
    'eval.assumed': '待验证',
    'eval.remaining': '会话剩余 %s 分钟',
    'eval.fetch': '抓取响应',
    'eval.signInFirst': '先完成一次账户登录（设置 → 账户登录），才能复用会话',
    'eval.evidenceNote': '以下为预期路径，本项目尚未实际跑通，与真实行为不符时以实际为准',
    'eval.responseTitle': '响应',
    'eval.signinPage': '拿到的是登录页，不是数据',
    'eval.noTable': '响应可读，但没有可表格化的内容',
    'eval.loaded': '已解析：%s',
    'eval.entryTitle': '评教入口（POST /loginSSO）',
    'eval.entryNote':
        '落地页自己的 JS 就是 POST /loginSSO {userId} → forwardURL。这里照做，只在本机解析出入口。',
    'eval.userId': '学号（仅本次使用，不保存）',
    'eval.resolve': '解析评教入口',
    'eval.resolved': '已解析到入口',
    'eval.openBrowser': '在内置浏览器打开',
    'eval.needUserId': '先填学号',
    'eval.noSubmit': '评教表单仍要在页面里填写并提交；本应用不代填（表单契约尚未取得）。',
    'eval.hamNote': 'Ham 的「给分 / 写评价」写入接口尚未取得，本应用目前只读取给分分布。',
    'eval.drafts': '评价草稿',
    'drafts.title': '评价草稿',
    'drafts.intro': '评教页面有时限，先在草稿里写好，再复制到页面里提交。',
    'drafts.new': '新建草稿',
    'drafts.edit': '编辑草稿',
    'drafts.course': '课程名称',
    'drafts.teacher': '任课教师（可空）',
    'drafts.rating': '评分',
    'drafts.text': '评价内容',
    'drafts.save': '保存草稿',
    'drafts.copy': '复制',
    'drafts.copied': '已复制，粘贴到评教页面即可',
    'drafts.empty': '还没有草稿',
    'drafts.emptyBody': '写一份评价草稿，评教时直接粘贴。',
    'drafts.needCourse': '请填写课程名称',
    'signIn.title': '登录',
    'signIn.cancel': '取消',
    'signIn.statusCas': '正在前往统一身份认证',
    'signIn.statusReturned': '已返回学校系统，正在读取登录凭据',
    'signIn.statusFailed': '登录未完成',
    'signIn.statusUnsupported': '当前平台不支持内置登录',
    'signIn.challengeNeeded': '需要验证',
    'signIn.challengeHint': '按页面要求完成验证（滑块 / 短信 / 安全令牌 / 扫码等），应用不会代为处理',
    'signIn.challengeNeutral': '当前未要求验证',
    'signIn.serviceMissing': '该项目尚未建立认证入口',
    'signIn.noGrant': '未取得统一认证票据，无法访问其他服务',
    'signIn.noSession': '尚未登录',
    'signIn.refresh': '重新登录',
    'signIn.identifier': '学号或工号',
    'signIn.password': '密码',
    'signIn.captcha': '验证码',
    'signIn.submit': '登录',
    'signIn.submitting': '正在登录…',
    'signIn.needIdentifier': '请输入学号或工号',
    'signIn.needPassword': '请输入密码',
    'signIn.network': '网络不通，请确认能访问学校网络',
    'signIn.slider': '该账号当前要求滑块验证，本应用无法呈现。请先在浏览器里登录一次，再回来重试',
    'signIn.captchaNeeded': '请输入图形验证码后重试',
    'signIn.diagnostics': '诊断',
    'signIn.privacy': '密码只用于这一次登录，不会写入磁盘；登录后只保留 Cookie',
    'account.title': '账户登录',
    'account.intro': '一次登录，成绩查询、课表导入、评教入口共用同一个会话；登录状态只在本次运行内保留。',
    'account.signedOut': '未登录',
    'account.signedIn': '已登录',
    'account.signedInShort': '已登录 · 剩余 %d 分钟',
    'account.acquiredAt': '登录时间 %s',
    'account.remaining': '剩余 %d 分钟',
    'account.expired': '会话已过期，请重新登录',
    'account.capabilities': '已解锁：成绩查询 · 课表导入 · 评教入口',
    'account.browserSignIn': '在应用内浏览器登录',
    'account.browserTitle': '账户登录',
    'account.browserHint': '登录成功后，点浏览器右上角的钥匙图标「设为应用会话」，再返回这里。',
    'account.challengeNote':
        '学校对非可信浏览器会要求二次认证（短信、安全令牌、扫码，也可能出现滑块）。请在页面里完成，应用不代填。',
    'account.hamNote': 'Ham 给分使用单独的 Ham 授权，不在此列。',
    'account.signOut': '退出登录',
    'account.signOutBody': '退出后需要重新登录才能使用教务功能。',
    'account.signedOutDone': '已退出登录',
    'account.passwordFallback': '账号密码登录（备用）',
    'account.passwordFallbackNote': '仅在账号未被要求二次认证时可用；遇到二次认证会停在验证页，请改用浏览器登录。',
    'account.loginSuccess': '已登录，成绩、课表、评教现在都可使用',
    'ham.title': '给分与评价',
    'ham.intro':
        '课程给分分布来自 Ham 的用户共建数据，需要你自己的 Ham API Key。它不是学校公开的数据，可能还没有任何记录。',
    'ham.apiKey': 'Ham API Key',
    'ham.apiKeyHint': '在 ham.nowcent.cn/console/tokens 生成。只保存在内存，不写入磁盘。',
    'ham.courseName': '课程名',
    'ham.instructor': '授课人',
    'ham.byCourse': '按课程',
    'ham.byInstructor': '按授课人',
    'ham.search': '查询',
    'ham.searching': '查询中…',
    'ham.queryNeeded': '请输入课程名或授课人',
    'ham.keyNeeded': '请先填入 Ham API Key',
    'ham.noData': '还没有人贡献过这门课的成绩',
    'ham.average': '平均分',
    'ham.samples': '%d 份成绩',
    'ham.unknownCourse': '（未命名课程）',
    'ham.quickAuth': '快捷授权',
    'ham.authorizing': '等待浏览器授权…',
    'ham.quickAuthHint':
        '点一下会在系统浏览器打开 Ham 授权页；登录并同意后，token 自动填入上面的框。浏览器里已经登录 Ham 的话约十秒。',
    'ham.tokenReady': '已获取授权，%d 天内有效',
    'ham.tokenDays': '剩余 %d 天',
    'ham.clearAuth': '清除授权',
    'ham.center': '我的 Ham',
    'ham.centerIntro': '只读取你自己的 Ham 数据；提交成绩与写评价不在这里（Ham 未开放这两个接口）。',
    'ham.rank': '成绩排名',
    'ham.want': '想上列表',
    'ham.myComments': '我的评价',
    'ham.noRank': '暂无排名数据',
    'ham.noWant': '想上列表为空',
    'ham.noMyComments': '还没有写过评价',
    'ham.totalCount': '共 %d 条',
    'ham.comments': '课程评论',
    'ham.noComments': '这门课还没有评论',
    'ham.semesterStats': '学期统计',
    'ham.year': '学年',
    'ham.semester': '学期',
    'ham.query': '查询',
    'ham.median': '中位数',
    'ham.missingCourseId': '缺少课程标识，无法读取评论与学期统计。',
    'ham.needAuthTitle': '需要先授权 Ham',
    'ham.needAuthBody': '回到上一页点「快捷授权」，授权后再进来。',
    'ham.needAuthShort': '需要先授权 Ham',
    'ham.sectionFailed': '读取失败：%s',
    'ham.likes': '%d 人赞',
    'ham.openTokenPanel': '打开 Token 面板',
    'ham.tokenPanelHint':
        '在 ham.nowcent.cn/console/tokens 里创建，创建后只显示一次，复制过来贴上。',
    'ham.openTokenPanelFailed': '无法打开浏览器',
    'ham.reopenAuthorize': '重新打开授权页',
    'ham.waitingHint': '浏览器里点完同意会自动回到应用；窗口被关掉了就点左边这个。',
    'settings.title': '设置',
    'settings.appearance': '外观',
    'settings.theme.system': '跟随系统',
    'settings.theme.light': '浅色',
    'settings.theme.dark': '深色',
    'settings.language': '语言',
    'settings.location': '位置',
    'settings.locationName': '位置名称',
    'settings.latitude': '纬度',
    'settings.longitude': '经度',
    'settings.ai': '对话服务',
    'settings.ai.base': '接口地址',
    'settings.ai.key': 'API Key',
    'settings.ai.model': '模型',
    'settings.ai.check': '测试连接',
    'settings.ai.checkOk': '连接正常',
    'settings.about': '关于',
    'settings.aboutBody': 'Campus Atlas 是独立的第三方开源实现，与任何官方校园应用无关联、'
        '未获其背书，也不复制其任何素材。',
    'settings.dataSources': '数据来源',
    'settings.dataSourcesBody':
        '天气与地理编码来自 Open-Meteo；地点搜索来自 OpenStreetMap Nominatim。',
    'settings.timetable': '课表',
    'settings.firstWeek': '第一周起始日',
    'settings.firstWeekBody': '用于计算课表周次，例如第 3 周。',
  };

  static const Map<String, String> _en = {
    'app.title': 'Campus Atlas',
    'nav.home': 'Home',
    'nav.weather': 'Weather',
    'nav.timetable': 'Timetable',
    'nav.agenda': 'Agenda',
    'nav.more': 'More',
    'nav.map': 'Map',
    'nav.ai': 'Chat',
    'nav.settings': 'Settings',
    'common.retry': 'Retry',
    'common.cancel': 'Cancel',
    'common.save': 'Save',
    'common.delete': 'Delete',
    'common.search': 'Search',
    'common.close': 'Close',
    'common.empty.title': 'Nothing here',
    'common.empty.body': 'Tap retry to load again.',
    'common.loading': 'Loading…',
    'error.title': 'Something went wrong',
    'error.network': 'No network connection',
    'error.timeout': 'The request timed out',
    'error.unauthorized': 'Your session expired — sign in again',
    'error.challenge': 'A verification step is required',
    'error.rateLimited': 'Too many requests — try again shortly',
    'error.protocol': 'Unexpected response (portal page?)',
    'error.server': 'Server error',
    'error.invalidData': 'Could not read the response',
    'error.validation': 'Invalid request or input',
    'error.unsupported': 'Not available in this build',
    'error.unknown': 'An unknown error occurred',
    'weather.title': 'Weather',
    'weather.updated': 'Updated',
    'weather.feelsLike': 'Feels like',
    'weather.humidity': 'Humidity',
    'weather.wind': 'Wind',
    'weather.precipitation': 'Precipitation',
    'weather.aqi': 'Air quality index',
    'weather.forecast7': '7-day forecast',
    'weather.noLocation': 'Set a location in Settings first',
    'map.title': 'Campus map',
    'map.hint': 'Search for a building, canteen or landmark',
    'map.noResults': 'No results found',
    'map.campusTab': 'Campus map',
    'map.searchTab': 'Place search',
    'map.all': 'All',
    'map.cat.teaching': 'Teaching',
    'map.cat.library': 'Library',
    'map.cat.food': 'Food & shops',
    'map.cat.sport': 'Sports',
    'map.cat.dorm': 'Dorms',
    'map.cat.medical': 'Medical',
    'map.searchCampus': 'Search campus places',
    'map.attribution': '© OpenStreetMap contributors (ODbL)',
    'map.coordinates': 'Coordinates',
    'map.openOsm': 'Open in OpenStreetMap',
    'map.noFacility': 'No matching place',
    'map.placesCount': '%d places',
    'timetable.title': 'Timetable',
    'timetable.today': 'Today',
    'timetable.empty': 'No classes this week — tap + to add one',
    'timetable.add': 'Add course',
    'timetable.name': 'Course name',
    'timetable.teacher': 'Instructor',
    'timetable.location': 'Room',
    'timetable.weekday': 'Weekday',
    'timetable.startPeriod': 'Starts at period',
    'timetable.periodCount': 'Number of periods',
    'timetable.weeks': 'Weeks (e.g. 1-16 for all, 3,5,7 for odd)',
    'timetable.periodN': 'Period %d',
    'timetable.validation.name': 'Course name is required',
    'timetable.validation.weeks': 'Week specification is not valid',
    'timetable.weekView': 'Week',
    'timetable.monthView': 'Month',
    'timetable.weekN': 'Week %d',
    'timetable.profiles': 'Timetables',
    'timetable.defaultProfile': 'My timetable',
    'timetable.newProfile': 'New timetable',
    'timetable.manageProfiles': 'Manage timetables',
    'timetable.profileName': 'Timetable name',
    'timetable.deleteProfile': 'Delete this timetable',
    'timetable.deleteProfileBody':
        'Removes every course in it, on this machine only.',
    'timetable.edit': 'Edit',
    'timetable.periods': 'Periods',
    'timetable.weeksLabel': 'Weeks',
    'timetable.weekdays': 'Mon,Tue,Wed,Thu,Fri,Sat,Sun',
    'timetable.nothingOnDay': 'Nothing on this day',
    'timetable.startTime': 'Class time (e.g. 08:00-09:40)',
    'timetable.startTimeHint': 'A time is what makes class reminders possible',
    'timetable.timeInvalid': 'Time must look like 08:00-09:40',
    'timetable.previous': 'Previous',
    'timetable.next': 'Next',
    'timetable.import': 'Import from the academic system',
    'timetable.importTitle': 'Import timetable',
    'timetable.importChannelJwgl': 'Undergraduate academic system (N2151)',
    'timetable.importChannelJwglNote':
        'Reads your own timetable for the chosen term; applying replaces the '
            'current timetable. The academic system now asks for a slider check '
            'on the timetable page — use “Open the timetable page and read it” '
            'below.',
    'timetable.importChannelYjs': 'Graduate system',
    'timetable.importChannelYjsNote':
        "The graduate system's timetable endpoint is not established yet (it "
            'needs a graduate account session), so this channel is unavailable.',
    'timetable.importNeedSession':
        'Complete an account sign-in first (Settings → Account sign-in) to read '
            'the academic timetable.',
    'timetable.importYear': 'Academic year (e.g. 2026)',
    'timetable.importTerm': 'Term',
    'timetable.importRun': 'Read timetable',
    'timetable.importPreview': '%d courses found',
    'timetable.importSkipped': '%d rows skipped (could not be parsed)',
    'timetable.importApply': 'Replace this timetable',
    'timetable.importApplyBody':
        'Replaces every course in “%s” with the %d imported ones.',
    'timetable.importDone': 'Imported %d courses',
    'timetable.importEmpty':
        'No courses found. The academic system now requires the timetable '
            'page’s 查询 button and slider check; open the timetable page in '
            'the browser, complete it, then read again.',
    'timetable.importBrowser': 'Open the timetable page and read it',
    'timetable.importBrowserTitle': 'Timetable query',
    'timetable.importBrowserRead': 'Read this timetable',
    'timetable.importBrowserNoRows':
        'No timetable was read. In the page, tap 查询 and complete the slider; '
            'when the timetable appears (switch to 列表 if needed), tap read.',
    'timetable.importUnverified':
        "The parser follows the N2151 timetable page and was checked against "
            'this deployment on 2026-10-20 (20 courses); still compare the '
            'courses before applying.',
    'agenda.title': 'Agenda',
    'agenda.hint': 'Add a task',
    'agenda.add': 'Add',
    'agenda.placeholder': 'What needs doing?',
    'agenda.completedCount': '%d completed',
    'agenda.due': 'Due',
    'agenda.noDue': 'No date',
    'agenda.repeatNone': 'Once',
    'agenda.repeatDaily': 'Daily',
    'agenda.repeatWeekly': 'Weekly',
    'agenda.repeatMonthly': 'Monthly',
    'agenda.repeatUntil': 'Until',
    'agenda.needDate': 'A repeating task needs a date first',
    'home.nextClass': 'Next class',
    'home.noUpcoming': 'No upcoming class',
    'home.inMinutes': 'starts in %d min',
    'home.running': 'in progress',
    'home.startsAt': 'starts',
    'home.noAgendaToday': 'Nothing on the agenda today',
    'home.reminderBody': '%d min until %s',
    'ai.title': 'Chat',
    'ai.placeholder': 'Type a message…',
    'ai.notConfigured': 'No chat service configured',
    'ai.notConfiguredBody':
        'Point this at any OpenAI-compatible endpoint to get started.',
    'ai.configure': 'Configure',
    'ai.send': 'Send',
    'ai.newChat': 'New chat',
    'ai.checkFailed': 'Connection test failed',
    'courses.title': 'Courses',
    'courses.ratings': 'Reviews',
    'courses.master': 'Master timetable',
    'courses.searchHint': 'Search a course or a teacher',
    'courses.noResults': 'No matching course',
    'courses.noReviews': 'No reviews yet',
    'courses.reviewCount': '%d reviews',
    'courses.rating': 'Overall',
    'courses.difficulty': 'Difficulty',
    'courses.teachingQuality': 'Teaching',
    'courses.workload': 'Workload',
    'courses.interest': 'Interest',
    'courses.ratingDifficult': 'Grading',
    'courses.credits': 'Credits',
    'courses.teacher': 'Teacher',
    'courses.room': 'Room',
    'courses.period': 'Period',
    'courses.weeks': 'Weeks',
    'courses.term': 'Term',
    'courses.pickTerm': 'Select term',
    'courses.loadingTerms': 'Loading terms…',
    'courses.storeEmpty': 'No timetable published for this term',
    'courses.freeOnly': 'Conflict-free only',
    'courses.badgeFree': 'Open to audit',
    'courses.badgeClash': 'Clashes with my timetable',
    'courses.noConflictFree': 'No clash-free courses here',
    'grades.title': 'Grades',
    'grades.signInNeeded': 'Grades require signing in to central auth',
    'grades.signInCta': 'Sign in',
    'grades.fetch': 'Fetch',
    'grades.empty': 'No grade records for this term',
    'grades.truncated':
        'The server declared %s rows but only %d were parsed; this may be one page',
    'grades.year': 'Year',
    'grades.term': 'Term',
    'grades.credits': 'Credits',
    'grades.creditTotal': 'Total credits',
    'grades.weightedMean': 'Credit-weighted mean',
    'grades.termCount': '%d courses',
    'gq.title': 'Grades & reviews',
    'gq.signInNote':
        'Sign in with your university account to query teacher grading and course reviews',
    'gq.signInPrivacy':
        'Your password is used for this sign-in only, is never written to disk, and is dropped on sign-out',
    'gq.identifier': 'Student number or email',
    'gq.password': 'Password',
    'gq.submit': 'Sign in',
    'gq.submitting': 'Signing in…',
    'gq.signInFailed': 'Sign-in failed — check the account and password',
    'gq.invalidInput': 'Invalid input',
    'gq.protocolError': 'Unexpected server response',
    'gq.failed': 'Query failed',
    'gq.searchHint': 'Course, teacher or code',
    'gq.noResults': 'No matching course',
    'gq.noTeachers': 'No teacher data for this course',
    'gq.noOfferings':
        'The service has no grade data for this course (it returned an empty offerings list). Try another course.',
    'gq.pickTeacher': 'Pick a teacher to view their grade data',
    'gq.reviewCount': '%d',
    'gq.overall': 'Overall',
    'gq.teachingQuality': 'Teaching',
    'gq.generous': 'Grading',
    'gq.workload': 'Workload',
    'gq.difficulty': 'Difficulty',
    'gq.distribution': 'Grade distribution',
    'gq.noDistribution': 'No grade distribution for this teacher yet',
    'gq.reviews': 'Reviews',
    'gq.noReviews': 'No reviews yet',
    'gq.backToList': 'Back to courses',
    'gq.signOut': 'Sign out',
    'gq.diagnostics': 'Diagnostics',
    'gq.rawResponse': 'Raw response',
    'gq.copy': 'Copy',
    'gq.copied': 'Copied',
    'gq.noRaw': 'Nothing captured yet — run a query first',
    'gq.rawNote':
        "This endpoint's real shape is not confirmed. What the server sent back is shown verbatim and contains no sign-in credential, so it can be copied out to pin the field names down.",
    'gq.clear': 'Clear',
    'jw.title': 'Academic system',
    'jw.signInNeeded':
        'Complete an account sign-in first (Settings → Account sign-in); the '
            'academic system needs it',
    'jw.signInCta': 'Account sign-in',
    'jw.explain':
        'Every path in the academic system returns the same page, so its endpoints cannot be discovered by probing. The list of student functions is delivered at runtime and depends on your account — reading the menu is how we find out which entries yours has.',
    'jw.fetchMenu': 'Read student menu',
    'jw.menuTitle': 'Student functions',
    'jw.emptyMenu': 'The menu is empty',
    'jw.noEvaluation': 'No evaluation or grading entry in this menu',
    'jw.foundEvaluation': '%d evaluation/grading entries found',
    'jw.opened': 'Opened',
    'jw.diagnosticsNote':
        "The menu's real shape is unconfirmed. What the server sent back is shown verbatim and contains no sign-in credential.",
    'jw.handshake':
        'How the session was obtained (tickets redacted; cookies by name and scope only)',
    'jw.gradesInBrowser': 'Open grades in the in-app browser',
    'jw.tileSubtitle':
        'Grades, timetable and evaluations live here; one sign-in',
    'jw.goToGrades': 'Go straight to the grade query (once signed in)',
    'jw.readGrades': 'Read grades',
    'jw.noGrades':
        'No grade table found on the page. Run the query first; once the table '
            'appears, read it here.',
    'jw.adoptSession': 'Use this sign-in for the whole app',
    'jw.adoptOk':
        'This sign-in now backs the menu, the credit progress and the '
            'evaluation entry.',
    'jw.adoptFailed': 'Could not adopt the sign-in: ',
    'archive.title': 'Grade archive',
    'archive.intro':
        'Grades read from the academic system are kept on this machine; '
            'statistics and trends need no network.',
    'archive.empty': 'Nothing archived yet',
    'archive.emptyBody':
        'Open the grade query in the academic system and read the table once — '
            'the grades then show up here.',
    'archive.standard': 'GPA algorithm',
    'archive.stdWhu': 'WHU 4.0',
    'archive.stdScale5': '5-point',
    'archive.stdWeighted': '100-point',
    'archive.requiredOnly': 'Compulsory only',
    'archive.gpa': 'GPA',
    'archive.avg': 'Weighted average',
    'archive.chipAvg': 'Avg %s',
    'archive.chipCredits': 'Credits %s',
    'archive.chipCounted': '%d counted',
    'archive.chipPassed': '%s credits passed',
    'archive.excluded':
        '%d more not counted (level grades, dropped, zero credits, or out of '
            'scope)',
    'archive.failedCount': '%d of them below 60',
    'archive.trend': 'Term trend',
    'archive.trendNeedTwo':
        'Archive two terms or more and the per-term trend appears here.',
    'archive.courses': 'Courses',
    'archive.creditsUnit': 'credits',
    'archive.clear': 'Clear local archive',
    'archive.clearBody':
        'Removes this machine\u2019s copy only; the school\u2019s records are '
            'untouched.',
    'archive.cleared': 'Local archive cleared',
    'archive.archived':
        '%d rows archived (new %n \u00b7 updated %u) \u2014 see the grade '
            'archive for statistics.',
    'archive.unchanged': 'Archive unchanged (%d rows already stored)',
    'archive.failed': 'Read succeeded, but archiving failed: %s',
    'archive.open': 'Grade archive & stats',
    'archive.viewStats': 'Open grade stats',
    'archive.add': 'Add manually',
    'archive.addTitle': 'Add a grade manually',
    'archive.editNote':
        'Manually added grades are kept on this machine and counted together '
            'with the imported ones.',
    'archive.fieldYear': 'Academic year',
    'archive.fieldSemester': 'Term',
    'archive.fieldName': 'Course name',
    'archive.fieldCode': 'Course code (optional)',
    'archive.fieldTeacher': 'Teacher (optional)',
    'archive.fieldKind': 'Course nature',
    'archive.fieldCredits': 'Credits',
    'archive.fieldScore': 'Score',
    'archive.scoreHint': 'e.g. 90, or a level such as Pass',
    'archive.nameRequired': 'A course name is required',
    'archive.added': 'Added %s',
    'archive.updated': 'Updated %s',
    'archive.removed': 'Removed %s',
    'archive.manualTag': 'manual',
    'status.title': 'Academic standing',
    'status.intro':
        'Computed from the local grade archive, no network needed; you can set '
            'the credit requirement yourself.',
    'status.gpa': 'GPA',
    'status.weighted': 'Weighted average',
    'status.passed': 'Credits earned',
    'status.failed': 'Failed',
    'status.progress': 'Degree progress',
    'status.progressLine': '%s% complete (%p / %t credits)',
    'status.setTarget': 'Set credit requirement',
    'status.noTarget':
        'No credit requirement set — set one and progress shows up here.',
    'status.targetHint': 'Credits required for graduation (e.g. 160)',
    'status.targetInvalid': 'Enter a number greater than 0',
    'status.saved': 'Saved',
    'status.creditsByKind': 'Credits by course nature',
    'status.kind.required': 'Compulsory',
    'status.kind.elective': 'Elective',
    'status.kind.other': 'Other',
    'status.terms': 'Terms',
    'status.termLine': '%s credits · GPA %g',
    'status.failedTitle': 'Failed courses',
    'status.noFailed': 'No failed courses',
    'status.archive': 'Open the grade archive',
    'status.empty': 'No grades yet',
    'status.emptyBody': 'Read the grade table once, or add a grade manually.',
    'eval.title': 'Teaching evaluation',
    'eval.planTitle': 'Session-reuse path',
    'eval.verified': 'Verified',
    'eval.assumed': 'Not yet verified',
    'eval.remaining': 'Session expires in %s minutes',
    'eval.fetch': 'Fetch response',
    'eval.signInFirst':
        'Complete an account sign-in first (Settings → Account sign-in) before '
            'a session can be reused',
    'eval.evidenceNote':
        'This is the expected path; this project has not run it, so treat a mismatch as the model being wrong, not the code',
    'eval.responseTitle': 'Response',
    'eval.signinPage': 'Got the sign-in page, not data',
    'eval.noTable': 'Readable response, but nothing shaped like a table',
    'eval.loaded': 'Parsed: %s',
    'eval.entryTitle': 'Evaluation entry (POST /loginSSO)',
    'eval.entryNote':
        "The landing page's own JS is `POST /loginSSO {userId}` → `forwardURL`. "
            'This does the same, resolving the entry on this machine.',
    'eval.userId': 'Student ID (used once, never stored)',
    'eval.resolve': 'Resolve the evaluation entry',
    'eval.resolved': 'Entry resolved',
    'eval.openBrowser': 'Open in the in-app browser',
    'eval.needUserId': 'Enter the student ID first',
    'eval.noSubmit':
        'The evaluation form still has to be filled in and submitted in the '
            'page; the app does not submit it (the form contract has not been '
            'captured).',
    'eval.hamNote':
        "Ham's write endpoints for 给分 / reviews are not available yet; the app "
            'currently reads grade distributions only.',
    'eval.drafts': 'Evaluation drafts',
    'drafts.title': 'Evaluation drafts',
    'drafts.intro':
        'The evaluation page is timed — write the text here first, then copy it '
            'into the page.',
    'drafts.new': 'New draft',
    'drafts.edit': 'Edit draft',
    'drafts.course': 'Course name',
    'drafts.teacher': 'Instructor (optional)',
    'drafts.rating': 'Rating',
    'drafts.text': 'Review text',
    'drafts.save': 'Save draft',
    'drafts.copy': 'Copy',
    'drafts.copied': 'Copied — paste it into the evaluation page',
    'drafts.empty': 'No drafts yet',
    'drafts.emptyBody': 'Write a draft now and paste it during the evaluation.',
    'drafts.needCourse': 'A course name is required',
    'signIn.title': 'Sign in',
    'signIn.cancel': 'Cancel',
    'signIn.statusCas': 'Going to central sign-in',
    'signIn.statusReturned':
        'Back on the university system — reading the session',
    'signIn.statusFailed': 'Sign-in did not complete',
    'signIn.statusUnsupported':
        'Built-in sign-in is not available on this platform',
    'signIn.challengeNeeded': 'Verification needed',
    'signIn.challengeHint':
        'Complete whatever verification the page asks for (slider, SMS, OTP, '
            'QR, …); the app does not answer it for you',
    'signIn.challengeNeutral': 'No verification required right now',
    'signIn.serviceMissing': 'No sign-in entry established for this service',
    'signIn.noGrant':
        'No central ticket was issued, so other services are unreachable',
    'signIn.noSession': 'Not signed in',
    'signIn.refresh': 'Sign in again',
    'signIn.identifier': 'Student or staff number',
    'signIn.password': 'Password',
    'signIn.captcha': 'Verification code',
    'signIn.submit': 'Sign in',
    'signIn.submitting': 'Signing in…',
    'signIn.needIdentifier': 'Enter your student or staff number',
    'signIn.needPassword': 'Enter your password',
    'signIn.network':
        'The network is unreachable; check that the campus network can be reached',
    'signIn.slider':
        'This account is being asked for a slider verification, which this app '
            'cannot present. Sign in once in a browser, then come back',
    'signIn.captchaNeeded': 'Enter the image verification code and try again',
    'signIn.diagnostics': 'Diagnostics',
    'signIn.privacy':
        'The password is used for this one sign-in and never written to disk; '
            'only the resulting cookies are kept',
    'account.title': 'Account sign-in',
    'account.intro':
        'One sign-in gives the grade query, timetable import and evaluation '
            'entry the same session; it lasts for this run only.',
    'account.signedOut': 'Not signed in',
    'account.signedIn': 'Signed in',
    'account.signedInShort': 'Signed in · %d min left',
    'account.acquiredAt': 'Signed in %s',
    'account.remaining': '%d min left',
    'account.expired': 'The session has expired — sign in again',
    'account.capabilities':
        'Unlocked: grade query · timetable import · evaluation entry',
    'account.browserSignIn': 'Sign in in the app browser',
    'account.browserTitle': 'Account sign-in',
    'account.browserHint':
        'After signing in, tap the key icon at the top right of the browser '
            '(“Use this sign-in for the whole app”), then come back here.',
    'account.challengeNote':
        'The university asks for a second factor on untrusted browsers (SMS, '
            'OTP, QR, and sometimes a slider). Complete it in the page; the app '
            'does not answer it for you.',
    'account.hamNote':
        'Ham grading uses a separate Ham authorisation and is not part of this.',
    'account.signOut': 'Sign out',
    'account.signOutBody':
        'After signing out you will need to sign in again to use the academic '
            'features.',
    'account.signedOutDone': 'Signed out',
    'account.passwordFallback': 'Sign in with password (fallback)',
    'account.passwordFallbackNote':
        'Only works when no second factor is required; if one is, it stops on '
            'the verification page — use the browser sign-in instead.',
    'account.loginSuccess':
        'Signed in — grades, timetable and evaluation are now available',
    'ham.title': 'Grades & reviews',
    'ham.intro':
        'Course grade distributions come from Ham\'s community-contributed data '
            'and need your own Ham API key. They are not published by the '
            'university, and there may be nothing recorded yet.',
    'ham.apiKey': 'Ham API key',
    'ham.apiKeyHint':
        'Create one at ham.nowcent.cn/console/tokens. Kept in memory only; never '
            'written to disk.',
    'ham.courseName': 'Course',
    'ham.instructor': 'Instructor',
    'ham.byCourse': 'By course',
    'ham.byInstructor': 'By instructor',
    'ham.search': 'Search',
    'ham.searching': 'Searching…',
    'ham.queryNeeded': 'Enter a course or an instructor',
    'ham.keyNeeded': 'Enter your Ham API key first',
    'ham.noData': 'Nobody has contributed a mark for this course yet',
    'ham.average': 'Average',
    'ham.samples': '%d marks',
    'ham.unknownCourse': '(unnamed course)',
    'ham.quickAuth': 'Quick authorise',
    'ham.authorizing': 'Waiting for the browser…',
    'ham.quickAuthHint':
        'Opens Ham\'s authorise page in your default browser. Sign in and '
            'approve, and the token is filled in above by itself — about ten '
            'seconds if you are already signed in to Ham.',
    'ham.tokenReady': 'Authorised · valid for %d days',
    'ham.tokenDays': '%d days left',
    'ham.clearAuth': 'Remove authorisation',
    'ham.openTokenPanel': 'Open token panel',
    'ham.tokenPanelHint':
        'Create one at ham.nowcent.cn/console/tokens — it is shown once, then '
            'copy it here.',
    'ham.openTokenPanelFailed': 'Could not open the browser',
    'ham.reopenAuthorize': 'Reopen the authorise page',
    'ham.waitingHint':
        'Approving in the browser returns here by itself; if the window was '
            'closed, use the button on the left.',
    'ham.center': 'My Ham',
    'ham.centerIntro':
        'Reads your own Ham data only; submitting grades and writing comments '
            'are not here (Ham does not expose those two APIs).',
    'ham.rank': 'Score rank',
    'ham.want': 'Want list',
    'ham.myComments': 'My comments',
    'ham.noRank': 'No rank data yet',
    'ham.noWant': 'Your want list is empty',
    'ham.noMyComments': 'You have not written any comments yet',
    'ham.totalCount': '%d total',
    'ham.comments': 'Course comments',
    'ham.noComments': 'No comments for this course yet',
    'ham.semesterStats': 'Semester statistics',
    'ham.year': 'Year',
    'ham.semester': 'Term',
    'ham.query': 'Query',
    'ham.median': 'Median',
    'ham.missingCourseId':
        'No course id — comments and semester statistics are unavailable.',
    'ham.needAuthTitle': 'Authorise Ham first',
    'ham.needAuthBody':
        'Use the quick-authorise button on the previous screen, then come back.',
    'ham.needAuthShort': 'Authorise Ham first',
    'ham.sectionFailed': 'Failed to load: %s',
    'ham.likes': '%d likes',
    'settings.title': 'Settings',
    'settings.appearance': 'Appearance',
    'settings.theme.system': 'Follow system',
    'settings.theme.light': 'Light',
    'settings.theme.dark': 'Dark',
    'settings.language': 'Language',
    'settings.location': 'Location',
    'settings.locationName': 'Location name',
    'settings.latitude': 'Latitude',
    'settings.longitude': 'Longitude',
    'settings.ai': 'Chat service',
    'settings.ai.base': 'Base URL',
    'settings.ai.key': 'API key',
    'settings.ai.model': 'Model',
    'settings.ai.check': 'Test connection',
    'settings.ai.checkOk': 'Connection OK',
    'settings.about': 'About',
    'settings.aboutBody': 'Campus Atlas is an independent third-party open-source '
        'implementation. It is not affiliated with, endorsed by, or derived '
        'from any official campus application, and copies none of its assets.',
    'settings.dataSources': 'Data sources',
    'settings.dataSourcesBody':
        'Weather and geocoding by Open-Meteo. Place search by OpenStreetMap '
            'Nominatim.',
    'settings.timetable': 'Timetable',
    'settings.firstWeek': 'First week start date',
    'settings.firstWeekBody':
        'Used to compute which week a class falls in, e.g. week 3.',
  };
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => AppLocalizations.supportedLocales
      .any((l) => l.languageCode == locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(AppLocalizations(locale));

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
