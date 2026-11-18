# Директивы и capabilities

Как бэкенд управляет колонкой. Сервер отвечает на запрос директивами: `AliceResponse` →
`directive_sequencer` → capabilities. Общая схема приведена в
[«Голосовом тракте Алисы»](voice.md).
Снято со Станции Мини 2 (`yandexmini_2`, прошивка 0.369.1.46): по строкам бинарника
`/system/vendor/quasar/maind`, логу `/data/quasar/daemons_logs/maind.log`
(`directive_sequencer routeDirective … via <Capability>`), `quasar.cfg`, схемам
[v3rt3p/quasar-protos](https://github.com/v3rt3p/quasar-protos) и серверу
[v3rt3p/quasar-server](https://github.com/v3rt3p/quasar-server). Помечено *(вывод)* то, что не
подтверждено напрямую.

!!! abstract "Главное"
    На прошивке сосуществуют два поколения директив, и у них **разный провод**. Легаси-директивы
    принимают `google.protobuf.Struct` в `TDirective.Payload`. Typed-директивы (`*_directive`)
    Struct/JSON **не принимают**: им нужно сериализованное proto-сообщение в
    `TDirective.PayloadRaw` и номер в `TDirective.DirectiveType`.

## Легаси-директивы: Struct в `Payload` { #legacy }

Payload — `google.protobuf.Struct`, ключи в `snake_case`.

| Группа | Директивы и payload |
|---|---|
| Громкость | `sound_set_level` `{new_level, new_percent_level}`, `sound_louder`, `sound_quiter`, `sound_mute`, `sound_unmute` |
| Плеер | `player_pause` `{smooth: false}`, `player_continue`, `player_next_track`, `player_previous_track` |
| Bluetooth | `start_bluetooth`, `stop_bluetooth` |
| Легаси-таймеры | `set_timer` `{duration, listening_is_possible}`; `cancel_timer`, `pause_timer`, `resume_timer` `{timer_id}` |

Шкала громкости — 0–10 (`volume_capability` в `quasar.cfg`).

Подтверждение: имена директив и ключей — строковые литералы в `maind`; quasar-server шлёт их на
реальные станции; в логе колонки виден роутинг, например `player_previous_track` →
`PlaybackControlCapability`.

## Typed-директивы: proto в `PayloadRaw` { #typed }

`maind` собран с **protobuf-lite** — без рефлексии, поэтому перевести Struct/JSON в
proto-сообщение он не может. В логе:

```text
Try to convert directive to proto in no reflection IOSDK
alarm_capability.cpp: Cannot convert directive to proto: {"timer":…}
```

Такие директивы шлют **сериализованным** сообщением в `TDirective.PayloadRaw` (поле 15) и
обязательно с `TDirective.DirectiveType`:

| Директива | Сообщение в `PayloadRaw` | `DirectiveType` |
|---|---|---|
| `timer_set_directive` | `NAlice.TAlarmCapability.TTimerSetDirective` | 112 |
| `timer_cancel_directive` | `NAlice.TAlarmCapability.TTimerCancelDirective` | 113 |
| `timer_pause_directive` | `NAlice.TAlarmCapability.TTimerPauseDirective` | 114 |
| `timer_resume_directive` | `NAlice.TAlarmCapability.TTimerResumeDirective` | 115 |
| `timer_stop_directive` | `NAlice.TAlarmCapability.TTimerStopDirective` | 276 |
| `alarm_add_directive` | `NAlice.TAlarmCapability.TAlarmAddDirective` | 32 |
| `alarm_cancel_directive` | `NAlice.TAlarmCapability.TAlarmCancelDirective` | 132 |
| `alarm_snooze_directive` | `NAlice.TAlarmCapability.TAlarmSnoozeDirective` | 116 |
| `set_do_not_disturb_directive` | `NAlice.TDoNotDisturbCapability.TSetDoNotDisturbStateDirective` | 224 |

### Поля payload { #typed-payload }

Ниже — payload в `snake_case`, как его удобно собирать на стороне бэкенда; поля один к одному
ложатся на поля proto-сообщения из таблицы выше.

| Директива | Payload |
|---|---|
| `timer_set_directive` | `{timer: {timer_id, start_timestamp, duration, remaining}}` |
| `alarm_add_directive` | `{alarm: {alarm_id, local_time, timezone, activation_days, edit_timestamp}}` |
| `alarm_cancel_directive` | `{alarm_id}` |
| `alarm_snooze_directive` | `{alarm_id, duration_sec}` |
| `set_do_not_disturb_directive` | `{force_do_not_disturb_state: "ForceEnable" \| "ForceDisable"}` |

Остановить звенящий будильник — легаси-директива `alarm_stop` (Struct в `Payload`, без
полей).

Будильник целиком:

```json
{
  "alarm": {
    "alarm_id": "<ALARM_ID>",
    "local_time": {"hours": 7, "minutes": 30, "seconds": 0},
    "timezone": {"timezone_name": "Europe/Moscow", "offset_seconds": 10800},
    "activation_days": [{"weekday": "MONDAY"}, {"weekday": "FRIDAY"}],
    "edit_timestamp": 1790000000
  }
}
```

Разовый будильник — `activation_days: [{"date": {"year": 2026, "month": 10, "day": 27}}]`.
Enum передаётся **именем** (`"ForceEnable"`, `"MONDAY"`) — так же quasar-server передаёт
`audio_player_rewind.type`.

??? note "Полный список `DirectiveType`, разобранных из `maind`"

    Список получен из `maind` (билд 2026-10-20).
    `strings -a maind | grep -oE '[A-Za-z][A-Za-z0-9_]*DirectiveType'`.
    Числовые значения `DirectiveType` хранятся как константы в коде.

    **Таймеры и будильники (25):**

    ```text
    AlarmAddDirectiveType, AlarmCancelDirectiveType, AlarmSnoozeDirectiveType,
    AlarmSoundSettingsUpdateDirectiveType, AlarmStopDirectiveType, AlarmUpdateDirectiveType,
    AlarmUpdateSoundLevelDirectiveType, CloseScreenAlarmActiveDirectiveType,
    CloseScreenTimerActiveDirectiveType, OpenScreenAlarmEditDirectiveType,
    OpenScreenAlarmListDirectiveType, OpenScreenTimerInfoDirectiveType,
    OpenScreenTimerListDirectiveType, RemindersPlayAddReminderToQueueDirectiveType,
    RemindersPlayRemoveRemindersFromQueueDirectiveType, SensorSoundAlarmMuteDirectiveType,
    SetSoundAlarmStrategyDirectiveType, ShowRemindersDirectiveType,
    StopCurrentSoundAlarmDirectiveType, TimerCancelDirectiveType, TimerPauseDirectiveType,
    TimerResumeDirectiveType, TimerSetDirectiveType, TimerStopDirectiveType,
    ToggleSensorSoundAlarmMuteDirectiveType,
    ```

    **Умный дом и IoT (89):**

    ```text
    AddGuestUserDirectiveAddIotScenariosDirectiveType, CoverCloseDirectiveType,
    CoverOpenDirectiveType, CoverResetLimitsDirectiveType, CoverSetDirectionDirectiveType,
    CoverSetLimitDirectiveType, CoverSetPositionDirectiveType, CoverSetSpeedDirectiveType,
    CoverStopDirectiveType, DoorLockAutoRelockSetDirectiveType,
    DoorLockDoorbellVolumeSetDirectiveType, DoorLockErrorVolumeSetDirectiveType,
    DoorLockPartialLockEnabledSetDirectiveType, DoorLockSetOpenDirectiveType,
    DoorLockUnlockVolumeSetDirectiveType, IotAcknowledgeCameraUsageLimitDirectiveType,
    IotBindDirectiveType, IotCalibrateCameraDirectiveType, IotCancelDiscoveryDirectiveType,
    IotCreateZoneDirectiveType, IotCustomLocalitySaveKeyDirectiveType,
    IotCustomLocalityStartDirectiveIotDeleteNetworksDirectiveType, IotDeleteZoneDirectiveType,
    IotDiscoveryContinueDirectiveType, IotEnableNetworkDirectiveType,
    IotFinishDiscoveryDirectiveType, IotFinishSystemDiscoveryDirectiveType,
    IotForgetDevicesDirectiveType, IotMoveCameraRelativeDirectiveType,
    IotMoveCameraToPositionDirectiveType, IotNameViewSetNameDirectiveType,
    IotRestoreNetworksDirectiveType, IotSetDisabledIndicatorDirectiveType,
    IotSetPlanarViewBasisDirectiveType, IotSetPlanarViewGridDirectiveType,
    IotSetPowerProfileDirectiveType, IotSetPulseTimeDirectiveType,
    IotSetRelaySwitchInputModeDirectiveType, IotSetSwitchModeDirectiveType,
    IotSetUxLayoutDirectiveType, IotSetVideoStreamKeepaliveModeDirectiveType,
    IotSetVideoStreamResolutionDirectiveType, IotSettingChildLockDirectiveType,
    IotStartDiscoveryDirectiveType, IotStartIdentifyDirectiveType,
    IotStartTrackingDirectiveType, IotStartTuyaBroadcastDirectiveType,
    IotStartWHIPVideoStreamDirectiveType, IotStopTrackingDirectiveType,
    IotStopVideoStreamDirectiveType, IotSyncEndpointsDirectiveType, IotToggleZoneDirectiveType,
    IotUnbindDirectiveType, IotUpdateZoneDirectiveType, MatterAdvertisingStartDirectiveType,
    MatterLocalityStopDirectiveType, OpenBodyDoorDirectiveType, RemoveIotScenariosDirectiveType,
    ResetLeakDirectiveType, SetAirPurifierStateDirectiveType,
    SetHvacDefrosterStateDirectiveType, SetHvacEcoStateDirectiveType,
    SetHvacFanSpeedDirectiveType, SetHvacRecirculationStateDirectiveType,
    SetHvacSeatTemperatureDirectiveType, SetHvacSeatVentilationDirectiveType,
    SetHvacTemperatureDirectiveType, SetHvacTemperatureSyncStateDirectiveType,
    SetIotAntifreezeDirectiveType, SetIotAntiscaleDirectiveType, SetIotBallastMaxDirectiveType,
    SetIotBallastMinDirectiveType, SetIotBallastMinMaxDirectiveType,
    SetIotColorMusicDirectiveType, SetIotDisplayOrientationDirectiveType,
    SetIotEnableClientDirectiveType, SetIotInterlockDirectiveType,
    SetIotScenariosActivityDirectiveType, SetIotWindowOpenDetectionDirectiveType,
    StartDoorLockDiscoveryDirectiveType, StartIotAutoCalibrationDirectiveType,
    StartLeakProtectionDoNotDisturbDirectiveType, StopLeakProtectionDoNotDisturbDirectiveType,
    SyncIotScenariosDirectiveType, ThermostatModeSetDirectiveType,
    ThermostatSetAbsoluteSetpointDirectiveType, ThermostatSetRelativeSetpointDirectiveType,
    TriggerLeakDirectiveType, ZigbeeNeighborsRequestDirectiveType,
    ```

    **UI и приложения (66):**

    ```text
    AddChatDiv2CardDirectiveType, AddTvChannelFavoritesDirectiveType,
    BrowserControlActivateTabDirectiveType, BrowserControlActivateTabGroupDirectiveType,
    BrowserControlActivateWindowDirectiveType, BrowserControlAddTabDirectiveType,
    BrowserControlCloseTabDirectiveType, BrowserControlCloseWindowDirectiveType,
    BrowserControlCreateTabGroupDirectiveType, BrowserControlGetTabGroupsDirectiveType,
    BrowserControlMoveTabsToTabGroupDirectiveType, BrowserControlMoveTabsToWindowDirectiveType,
    BrowserControlOpenNewWindowDirectiveType, BrowserControlPinTabGroupsDirectiveType,
    BrowserControlRemoveTabGroupDirectiveType, BrowserControlRenameTabGroupDirectiveType,
    BrowserControlRestoreTabDirectiveType, BrowserControlRestoreTabGroupDirectiveType,
    BrowserControlRestoreWindowDirectiveType, BrowserControlUnpinTabGroupsDirectiveType,
    CentaurOpenSeriesScreenDirectiveType, CentaurOpenVideoDetailsScreenDirectiveType,
    CentaurOpenVideoPurchaseScreenDirectiveType, ClearGuestUserDirectiveCloseCardDirectiveType,
    DeleteTvChannelFavoritesDirectiveType, DialogChannelPlaceholderDirectiveType,
    DisableScreenDirectiveType, DownloadTvUpdateDirectiveType, EnableScreenDirectiveType,
    FewRequestsLeftBannerDirectiveFillChatInputDirectiveType, HideTvCategoriesDirectiveType,
    HideTvUpdateDirectiveType, InstallTvUpdateDirectiveType,
    LegacySendBugReportTypeLimitExceededBannerDirectiveType, OpenBodyWindowDirectiveType,
    OpenDeeplinkDirectiveType, OpenProPurchaseScreenDirectiveType,
    OpenTvChannelSettingsDirectiveType, OpenTvChannelsCategoryDirectiveType,
    OpenTvChannelsScreenCentaurDirectiveType, OpenTvProgramDirectiveType,
    OpenVideoDetailsScreenDirectiveType, OpenVideoMainScreenDirectiveType,
    RetryTvUpdateDirectiveType, ScreenOffDirectiveType, ScrollToFragmentDirectiveType,
    ScrollToTopDirectiveType, SetActiveDialogDirectiveType,
    SetCompanionScreenUISkinDirectiveType, SetFullScreenModeDirectiveType,
    SetScreenAutoBrightnessDirectiveType, SetScreenBrightnessDirectiveType,
    SetScreenOnOffDirectiveType, SetScreenPowerDirectiveType, SetScreenSunriseDirectiveType,
    SetScreenSunsetDirectiveType, ShowAliceProBannerDirectiveType,
    ShowAliceVisionScreenDirectiveType, ShowBannerDirectiveType, ShowClidMenuDirectiveType,
    ShowLoginScreenDirectiveType, ShowProPurchaseScreenDirectiveType,
    ShowPromoScreenDirectiveType, ShowTvCategoriesDirectiveType,
    TOpenProlongationScreenDirectiveType, TurnOnTvChannelDirectiveType,
    ```

    **Медиа и плеер (73):**

    ```text
    ApplyMusicPlatformQueueDirectiveType, AudioPlayerDisableKaraokeModeDirectiveType,
    AudioPlayerDislikeDirectiveType, AudioPlayerEnableKaraokeModeDirectiveType,
    AudioPlayerGetLyricsDirectiveType, AudioPlayerLikeDirectiveType,
    AudioPlayerNextDirectiveType, AudioPlayerPlayDirectiveType,
    AudioPlayerPreviousDirectiveType, AudioPlayerRepeatAllDirectiveType,
    AudioPlayerRepeatOneDirectiveType, AudioPlayerSetSpeedLevelDirectiveType,
    AudioPlayerShuffleDirectiveType, AudioPlayerUndislikeDirectiveType,
    AudioPlayerUnlikeDirectiveType, AudioPlayerUnrepeatDirectiveType,
    AudioPlayerUnshuffleDirectiveType, ChangeVideoPlayerTrackDirectiveType,
    CollectMusicVerticalDirectiveType, ControlExternalPlayerDirectiveType,
    FetchEnrollmentAudioDirectiveType, ForgetRadioDirectiveType,
    LocalAudioFilePlayDirectiveType, LocalAudioFileStopDirectiveType,
    MusicSearchRequestDirectiveType, OpenMusicSearchDirectiveType,
    OpenPlayerTvChannelListDirectiveType, OpenPlayerTvProgramDirectiveType,
    OpenYoutubeUriDirectiveType, PlayHlsStreamDirectiveType, PlayInExternalPlayerDirectiveType,
    PlayWebRTCStreamDirectiveType, PlayerControlDislikeDirectiveType,
    PlayerControlFastForwardDirectiveType, PlayerControlLikeDirectiveType,
    PlayerControlNextTrackDirectiveType, PlayerControlPauseDirectiveType,
    PlayerControlPlayDirectiveType, PlayerControlPrevTrackDirectiveType,
    PlayerControlRepeatDirectiveType, PlayerControlReplayDirectiveType,
    PlayerControlResumeDirectiveType, PlayerControlRewindDirectiveType,
    PlayerControlShuffleDirectiveType, PlayerControlUndoDislikeDirectiveType,
    PlayerControlUndoLikeDirectiveType, PlayerControlUnshuffleDirectiveType,
    PlayerSkipToNextDirectiveType, PlayerSkipToPreviousDirectiveType,
    SetAnimationColorMusicDirectiveType, SetAudioPlayerSequenceStateDirectiveType,
    SetEnableColorMusicDirectiveType, ShowAudioPlayerScreenDirectiveType,
    ShowEpisodeDirectiveType, ShowMusicAlbumScreenDirectiveType,
    ShowMusicArtistPlaylistsDirectiveType, ShowMusicArtistPopularAlbumsDirectiveType,
    ShowMusicArtistPopularTracksDirectiveType, ShowMusicArtistScreenDirectiveType,
    ShowMusicArtistSimilarArtistsDirectiveType, ShowMusicPlaylistScreenDirectiveType,
    ShowVideoPlayerTrackSettingsDirectiveType, StartRadioDiscoveryDirectiveType,
    StereoPairPlayerNotReadyNotificationDirectiveType, StopRadioDiscoveryDirectiveType,
    TurnOffVinylDirectiveType, TurnOnVinylDirectiveType, VinylJogWheelForwardDirectiveType,
    VinylJogWheelReverseDirectiveType, YaDiskAlbumItemsDataDirectiveType,
    YoutubeDislikeDirectiveType, YoutubeLikeDirectiveType, YoutubeOpenAccountsDirectiveType,
    ```

    **Звонки (23):**

    ```text
    AcceptVideoCallDirectiveType, DiscardVideoCallDirectiveType,
    DivUICallActionsGroupsDirectiveType, DivUICallTerminateActionsDirectiveType,
    OpenDeviceCallUIDirectiveType, PhoneCallsAcceptCallDirectiveType,
    PhoneCallsHangUpCallDirectiveType, PhoneCallsIgnoreIncomingCallDirectiveType,
    PhoneCallsMakeCallDirectiveType, PhoneCallsOpenDeviceCallUiDirectiveType,
    PhoneCallsProcessIncomingCallDirectiveType, ProcessIncomingVideoCallDirectiveType,
    ShowCallErrorDirectiveType, StartVideoCallDirectiveType, StartVideoCallLoginDirectiveType,
    VideoCallLogoutDirectiveType, VideoCallMuteMicDirectiveType,
    VideoCallSetActionOnCallEndDirectiveType, VideoCallTurnOffAutoCropDirectiveType,
    VideoCallTurnOffVideoDirectiveType, VideoCallTurnOnAutoCropDirectiveType,
    VideoCallTurnOnVideoDirectiveType, VideoCallUnmuteMicDirectiveType,
    ```

    **Сценарии и чат (22):**

    ```text
    ActivateSmartScenarioDirectiveType, AliceChatHapticDirectiveType,
    AliceChatHapticToggleSettingDirectiveType, AliceChatListenOnStartToggleSettingDirectiveType,
    AliceChatMuteToggleSettingDirectiveType, AliceChatShareDirectiveType,
    ChatNavigateBackDirectiveType, ContinueScenarioLaunchDirectiveType,
    CreateNewChatDirectiveType, DeactivateSmartScenarioDirectiveType, DismissChatDirectiveType,
    FinishChatDirectiveType, OpenChatListDirectiveType, OpenSmartHomeConfirmQrDirectiveType,
    OpenSmartHomeDirectiveType, OpenSmartHomePageDirectiveType, OpenWebChatDirectiveType,
    SetChatRequestModeDirectiveType, SetChatSettingModeDirectiveType,
    ShowAliceChatFilesPickerDirectiveType, ShowAliceChatSettingsDirectiveType,
    WaitScenarioDelayDirectiveType,
    ```

    **Громкость и уровни (20):**

    ```text
    AdhanSetSoundLevelDirectiveType, CecVolumeDownDirectiveType, CecVolumeUpDirectiveType,
    ProcessSmartVolumeDirectiveType, SetAbsoluteLevelDirectiveType,
    SetBrightnessLevelDirectiveType, SetLevelCorrectionDirectiveType,
    SetRelativeLevelDirectiveType, ShowVolumeDirectiveType, StartCalibrationLevelDirectiveType,
    StartMoveLevelDirectiveType, StopMoveLevelDirectiveType, StopTransitionLevelDirectiveType,
    TransitionLevelDirectiveType, VideoSetSpeedLevelDirectiveType, VolumeMuteDirectiveType,
    VolumeSetDirectiveType, VolumeStartVolumeChangeDirectiveType,
    VolumeStopVolumeChangeDirectiveType, VolumeUnmuteDirectiveType,
    ```

    **Аккаунт и авторизация (19):**

    ```text
    AddAccountDirectiveType, AddAccountWithCookieDirectiveType, ExpandAccountListDirectiveType,
    LocalAddAccountDirectiveType, LoginWithCallbackDirectiveType,
    MultiaccountAddAccountDirectiveType, MultiaccountRemoveAccountDirectiveType,
    MultiaccountRemoveAccountPersIdDirectiveType, NativeDeleteAccountDirectiveType,
    NativeLogoutDirectiveType, OpenAccountListDirectiveType, PhoneCallsAddAccountDirectiveType,
    PhoneCallsConnectAccountDirectiveType, PhoneCallsDeleteAccountDirectiveType,
    PhoneCallsRefreshAccountDirectiveType, RefreshAccountDirectiveType,
    RemoveAccountDirectiveType, SetIoTAccountSettingsDirectiveType, SwitchAccountDirectiveType,
    ```

    **Дисплей и свет (14):**

    ```text
    ChangeAmbientLightingColorDirectiveType,
    OpenPowerButtonDoubleTapSystemSettingsDirectiveType, SetAmbientLightingStateDirectiveType,
    SetAutoBrightnessDirectiveType, SetButtonBacklightBrightnessDirectiveType,
    SetHudBrightnessDirectiveType, SetHueAndSaturationDirectiveType, SetHueDirectiveType,
    SetInstrumentPanelBrightnessDirectiveType, SetLedMaskDirectiveType,
    SetSaturationDirectiveType, SetTapGroupSettingDirectiveType,
    StartLightSequenceDirectiveType, StopLightSequenceDirectiveType,
    ```

    **ИК-пульты (12):**

    ```text
    AddIrRemoteDirectiveType, CancelRecordIrPulseDirectiveType, ForgetIrRemoteDirectiveType,
    PartialRestoreIrRemotesDirectiveType, RecordIrPulseDirectiveType,
    RestoreIrRemotesDirectiveType, SendIrAcCommandDirectiveType, SendIrCommandDirectiveType,
    SendIrCustomCommandDirectiveType, SetMaxAcStateDirectiveType, TryIrAcCommandDirectiveType,
    TryIrCommandDirectiveType,
    ```

    **OTA и обновления (11):**

    ```text
    AdhanAddOrUpdateDirectiveType, AdhanUpdateActivationTimesDirectiveType,
    CheckFirmwareUpdateDirectiveType, ForceOtaRequestDirectiveType,
    MakeOrderUpdateStateDirectiveType, OtaApplyDirectiveType, PushUpdateConfigDirectiveType,
    UpdateAllInformersDirectiveType, UpdateInformerDirectiveType,
    UpdateSiteContentDirectiveType, UpdateTtsPlaceholderDirectiveType,
    ```

    **Голос и распознавание (9):**

    ```text
    FinishSpeechInputDirectiveType, ScenarioVoiceTriggerDirectiveType,
    SetGestureRecognitionDirectiveType, SetSpeechModeOptionsDirectiveType,
    SetVoiceZoneSettingsDirectiveType, SpeechModeShowDirectiveType,
    SpeechModeShowTimeEndingBannerDirectiveType, StartSpeechInputDirectiveType,
    StartVoiceInputDirectiveType,
    ```

    **Биометрия (8):**

    ```text
    BioStartSoundEnrollmentDirectiveType, CalculateVoiceprintDirectiveType,
    ForgetFaceEnrollmentDirectiveType, RemoveVoiceprintDirectiveType,
    ShowVoiceprintRemoveSuccessDirectiveType, StartFaceEnrollmentDirectiveType,
    StartFaceRecordingDirectiveType, StartVoiceprintEnrollmentDirectiveType,
    ```

    **Wi-Fi и сеть (5):**

    ```text
    ConnectToNetworkDirectiveType, ForceSyncWifiConfigurationDirectiveType,
    SetWifiConfigurationDirectiveType, ZenohLocalitySaveKeyDirectiveType,
    ZenohLocalityStartDirectiveZenohLocalityStopDirectiveType,
    ```

    **Bluetooth (2):**

    ```text
    ConnectBluetoothDirectiveType, DisconnectBluetoothDirectiveType,
    ```

    **Уведомления (3):**

    ```text
    ScheduleLocalNotificationDirectiveType, ShowNotificationDirectiveType,
    StereoPairNoConnectionNotificationDirectiveType,
    ```

    **Прочее (333):**

    ```text
    AccessibilityPressButtonByIdDirectiveType, AccessibilityWriteTextInInputDirectiveType,
    ActivateOwnAppDirectiveType, AddDeviceDirectiveType, AddDigitalMeterDirectiveType,
    AddEnrolledPersonDirectiveType, AddTeaserDirectiveType, AddToWatchListDirectiveType,
    AddWireLineDirectiveType, AdhanRemoveDirectiveType, AdhanSetMuezzinSettingsDirectiveType,
    AdhanStopDirectiveType, AliceAppsSelectDirectiveType, AliceAppsWidgetSetDataDirectiveType,
    AliceBlockDirectiveType, AliceShowStartDirectiveType, AliceShowStopDirectiveType,
    AliceStartDataInputDirectiveAliceStartFileUploadDirectiveAliceUnblockDirectiveType,
    AliceVisionFreeRequestsLimitExceededDirectiveType, ApproveNotifyDirectiveType,
    AssistantResponseModeToggleSettingDirectiveType, AuthorizePupaDirectiveType,
    AutoHeadTextMessagingDisableSyncDirectiveType, AutoHeadTextMessagingEnableSyncDirectiveType,
    AutoHeadTextMessagingOpenPopupMessageDirectiveType,
    AutoHeadTextMessagingSendMessageDirectiveType, BrowserControlClearBrowsingDataDirectiveType,
    BrowserControlCloseTabsDirectiveType, BrowserControlGetBookmarksDirectiveType,
    BrowserControlGetBrowserStatusDirectiveType,
    BrowserControlGetClearBrowsingDataCountersDirectiveType,
    BrowserControlGetCurrentTimeDirectiveType, BrowserControlGetTabsDirectiveType,
    BrowserControlGetWindowsDirectiveType, BrowserControlPinTabsDirectiveType,
    BrowserControlRestoreTabsDirectiveType,
    BrowserControlSetBookmarksPanelVisibilityDirectiveType,
    BrowserControlSetDefaultBrowserDirectiveType, BrowserControlSwitchColorSchemeDirectiveType,
    BrowserControlUnpinTabsDirectiveType, BuyCurrentDirectiveType, BuzzerPlayDirectiveType,
    CameraLocalArchiveFormatStorageDirectiveType, CameraLocalArchiveGetFileDirectiveType,
    CameraLocalArchiveGetFileHeaderDirectiveType, CameraLocalArchiveGetFileSegmentDirectiveType,
    CameraLocalArchiveGetFileThumbnailDirectiveType, CameraLocalArchiveGetManifestDirectiveType,
    CameraLocalArchiveListFilesDirectiveType, CameraLocalArchiveRemoveFilesDirectiveType,
    CameraLocalArchiveUnmountStorageDirectiveType, CameraSnapshotTakePictureDirectiveType,
    CameraVideoRecordingStartVideoRecordingDirectiveType, CancelAutoskipDirectiveType,
    CancelScheduledActionDirectiveType, CategoryDirectiveType, ChangeOwnerDirectiveType,
    ChildModeUnblockDirectiveType, ClearContextDirectiveType, CloseScreensaverDirectiveType,
    CollectDiagnosticArtifactDirectiveType, CompleteStreamingResponseDirectiveType,
    CompleteTtsResponseDirectiveType, ContinueRouteManagerDirectiveType,
    DisableCommandPhrasesDirectiveType, DisableLyricsDirectiveType,
    DivUIHideAllViewsDirectiveType, DivUIHideViewDirectiveType, DivUIPatchViewDirectiveType,
    DivUIShowViewDirectiveType, DivUIStashViewDirectiveType, DivUIUnstashViewDirectiveType,
    DontAutoPlayRelatedVideoDirectiveType, DownloadImageDirectiveType,
    DrawAnimationDirectiveType, EDirectiveType, EnableCommandPhrasesDirectiveType,
    EnableLyricsDirectiveType, EnrollmentCancelDirectiveType, EnrollmentFinishDirectiveType,
    EnrollmentShareDirectiveType, EnrollmentStartDirectiveType,
    ExecuteActionOnLeaderDirectiveType, ExpertLimitNoticeDirectiveType,
    FinishEnrollmentUiDirectiveType, ForceSubscriptionCheckDirectiveType,
    ForgetAllFacesDirectiveType, ForgetPairedDevicesDirectiveType,
    GetCallableDevicesDirectiveType, GetNotificationsDirectiveType,
    GetUsersWithVoiceprintsDirectiveType, HideClockDirectiveType, HideFromDelayedDirectiveType,
    InstallMarketAppDirectiveType, InvalidateAutoListenDirectiveType,
    InvokeAppFunctionDirectiveType, IoTEndpointsRemovedDirectiveType,
    IoTEndpointsStateChangedDirectiveType, IpCamSetStreamingAllowedDirectiveType,
    KidsStartAwakeningDirectiveType, KidsStopAwakeningDirectiveType, LaunchAppDirectiveType,
    LaunchFileDownloadDirectiveType, LimitUpdatedDirectiveType, LoadScreensaversDirectiveType,
    LongPollingJobDirectiveType, MakeOrderLaunchApplicationDirectiveType,
    MakeOrderProcessCheckoutResultDirectiveType, MakeOrderProcessSearchResultsDirectiveType,
    ManualCalibrationAbortSessionDirectiveType, ManualCalibrationFinishSessionDirectiveType,
    ManualCalibrationRunStageDirectiveType, MotorControlCloseDirectiveType,
    MotorControlOpenDirectiveType, MotorControlStopDirectiveType,
    MotorControlToggleDirectiveType, MultiroomSemanticFrameDirectiveType,
    NoiseReductionSetModeDirectiveType, NotesEventDirectiveType, NotifyDirectiveType,
    OnOffDirectiveType, OnWithTimedOffDirectiveType, OpenAndroidSettingsDirectiveType,
    OpenAppDetailsDirectiveType, OpenAppsMarketDirectiveType, OpenBodySideMirrorsDirectiveType,
    OpenBodySunVisorDirectiveType, OpenBodyTrapdoorDirectiveType, OpenBodyTrunkDirectiveType,
    OpenBrowserDirectiveType, OpenCatalogDirectiveType,
    OpenColdstartRecommendationsDirectiveType, OpenContentDirectiveType,
    OpenCurrentContentTrailerDirectiveType, OpenDefaultAssistantSettingsDirectiveType,
    OpenDeviceSettingsDirectiveType, OpenDownloadedFileDirectiveType,
    OpenNativePassportDirectiveType, OpenQRPaymentDirectiveType, OpenScreensaverDirectiveType,
    OpenSearchDirectiveType, OpenSerialNavigatorDirectiveType,
    OpenSerialNavigatorTypeOpenSerpViewDirectiveType, OpenSourceInputDirectiveType,
    OpenSourceInputsListDirectiveType, OpenTretyakovkaInfoDirectiveType, OpenUrlDirectiveType,
    OpenWhatsNewStorageDirectiveType, OptionalDirectiveType,
    PhoneByContactsBookContactDirectiveType, PhoneCallsSetMicMuteDirectiveType,
    PhoneGetLastCalledContactDirectiveType, PlayChannelDirectiveType,
    PlaySportVideoDirectiveType, PlayVideoDirectiveType, PlayWeatherDirectiveType,
    PlayWebVideoDirectiveType, PowerButtonAssistantActivationToggleSettingDirectiveType,
    PowerOffDirectiveType, PurchaseInAppOfferDirectiveType,
    QueryVisitedPageContextsDirectiveType, ReadNotificationsDirectiveType,
    RemoveDigitalMeterDirectiveType, RemoveFromWatchListDirectiveType,
    RemoveTeaserDirectiveType, RemoveWireLineDirectiveType, ReplaceWireLineDirectiveType,
    RequestDeviceStateDirectiveType, RequestInAppPurchaseOffersDirectiveType,
    RequestPermissionDirectiveType, ResetCalibrationDirectiveType, ResolvePendingDirectiveType,
    RotateTeasersDirectiveType, RouteDirectiveType, SaveSensorsDirectiveType,
    ScheduleActionDirectiveType, ScreenshotTakenDirectiveType,
    SearchFilteringToggleSettingDirectiveType,
    SendBugReportTypeSendExecuteNonLocalStepEventDirectiveType,
    SendLocalStepsFinishedEventDirectiveType, SendMetricaEventDirectiveType,
    SendVideoFrameCallbackDirectiveType, SerialNavigatorOpenPurchaseDirectiveType,
    SetAdjustableEqualizerBandsDirectiveType, SetAliceWatchStateDirectiveType,
    SetAnimationColorAnimationDirectiveType, SetAnimationTypeCommonSettingDirectiveType,
    SetAqsStateDirectiveType, SetAutoConditioningSystemStateDirectiveType,
    SetAutoDefrosterStateDirectiveType, SetAutoSeatHeatingStateDirectiveType,
    SetAutoSeatVentilationStateDirectiveType, SetBlockedDirectiveType, SetChannelDirectiveType,
    SetColorSceneDirectiveType, SetConditioningSystemStateDirectiveType,
    SetCoolingSystemStateDirectiveType, SetDivVariablesDirectiveType,
    SetDoNotDisturbStateDirectiveType, SetDrivingModeStateDirectiveType,
    SetElectricVentModeDirectiveType, SetEnabledExternalTemperatureMeasurementDirectiveType,
    SetEventsDirectiveType, SetFanDirectionDirectiveType, SetFeedBackDirectiveType,
    SetFixedEqualizerBandsDirectiveType, SetFlashlightStateDirectiveType,
    SetFragranceIntensityDirectiveType, SetFragranceStateDirectiveType,
    SetFragranceTypeDirectiveType, SetFridgeStateDirectiveType, SetGmtDirectiveType,
    SetHeatingSystemStateDirectiveType, SetHudHeightDirectiveType, SetHudModeDirectiveType,
    SetHudStateDirectiveType, SetIntonationSpottingDirectiveType,
    SetIntonationSpottingSettingsDirectiveType, SetIoTUserInfoDirectiveType,
    SetJingleStateDirectiveType, SetLitersPerImpulseDirectiveType, SetLocalizationDirectiveType,
    SetLocationDirectiveType, SetLyricsDirectiveType, SetMassageModeDirectiveType,
    SetMassageSeatSpeedDirectiveType, SetMeasuredValueDirectiveType,
    SetMirrorHeatingStateDirectiveType,
    SetMotionDetectionIntervalTypeSetMotionSettingDirectiveType,
    SetMotorCloseLimitDirectiveType, SetMotorDirectionDirectiveType,
    SetMotorLimitsDirectiveType, SetMotorOpenLimitDirectiveType,
    SetNeptuneRelayModeDirectiveType, SetNeptuneUpsForceAttachDirectiveType,
    SetNightModeDirectiveType, SetNightVisionModeDirectiveType,
    SetNoiseCancellationModeDirectiveType, SetOneTouchHeatingStateDirectiveType,
    SetPanoramicDisplayStateDirectiveType, SetPreferenceDirectiveType,
    SetPrivacyModeDirectiveType, SetReactionEventsDirectiveType,
    SetReactionSettingDirectiveType, SetRecalibrationEnabledDirectiveType,
    SetShouldApplyPendingContentInstantlyDirectiveType, SetSoundInputDirectiveType,
    SetSoundOutputDirectiveType, SetStartupModeDirectiveType,
    SetSteeringWheelHeatingStateDirectiveType, SetTemperatureKDirectiveType,
    SetThreeRowSeatingModeDirectiveType, SetTimezoneDirectiveType,
    SetUniProxySettingsDirectiveType, SetVadActionDirectiveType,
    SetVirtualSurroundDirectiveType, SetVisualSpottingDirectiveType,
    SetVisualizationSettingsDirectiveType, SetWallpaperDirectiveType,
    SetWaterMeterLitersDirectiveType, SetWidgetStackDirectiveType,
    SetWirelessChargingStateDirectiveType, SetWorkModeDirectiveType, SetWorkSpeedDirectiveType,
    ShareEnrolledPersonDirectiveType, ShareImageDirectiveType, ShowAgentPinsDirectiveType,
    ShowAlarmsDirectiveType, ShowAnimationDirectiveType, ShowAssistantOnboardingDirectiveType,
    ShowAutomotiveWeatherDirectiveType, ShowCaptchaDirectiveType, ShowClockDirectiveType,
    ShowEnrollmentPhraseDirectiveType, ShowEnrollmentUserAvatarDirectiveType,
    ShowExternalCinemasDirectiveType, ShowFullscreenImageGalleryDirectiveType,
    ShowModalDirectiveType, ShowOnboardingDirectiveType, ShowRouteManagerDirectiveType,
    ShowTimersDirectiveType, ShowTiresDirectiveType, ShowWeatherDirectiveType,
    ShowWhatYouCanDirectiveType, ShowWhatsNewDirectiveType, ShowWhatsNewInSourcesDirectiveType,
    SkipVideoFragmentDirectiveType, StartBleAdvertisingDirectiveType,
    StartBleDiscoveryDirectiveType, StartBleSetupDirectiveType,
    StartCustomNoiseRecordingDirectiveType, StartEnergyScanDirectiveType,
    StartEnrollmentOnboardingDirectiveType, StartFeatureBoardingDirectiveType,
    StartFilePollingDirectiveType, StartFileUploadDirectiveType, StartMobileAgentDirectiveType,
    StartMultiroomDirectiveType, StartNoteInputDirectiveType, StartRecognizeDirectiveType,
    StartRecordInputDirectiveType, StartRouteManagerDirectiveType, StartSetupDirectiveType,
    StartTextInputDirectiveType, StartTranslateInputDirectiveType, StartWorkoutDirectiveType,
    StashViewDirectiveType, StopConversationDirectiveType,
    StopCustomNoiseRecordingDirectiveType, StopRouteManagerDirectiveType,
    SubscribeIoTEndpointsDirectiveType, SuggestReaskDirectiveType, SyncIoTUserInfoDirectiveType,
    SyncNotesDirectiveType, TImageAttachmentDirectiveType, TProlongTimeLimitDirectiveType,
    TPurchaseSubscriptionDirectiveType, TPurchaseVideoDirectiveType,
    TSendUnblockRequestDirectiveType, TakeScreenshotDirectiveType, ToggleOnOffDirectiveType,
    TogglePrivacyModeDirectiveType, TriggerRatingDirectiveType, UnknownDirectiveType,
    UnlinkDeviceDirectiveType, UnstashViewDirectiveType, UnsubscribeIoTEndpointsDirectiveType,
    VideoSkipAdvertisementDirectiveType, VocalizeDirectiveType, WebOSLaunchAppDirectiveType,
    WebOSManageAppDirectiveType, WebOSShowGalleryDirectiveType, ZoomImageDirectiveType,
    ```


## Будильники без iCalendar { #alarms }

В `maind` этой прошивки нет кода iCalendar вообще — ни `BEGIN:VCALENDAR`, ни `DTSTART`, ни
`RRULE`. Поэтому классическая директива `alarms_update` `{state: <iCalendar>}` здесь не
разбирается. Будильники ставятся typed-директивами выше, а их список колонка отдаёт только через
`CapabilityUpdateState` (`TAlarmCapability.State.Alarms`).

На Лайт 1 с прошивкой `0.369.1.46.4778262442.20261013.297` в
`alarmd` отдельно задаются начальная, конечная и минимальная громкость
будильников/напоминаний и шаг изменения громкости. Это свойства штатного
проигрывания, а не директивы создания будильника.

## Что не путать { #pitfalls }

| Директива | На самом деле | Для колонки нужно |
|---|---|---|
| `stop_current_sound_alarm_directive` | `TIotSoundAlarmCapability` — сирены IoT-датчиков (протечка, дым) | звенящий будильник — `alarm_stop`, таймер — `timer_stop_directive` |
| `set_absolute_level_directive`, `set_relative_level_directive` | `TLevelCapability` — общий уровень endpoint'а (например, IoT-диммеры) | собственная громкость — `sound_*` |

## Состояние устройства { #state }

Колонка рапортует `TDeviceState` — громкость, плеер, таймеры (`ActiveTimers`), звенящий
будильник (`AlarmState.CurrentlyPlaying`):

- в каждом запросе — `VoiceInput`/`TextInput`, поле `Request.DeviceStateRaw`;
- отдельно — событием `CapabilityUpdateState`.

Список будильников в `TDeviceState` не приходит — только в `TAlarmCapability.State`.

## Источник { #source }

Снято в проекте syrinx — своём бэкенде для колонки (GPL-3.0, репозиторий в публикации).
Про подмену облачного адреса — [«Своя LLM вместо Алисы»](../recipes/llm.md) и
[«Колонка без Яндекса»](../recipes/standalone.md).

## «Не беспокоить»: где живёт расписание

Расписание «Не беспокоить» (время начала/конца) прошивка не хранит: `device_config.dndMode.enabled` в `user_config.dat` содержит только состояние и `features.allowIncomingCalls`; расписание живёт в облаке и применяется бэкендом/приложением. Локальные директивы — только `ForceEnable`/`ForceDisable`.
