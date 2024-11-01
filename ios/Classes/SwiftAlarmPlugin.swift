import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import MediaPlayer
import BackgroundTasks

public class SwiftAlarmPlugin: NSObject, FlutterPlugin {
    #if targetEnvironment(simulator)
        private let isDevice = false
    #else
        private let isDevice = true
    #endif

    private var registrar: FlutterPluginRegistrar!
    static let shared = SwiftAlarmPlugin()
    static let backgroundTaskIdentifier: String = "com.gdelataillade.fetch"
    private var channel: FlutterMethodChannel!

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.gdelataillade/alarm", binaryMessenger: registrar.messenger())
        let instance = SwiftAlarmPlugin.shared

        instance.channel = channel
        instance.registrar = registrar
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    private var alarms: [Int: AlarmConfiguration] = [:]

    private var silentAudioPlayer: AVAudioPlayer?

    private var warningNotificationOnKill: Bool = false
    private var notificationTitleOnKill: String? = nil
    private var notificationBodyOnKill: String? = nil

    private var observerAdded = false
    private var playSilent = false
    private var previousVolume: Float? = nil

    private var vibratingAlarms: Set<Int> = []

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setAlarm":
            self.setAlarm(call: call, result: result)
        case "stopAlarm":
            guard let args = call.arguments as? [String: Any], let id = args["id"] as? Int else {
                result(FlutterError(code: "NATIVE_ERR", message: "[SwiftAlarmPlugin] Error: id parameter is missing or invalid", details: nil))
                return
            }
            self.stopAlarm(id: id, cancelNotif: true, result: result)
        case "isRinging":
            let id = call.arguments as? Int
            if id == nil {
                result(self.isAnyAlarmRinging())
            } else {
                result(self.alarms[id!]?.audioPlayer?.isPlaying ?? false)
            }
        case "setWarningNotificationOnKill":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "NATIVE_ERR", message: "[SwiftAlarmPlugin] Error: Arguments are not in the expected format for setWarningNotificationOnKill", details: nil))
                return
            }
            self.notificationTitleOnKill = (args["title"] as! String)
            self.notificationBodyOnKill = (args["body"] as! String)
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func unsaveAlarm(id: Int) {
        AlarmStorage.shared.unsaveAlarm(id: id)
        self.stopAlarm(id: id, cancelNotif: true, result: { _ in })
        channel.invokeMethod("alarmStoppedFromNotification", arguments: ["id": id])
    }

    private func setAlarm(call: FlutterMethodCall, result: FlutterResult) {
        self.mixOtherAudios()

        guard let args = call.arguments as? [String: Any],
            let alarmSettings = AlarmSettings.fromJson(json: args) else {
            let argumentsDescription = "\(call.arguments ?? "nil")"
            result(FlutterError(code: "NATIVE_ERR", message: "[SwiftAlarmPlugin] Arguments are not in the expected format: \(argumentsDescription)", details: nil))
            return
        }

        NSLog("[SwiftAlarmPlugin] AlarmSettings: \(alarmSettings)")

        var volumeFloat: Float? = nil
        if let volumeValue = alarmSettings.volume {
            volumeFloat = Float(volumeValue)
        }

        let id = alarmSettings.id
        let delayInSeconds = alarmSettings.dateTime.timeIntervalSinceNow

        NSLog("[SwiftAlarmPlugin] Alarm scheduled in \(delayInSeconds) seconds")

        let alarmConfig = AlarmConfiguration(
            id: id,
            assetAudio: alarmSettings.assetAudioPath,
            vibrationsEnabled: alarmSettings.vibrate,
            loopAudio: alarmSettings.loopAudio,
            fadeDuration: alarmSettings.fadeDuration,
            volume: volumeFloat,
            volumeEnforced: alarmSettings.volumeEnforced
        )

        self.alarms[id] = alarmConfig

        if delayInSeconds >= 1.0 {
            NotificationManager.shared.scheduleNotification(id: id, delayInSeconds: Int(floor(delayInSeconds)), notificationSettings: alarmSettings.notificationSettings) { error in
                if let error = error {
                    NSLog("[SwiftAlarmPlugin] Error scheduling notification: \(error.localizedDescription)")
                }
            }
        }

        warningNotificationOnKill = (args["warningNotificationOnKill"] as! Bool)
        if warningNotificationOnKill && !observerAdded {
            observerAdded = true
            NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)), name: UIApplication.willTerminateNotification, object: nil)
        }

        if let audioPlayer = self.loadAudioPlayer(withAsset: alarmSettings.assetAudioPath, forId: id) {
            let currentTime = audioPlayer.deviceCurrentTime
            let time = currentTime + delayInSeconds
            let dateTime = Date().addingTimeInterval(delayInSeconds)

            if alarmSettings.loopAudio {
                audioPlayer.numberOfLoops = -1
            }

            audioPlayer.prepareToPlay()

            if !self.playSilent {
                self.startSilentSound()
            }

            audioPlayer.play(atTime: time + 0.5)

            self.alarms[id]?.audioPlayer = audioPlayer
            self.alarms[id]?.triggerTime = dateTime
            self.alarms[id]?.task = DispatchWorkItem(block: {
                self.handleAlarmAfterDelay(id: id)
            })

            self.alarms[id]?.timer = Timer.scheduledTimer(timeInterval: delayInSeconds, target: self, selector: #selector(self.executeTask(_:)), userInfo: id, repeats: false)
            SwiftAlarmPlugin.scheduleAppRefresh()

            result(true)
        } else {
            result(FlutterError(code: "NATIVE_ERR", message: "[SwiftAlarmPlugin] Failed to load audio for asset: \(alarmSettings.assetAudioPath)", details: nil))
            return
        }
    }

    private func loadAudioPlayer(withAsset assetAudio: String, forId id: Int) -> AVAudioPlayer? {
        let audioURL: URL
        if assetAudio.hasPrefix("assets/") || assetAudio.hasPrefix("asset/") {
            let filename = registrar.lookupKey(forAsset: assetAudio)
            guard let audioPath = Bundle.main.path(forResource: filename, ofType: nil) else {
                NSLog("[SwiftAlarmPlugin] Audio file not found: \(assetAudio)")
                return nil
            }
            audioURL = URL(fileURLWithPath: audioPath)
        } else {
            let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            audioURL = documentsDirectory.appendingPathComponent(assetAudio)
        }

        do {
            return try AVAudioPlayer(contentsOf: audioURL)
        } catch {
            NSLog("[SwiftAlarmPlugin] Error loading audio player: \(error.localizedDescription)")
            return nil
        }
    }

    @objc func executeTask(_ timer: Timer) {
        if let id = timer.userInfo as? Int, let task = alarms[id]?.task {
            task.perform()
        }
    }

    private func startSilentSound() {
        let filename = registrar.lookupKey(forAsset: "assets/long_blank.mp3", fromPackage: "alarm")
        if let audioPath = Bundle.main.path(forResource: filename, ofType: nil) {
            let audioUrl = URL(fileURLWithPath: audioPath)
            do {
                self.silentAudioPlayer = try AVAudioPlayer(contentsOf: audioUrl)
                self.silentAudioPlayer?.numberOfLoops = -1
                self.silentAudioPlayer?.volume = 0.1
                self.playSilent = true
                self.silentAudioPlayer?.play()
                NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
            } catch {
                NSLog("[SwiftAlarmPlugin] Error: Could not create and play silent audio player: \(error)")
            }
        } else {
            NSLog("[SwiftAlarmPlugin] Error: Could not find silent audio file")
        }
    }

    @objc func handleInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
            case .began:
                self.silentAudioPlayer?.play()
                NSLog("[SwiftAlarmPlugin] Interruption began")
            case .ended:
                self.silentAudioPlayer?.play()
                NSLog("[SwiftAlarmPlugin] Interruption ended")
            default:
                break
        }
    }

    private func loopSilentSound() {
        self.silentAudioPlayer?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.silentAudioPlayer?.pause()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                if self.playSilent {
                    self.loopSilentSound()
                }
            }
        }
    }

    private func isAnyAlarmRinging() -> Bool {
        for (_, alarmConfig) in self.alarms {
            if let audioPlayer = alarmConfig.audioPlayer, audioPlayer.isPlaying, audioPlayer.currentTime > 0 {
                return true
            }
        }
        return false
    }

    private func handleAlarmAfterDelay(id: Int) {
        if self.isAnyAlarmRinging() {
            NSLog("[SwiftAlarmPlugin] Ignoring alarm with id \(id) because another alarm is already ringing.")
            self.unsaveAlarm(id: id)
            return
        }

        guard let alarm = self.alarms[id], let audioPlayer = alarm.audioPlayer else {
            return
        }

        self.duckOtherAudios()

        if !audioPlayer.isPlaying || audioPlayer.currentTime == 0.0 {
            audioPlayer.play()
        }

        if alarm.vibrationsEnabled {
            self.vibratingAlarms.insert(id)
            if self.vibratingAlarms.count == 1 {
                self.triggerVibrations()
            }
        }

        if !alarm.loopAudio {
            let audioDuration = audioPlayer.duration
            DispatchQueue.main.asyncAfter(deadline: .now() + audioDuration) {
                self.stopAlarm(id: id, cancelNotif: false, result: { _ in })
            }
        }

        let currentSystemVolume = self.getSystemVolume()
        let targetSystemVolume: Float

        if let volumeValue = alarm.volume {
            targetSystemVolume = volumeValue
            self.setVolume(volume: targetSystemVolume, enable: true)
        } else {
            targetSystemVolume = currentSystemVolume
        }

        if alarm.fadeDuration > 0.0 {
            audioPlayer.volume = 0.01
            fadeVolume(audioPlayer: audioPlayer, duration: alarm.fadeDuration)
        } else {
            audioPlayer.volume = 1.0
        }

        if alarm.volumeEnforced {
            alarm.volumeEnforcementTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self = self else { return }
                let currentSystemVolume = self.getSystemVolume()
                if abs(currentSystemVolume - targetSystemVolume) > 0.01 {
                    self.setVolume(volume: targetSystemVolume, enable: false)
                }
            }
        }
    }

    private func getSystemVolume() -> Float {
        let audioSession = AVAudioSession.sharedInstance()
        return audioSession.outputVolume
    }

    private func fadeVolume(audioPlayer: AVAudioPlayer, duration: TimeInterval) {
        let fadeInterval: TimeInterval = 0.2
        let currentVolume = audioPlayer.volume
        let volumeDifference = 1.0 - currentVolume
        let steps = Int(duration / fadeInterval)
        let volumeIncrement = volumeDifference / Float(steps)

        var currentStep = 0
        Timer.scheduledTimer(withTimeInterval: fadeInterval, repeats: true) { timer in
            if !audioPlayer.isPlaying {
                timer.invalidate()
                NSLog("[SwiftAlarmPlugin] Volume fading stopped as audioPlayer is no longer playing.")
                return
            }

            NSLog("[SwiftAlarmPlugin] Fading volume: \(100 * currentStep / steps)%%")
            if currentStep >= steps {
                timer.invalidate()
                audioPlayer.volume = 1.0
            } else {
                audioPlayer.volume += volumeIncrement
                currentStep += 1
            }
        }
    }

    private func stopAlarm(id: Int, cancelNotif: Bool, result: FlutterResult) {
        if cancelNotif {
            NotificationManager.shared.cancelNotification(id: id)
        }
        NotificationManager.shared.dismissNotification(id: id)

        self.mixOtherAudios()

        self.vibratingAlarms.remove(id)

        if let previousVolume = self.previousVolume {
            self.setVolume(volume: previousVolume, enable: false)
        }

        if let alarm = self.alarms[id] {
            alarm.timer?.invalidate()
            alarm.task?.cancel()
            alarm.audioPlayer?.stop()
            alarm.volumeEnforcementTimer?.invalidate()
            self.alarms.removeValue(forKey: id)
        }

        self.stopSilentSound()
        self.stopNotificationOnKillService()

        result(true)
    }

    private func stopSilentSound() {
        self.mixOtherAudios()

        if self.alarms.isEmpty {
            self.playSilent = false
            self.silentAudioPlayer?.stop()
            NotificationCenter.default.removeObserver(self)
            SwiftAlarmPlugin.cancelBackgroundTasks()
        }
    }

    private func triggerVibrations() {
        if !self.vibratingAlarms.isEmpty && isDevice {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.triggerVibrations()
            }
        }
    }

    public func setVolume(volume: Float, enable: Bool) {
        let volumeView = MPVolumeView()

        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                self.previousVolume = enable ? slider.value : nil
                slider.value = volume
            }
            volumeView.removeFromSuperview()
        }
    }

    private func backgroundFetch() {
        self.mixOtherAudios()

        self.silentAudioPlayer?.pause()
        self.silentAudioPlayer?.play()

        let ids = Array(self.alarms.keys)

        for id in ids {
            NSLog("[SwiftAlarmPlugin] Background check alarm with id \(id)")
            if let audioPlayer = self.alarms[id]?.audioPlayer, let dateTime = self.alarms[id]?.triggerTime {
                let currentTime = audioPlayer.deviceCurrentTime
                let time = currentTime + dateTime.timeIntervalSinceNow
                audioPlayer.play(atTime: time)
            }

            if let alarm = self.alarms[id], let delayInSeconds = alarm.triggerTime?.timeIntervalSinceNow {
                alarm.timer = Timer.scheduledTimer(timeInterval: delayInSeconds, target: self, selector: #selector(self.executeTask(_:)), userInfo: id, repeats: false)
            }
        }
    }

    private func stopNotificationOnKillService() {
        if self.alarms.isEmpty && self.observerAdded {
            NotificationCenter.default.removeObserver(self, name: UIApplication.willTerminateNotification, object: nil)
            self.observerAdded = false
        }
    }

    // Show notification on app kill
    @objc func applicationWillTerminate(_ notification: Notification) {
        let content = UNMutableNotificationContent()
        content.title = notificationTitleOnKill ?? "Your alarms may not ring"
        content.body = notificationBodyOnKill ?? "You killed the app. Please reopen so your alarms can be rescheduled."

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: "notification on app kill immediate", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { (error) in
            if let error = error {
                NSLog("[SwiftAlarmPlugin] Failed to show immediate notification on app kill => error: \(error.localizedDescription)")
            } else {
                NSLog("[SwiftAlarmPlugin] Triggered immediate notification on app kill")
            }
        }
    }

    // Mix with other audio sources
    private func mixOtherAudios() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            NSLog("[SwiftAlarmPlugin] Error setting up audio session with option mixWithOthers: \(error.localizedDescription)")
        }
    }

    // Lower other audio sources
    private func duckOtherAudios() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {
            NSLog("[SwiftAlarmPlugin] Error setting up audio session with option duckOthers: \(error.localizedDescription)")
        }
    }

    /// Runs from AppDelegate when the app is launched
    static public func registerBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
                self.scheduleAppRefresh()
                DispatchQueue.main.async {
                    shared.backgroundFetch()
                }
                task.setTaskCompleted(success: true)
            }
        } else {
            NSLog("[SwiftAlarmPlugin] BGTaskScheduler not available for your version of iOS lower than 13.0")
        }
    }

    /// Enables background fetch
    static func scheduleAppRefresh() {
        if #available(iOS 13.0, *) {
            let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)

            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                NSLog("[SwiftAlarmPlugin] Could not schedule app refresh: \(error)")
            }
        } else {
            NSLog("[SwiftAlarmPlugin] BGTaskScheduler not available for your version of iOS lower than 13.0")
        }
    }

    /// Disables background fetch
    static func cancelBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
        } else {
            NSLog("[SwiftAlarmPlugin] BGTaskScheduler not available for your version of iOS lower than 13.0")
        }
    }
}