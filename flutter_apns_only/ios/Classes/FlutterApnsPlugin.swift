import Flutter
import UserNotifications

func getFlutterError(_ error: Error) -> FlutterError {
    let e = error as NSError
    return FlutterError(code: "Error: \(e.code)", message: e.domain, details: error.localizedDescription)
}

/// Starting point for the plugin
@objc public class FlutterApnsPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
    internal init(channel: FlutterMethodChannel) {
        self.channel = channel
    }
    /// a method that registers the dart code to its native counterpart.
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_apns", binaryMessenger: registrar.messenger())
        let instance = FlutterApnsPlugin(channel: channel)
        registrar.addApplicationDelegate(instance)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    let channel: FlutterMethodChannel
    var launchNotification: [String: Any]?
    var resumingFromBackground = false // a boolean that determines if app is resuming from Bg.
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestNotificationPermissions":
            requestNotificationPermissions(call, result: result)
        case "configure":
            assert(
                UNUserNotificationCenter.current().delegate != nil,
                "UNUserNotificationCenter.current().delegate is not set. Check readme at https://pub.dev/packages/flutter_apns."
            )
            UIApplication.shared.registerForRemoteNotifications()

            // check for onLaunch notification *after* configure has been ran
            if let launchNotification = launchNotification {
                channel.invokeMethod("onLaunch", arguments: launchNotification)
                self.launchNotification = nil
                return
            }
            result(nil)
        case "getAuthorizationStatus":
            getAuthorizationStatus();
            result(nil)
        case "unregister":
            UIApplication.shared.unregisterForRemoteNotifications()
            result(nil)
        case "setNotificationCategories":
            setNotificationCategories(arguments: call.arguments!)
            result(nil)
        default:
            assertionFailure(call.method)
            result(FlutterMethodNotImplemented)
        }
    }
    /// is called inside [handle] method
    func setNotificationCategories(arguments: Any) {
        let arguments = arguments as! [[String: Any]]
        func decodeCategory(map: [String: Any]) -> UNNotificationCategory {
            return UNNotificationCategory(
                identifier: map["identifier"] as! String,
                actions: (map["actions"] as! [[String: Any]]).map(decodeAction),
                intentIdentifiers: map["intentIdentifiers"] as! [String],
                options: decodeCategoryOptions(data: map["options"] as! [String])
            )
        }
        func decodeCategoryOptions(data: [String]) -> UNNotificationCategoryOptions {
            let mapped = data.compactMap {
                UNNotificationCategoryOptions.stringToValue[$0]
            }
            return .init(mapped)
        }

        func decodeAction(map: [String: Any]) -> UNNotificationAction {
            return UNNotificationAction(
                identifier: map["identifier"] as! String,
                title: map["title"] as! String,
                options: decodeActionOptions(data: map["options"] as! [String])
            )
        }

        func decodeActionOptions(data: [String]) -> UNNotificationActionOptions {
            let mapped = data.compactMap {
                UNNotificationActionOptions.stringToValue[$0]
            }
            return .init(mapped)
        }

        let categories = arguments.map(decodeCategory)
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }

    /// called inside the handle function
    func getAuthorizationStatus()  {
        UNUserNotificationCenter.current().getNotificationSettings { (settings) in
            switch settings.authorizationStatus {
            case .authorized:
                self.channel.invokeMethod("setAuthorizationStatus", arguments: "authorized")
            case .denied:
                self.channel.invokeMethod("setAuthorizationStatus", arguments: "denied")
            case .notDetermined:
                self.channel.invokeMethod("setAuthorizationStatus", arguments: "notDetermined")
            default:
                self.channel.invokeMethod("setAuthorizationStatus", arguments: "unsupported status")
            }
        }
    }
    /// called inside the [handle] function.
    func requestNotificationPermissions(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let center = UNUserNotificationCenter.current()
        let application = UIApplication.shared
        
        func readBool(_ key: String) -> Bool {
            (call.arguments as? [String: Any])?[key] as? Bool ?? false
        }
        
        assert(center.delegate != nil)
        
        var options = [UNAuthorizationOptions]()
        
        if readBool("sound") {
            options.append(.sound)
        }
        if readBool("badge") {
            options.append(.badge)
        }
        if readBool("alert") {
            options.append(.alert)
        }
        
        var provisionalRequested = false
        if #available(iOS 12.0, *) {
            if readBool("provisional") {
                options.append(.provisional)
                provisionalRequested = true
            }
        }

        
        let optionsUnion = UNAuthorizationOptions(options)
        
        center.requestAuthorization(options: optionsUnion) { (granted, error) in
            if let error = error {
                result(getFlutterError(error))
                return
            }
            
            center.getNotificationSettings { (settings) in
                let map = [
                    "sound": settings.soundSetting == .enabled,
                    "badge": settings.badgeSetting == .enabled,
                    "alert": settings.alertSetting == .enabled,
                    "provisional": granted && provisionalRequested
                ]
                
                self.channel.invokeMethod("onIosSettingsRegistered", arguments: map)
            }
            
            result(granted)
        }
        
        application.registerForRemoteNotifications()
    }
    
    //MARK:  - AppDelegate
    /// Tells the delegate that the launch process is almost done and the app is almost ready to run.
    /// -- application: The singleton app object.
    /// -- launchOptions:  A dictionary indicating the reason the app was launched (if any). The contents
    /// of this dictionary may be empty in situations where the user launched the app directly. For information 
    /// about the possible keys in this dictionary and how to handle them, see UIApplication.LaunchOptionsKey.
    /// -- Return Value: 
    /// false if the app cannot handle the URL resource or continue a user activity, otherwise return true. 
    /// The return value is ignored if the app is launched as a result of a remote notification.
    public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [AnyHashable : Any] = [:]) -> Bool {
        if let launchNotification = launchOptions[UIApplication.LaunchOptionsKey.remoteNotification] as? [String: Any] {
            self.launchNotification = FlutterApnsSerialization.remoteMessageUserInfo(toDict: launchNotification)
        }
        return true
    }
    /// Tells the delegate that the app is now in the background.
    public func applicationDidEnterBackground(_ application: UIApplication) {
        resumingFromBackground = true
    }
    /// Tells the delegate that the app has become active.
    public func applicationDidBecomeActive(_ application: UIApplication) {
        resumingFromBackground = false
        application.applicationIconBadgeNumber = 1
        application.applicationIconBadgeNumber = 0
    }
    /// Tells the delegate that the app successfully registered with Apple Push Notification service (APNs).
    /// -- application: The app object that initiated the remote-notification registration process.
    /// -- deviceToken: A globally unique token that identifies this device to APNs. Send this token to the server 
    /// that you use to generate remote notifications. Your server must pass this token unmodified back to APNs when 
    /// sending those remote notifications.
    /// APNs device tokens are of variable length. Do not hard-code their size.
    public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        channel.invokeMethod("onToken", arguments: deviceToken.hexString)
    }
    
    /// Tells the app that a remote notification arrived that indicates there is data to be fetched.
    /// the system calls this method when your app is running in the foreground or background. 
    /// In addition, if you enabled the remote notifications background mode, the system launches your app 
    /// (or wakes it from the suspended state) and puts it in the background state when a remote notification arrive
    /// -- application: Your singleton app object.
    /// -- userInfo: A dictionary that contains information related to the remote notification, potentially
    /// including a badge number for the app icon, an alert sound, an alert message to display to the user,
    /// a notification identifier, and custom data. The provider originates it as a JSON-defined dictionary 
    /// that iOS converts to an NSDictionary object; the dictionary may contain only property-list objects 
    /// plus NSNull. For more information about the contents of the remote notification dictionary, see 
    /// Generating a Remote Notification.
    /// -- handler:  The block to execute when the download operation is complete. When calling this block, 
    /// pass in the fetch result value that best describes the results of your download operation. You must 
    /// call this handler and should do so as soon as possible. For a list of possible values, see the 
    /// UIBackgroundFetchResult type.
    public func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        let userInfo = FlutterApnsSerialization.remoteMessageUserInfo(toDict: userInfo)
        
        if resumingFromBackground {
            channel.invokeMethod("onBackgroundMessage", arguments: userInfo)
        } else {
            channel.invokeMethod("onMessage", arguments: userInfo)
        }
        
        completionHandler(.noData)
        return true
    }
    /// Asks the delegate how to handle a notification that arrived while the app was running in the foreground.
    /// -- center: The shared user notification center object that received the notification.
    /// -- notification: The notification that is about to be delivered. Use the information in this object to 
    /// determine an appropriate course of action. For example, you might use the information to update your app’s interface.
    /// -- completionHandler: The block to execute with the presentation option for the notification. Always execute this block
    /// at some point during your implementation of this method. Use the options parameter to specify how you want the system to 
    /// alert the user, if at all. This block has no return value and takes the following parameter:
    /// -- options: The option for notifying the user. Specify UNNotificationPresentationOptionNone to silence the notification 
    /// completely. Specify other values to interact with the user. For a list of possible options, see UNNotificationPresentationOptions.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        
        guard userInfo["aps"] != nil else {
            return
        }
        
        let dict = FlutterApnsSerialization.remoteMessageUserInfo(toDict: userInfo)
        
        channel.invokeMethod("willPresent", arguments: dict) { (result) in
            let shouldShow = (result as? Bool) ?? false
            if shouldShow {
                completionHandler([.alert, .sound])
            } else {
                completionHandler([])
                let userInfo = FlutterApnsSerialization.remoteMessageUserInfo(toDict: userInfo)
                self.channel.invokeMethod("onMessage", arguments: userInfo)
            }
        }
    }
    /// Asks the delegate to process the user's response to a delivered notification.
    /// -- center: The shared user notification center object that received the notification.
    /// -- response: The user’s response to the notification. This object contains the original 
    /// notification and the identifier string for the selected action. If the action allowed the 
    /// user to provide a textual response, this parameter contains a UNTextInputNotificationResponse object.
    /// -- completionHandler: The block to execute when you have finished processing the user’s response. You
    /// must execute this block at some point after processing the user's response to let the system know that 
    /// you are done. The block has no return value or parameters.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        var userInfo = response.notification.request.content.userInfo
        guard userInfo["aps"] != nil else {
            return
        }
        
        userInfo["actionIdentifier"] = response.actionIdentifier
        let dict = FlutterApnsSerialization.remoteMessageUserInfo(toDict: userInfo)
        
        if launchNotification != nil {
            launchNotification = dict
            return
        }

        onResume(userInfo: dict)
        completionHandler()
    }
    
    func onResume(userInfo: [AnyHashable: Any]) {
        channel.invokeMethod("onResume", arguments: userInfo)
    }
}

extension UNNotificationCategoryOptions {
    static let stringToValue: [String: UNNotificationCategoryOptions] = {
        var r: [String: UNNotificationCategoryOptions] = [:]
        r["UNNotificationCategoryOptions.customDismissAction"] = .customDismissAction
        r["UNNotificationCategoryOptions.allowInCarPlay"] = .allowInCarPlay
        if #available(iOS 11.0, *) {
            r["UNNotificationCategoryOptions.hiddenPreviewsShowTitle"] = .hiddenPreviewsShowTitle
        }
        if #available(iOS 11.0, *) {
            r["UNNotificationCategoryOptions.hiddenPreviewsShowSubtitle"] = .hiddenPreviewsShowSubtitle
        }
        if #available(iOS 13.0, *) {
            r["UNNotificationCategoryOptions.allowAnnouncement"] = .allowAnnouncement
        }
        return r
    }()
}

extension UNNotificationActionOptions {
    static let stringToValue: [String: UNNotificationActionOptions] = {
        var r: [String: UNNotificationActionOptions] = [:]
        r["UNNotificationActionOptions.authenticationRequired"] = .authenticationRequired
        r["UNNotificationActionOptions.destructive"] = .destructive
        r["UNNotificationActionOptions.foreground"] = .foreground
        return r
    }()
}

extension Data {
    var hexString: String {
        let hexString = map { String(format: "%02.2hhx", $0) }.joined()
        return hexString
    }
}
