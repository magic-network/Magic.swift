//
//  Magic.swift
//  Magic
//
//  Copyright © 2019 Magic. All rights reserved.
//

import Foundation
import NetworkExtension
import UIKit
import web3swift
import UserNotifications

public enum NetworkError: Error {
    case success
    case noEAPSettingsProvided
    case errorGettingConfiguration
    case errorConnectingToNetwork
}

enum MagicError: Error {
    case noAccount
    case failedToSaveToKeychain
    case keychainDataError
    case keychainDataMismatch
    case unhandledError(status: OSStatus)
}

enum MagicStatus: CustomStringConvertible, Equatable {
    case connected
    case disconnected
    case pending
    case enabled
    case error(NetworkError)
    
    var description : String {
        switch self {
        case .connected:
            return "co.magic.connected"
        case .enabled:
            return "co.magic.enabled"
        case .pending:
            return "co.magic.pending"
        case .disconnected:
            return "co.magic.disconnected"
        case .error:
            return "co.magic.error"
        }
    }
}

final class Magic {
    static let version = "0.0.1"
    
    static func clamp<T: Comparable>(min: T, max: T, input: T) -> T {
        if input < min {
            return min
        }
        
        if input > max {
            return max
        }
        
        return input
    }
    
    static func mapToRange<T: FloatingPoint>(input: T, in_min: T, in_max: T, out_min: T, out_max: T) -> T {
        //evidently the swift compiler can't handle this function on one line
        // The compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions
        let lhs = (input - in_min) * (out_max - out_min)
        let rhs = (in_max - in_min) + out_min
        return lhs / rhs
    }
    
    private init(){
        // just make init private so we don't have people making multiple copies of the magic class
    }
    
    static func register() {
        //initialize magic singletons
        Connectivity.shared
        Account.shared
    }
    
    class Connectivity {
        static let shared = Connectivity()
        var status: MagicStatus {
            return currentStatus
        }
        
        private var lastActiveMagicNetwork: String?
        private var currentStatus: MagicStatus
        private var app_certificate: SecCertificate?
        
        private init() {
            currentStatus = .disconnected
            installCertificate()
            setupNetworkMonitor()

            if currentSSID().hasPrefix("magic") {
                currentStatus = .connected
                lastActiveMagicNetwork = currentSSID()
                Magic.EventBus.post(MagicStatus.connected)
            }
            
        }
        
        func getCurrentInterface() -> [Any]? {
            return NEHotspotHelper.supportedNetworkInterfaces()
        }
        
        func connect(ssid: String) {
            let connectionNotification = UNMutableNotificationContent()
            let ud = UserDefaults.standard
            
            if(ssid == currentSSID()){
                print("you were already connected to the network silly")
                self.currentStatus = .connected
                self.lastActiveMagicNetwork = ssid
                Magic.EventBus.post(self.status)
            }
            
            if Account.shared.isValid() {
                var configuration: NEHotspotConfiguration?
                
                let timestamp = NSDate().timeIntervalSince1970
                let pw = "\(timestamp)-\(Magic.Account.shared.signWithTimestamp(timestamp: timestamp)!)"
                // We switch username and password because iOS limits passwords to 64 characters and usernames to 253
                configuration = NEHotspotConfiguration(ssid: ssid, eapSettings: generateEAPSettings(username: pw, password: Account.shared.getAddress()))
                
                guard let networkConfiguration = configuration else {
                    connectionNotification.title = "Failed"
                    connectionNotification.body = "Error creating configuration for network"
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "magic.connect.failed", content: connectionNotification, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)), withCompletionHandler: {error in
                        
                    })
                    self.currentStatus = .error(.errorGettingConfiguration)
                    Magic.EventBus.post(self.status)
                    return
                }
                
                NEHotspotConfigurationManager.shared.apply(networkConfiguration) { (error) in
                    // TODO: we have a slight issue here, even when its unable to join the network we get no error so it sends a success state
                    if error != nil {
                        if NEHotspotConfigurationError(rawValue: (error! as NSError).code) == .alreadyAssociated {
                            print("Already connected to the network")
                            self.currentStatus = .connected
                            self.lastActiveMagicNetwork = ssid
                            Magic.EventBus.post(self.status)
                        } else {
                            connectionNotification.title = "Failed"
                            connectionNotification.subtitle = "Could not connect to network \(ssid)"
                            connectionNotification.body = "Error: \(error!.localizedDescription)"
                            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "magic.connect.failed", content: connectionNotification, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)), withCompletionHandler: {error in
                                
                            })
                            self.currentStatus = .error(.errorConnectingToNetwork)
                            Magic.EventBus.post(self.status)
                        }
                    } else {
                        if self.currentSSID() != ssid {
                            self.currentStatus = .error(.errorConnectingToNetwork)
                            Magic.EventBus.post(self.status)
                        } else {
                            if ud.bool(forKey: "magic.notification.connect") {
                                
                                connectionNotification.title = "Connected"
                                connectionNotification.body = "You are now connected to \(ssid)"
                                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "magic.connect.success", content: connectionNotification, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)), withCompletionHandler: {error in
                                    
                                })
                            }
                            self.currentStatus = .connected
                            self.lastActiveMagicNetwork = ssid
                            Magic.EventBus.post(self.status)
                        }
                    }
                }
            } else {
                connectionNotification.title = "Failed"
                connectionNotification.body = "Your magic account is invalid"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "magic.connect.failed", content: connectionNotification, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)), withCompletionHandler: {error in
                    
                })
                self.currentStatus = .error(.errorGettingConfiguration)
                Magic.EventBus.post(self.status)
            }
        }
        
       func removeMagicConfig(_ ssid: String) {
           NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
           lastActiveMagicNetwork = nil
       }

       func removeMagicConfigAndDisconnect(_ ssid: String) {
           removeMagicConfig(ssid)
           self.currentStatus = .disconnected
           Magic.EventBus.post(MagicStatus.disconnected)
       }
        
        fileprivate func setDisconnected() {
            //Don't disconnect from the network just set our status to disconnected
            self.currentStatus = .disconnected
            Magic.EventBus.post(self.status)
        }
        
        func disconnect() {
            if let network = activeNetwork  {
                let ud = UserDefaults.standard
                
                let hasLogoffStarted = NEHotspotHelper.logoff(network)
                NSLog("Has logoff started: \(hasLogoffStarted)")
                
                if ud.bool(forKey: "magic.notification.disconnect") {
                    let connectionNotification = UNMutableNotificationContent()
                    connectionNotification.title = "Disconnected"
                    connectionNotification.body = "You are now disconnected from \(network.ssid)"
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "magic.disconnect.success", content: connectionNotification, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)), withCompletionHandler: {error in
                        
                    })
                }
            }
            if currentSSID().hasPrefix("magic") || lastActiveMagicNetwork != nil {
//                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: lastActiveMagicNetwork ?? currentSSID())
                lastActiveMagicNetwork = nil
            }
            self.currentStatus = .disconnected
            Magic.EventBus.post(self.status)
        }
        
        func generateEAPSettings(username: String, password: String) -> NEHotspotEAPSettings {
            let hotspotEAPSettings = NEHotspotEAPSettings()
            hotspotEAPSettings.username = username
            hotspotEAPSettings.password = password
            hotspotEAPSettings.isTLSClientCertificateRequired = true
            hotspotEAPSettings.supportedEAPTypes = [NEHotspotEAPSettings.EAPType.EAPTTLS.rawValue] as [NSNumber]
            hotspotEAPSettings.ttlsInnerAuthenticationType = .eapttlsInnerAuthenticationPAP
            hotspotEAPSettings.setTrustedServerCertificates([app_certificate!])
            return hotspotEAPSettings
        }
        
        // https://developer.apple.com/documentation/security/certificate_key_and_trust_services/certificates/storing_a_certificate_in_the_keycha
        private func installCertificate() {
            
            let getquery: [String: Any] = [kSecClass as String: kSecClassCertificate,
                                           kSecAttrLabel as String: "Magic Certificate",
                                           kSecReturnRef as String: kCFBooleanTrue]
            var item: CFTypeRef?
            let get_status = SecItemCopyMatching(getquery as CFDictionary, &item)
            guard get_status == errSecSuccess else {
                print("Could not find certificate in keychain \(SecCopyErrorMessageString(get_status, nil)!)")
                guard let certificate = grabBundleCertificate() else {
                    print("Could not get certificate from app bundle...")
                    return
                }
                app_certificate = certificate
                let addquery: [String: Any] = [kSecClass as String: kSecClassCertificate,
                                               kSecValueRef as String: certificate,
                                               kSecAttrLabel as String: "Magic Certificate"]
                
                let add_status = SecItemAdd(addquery as CFDictionary, nil)
                guard add_status == errSecSuccess else {
                    print("Could not install certificate to keychain \(SecCopyErrorMessageString(add_status, nil)!)")
                    return
                }
                print("Installed certificate to keychain")
                return
            }
            print("certificate is already installed")
            app_certificate = (item as! SecCertificate)
        }
        
        private func grabBundleCertificate() -> SecCertificate? {
            guard let certFile = Bundle.main.path(forResource: "server", ofType:"der") else {
                print("File not found...")
                return nil
            }
            
            guard let certData = NSData.init(contentsOfFile: certFile) else {
                print("Could not load data")
                return nil
            }
            
            guard let certificate = SecCertificateCreateWithData(nil, certData) else {
                print("Could not convert to certificate, may not be formatted properly")
                return nil
            }
            
            return certificate
        }
    }
    
    class Account {
        public static let shared = Account()
        private var address: String = ""
        private var key: Data = Data()
        
        private init() {
            do {
                try retrieveAccountFromKeychain()
            } catch {
                // account isn't saved or corrupted
                print("No account found in keychain, generating new account")
                createAccount()
            }
        }
        
        deinit {
            if !address.isEmpty && !key.isEmpty {
                do {
                    try saveAccount()
                    print("Saved account to keychain")
                } catch {
                    print("failed to save account to keychain")
                }
            }
        }
        
        func isValid() -> Bool {
            // these don't seem to match up...
            // && getPrivateKey() == self.key.toHexString()
            return !self.address.isEmpty && !self.key.isEmpty
        }
        
        func getAddress() -> String {
            return self.address
        }
        
        func getUsername() -> String {
            return self.address
        }
        
        func signWithTimestamp(timestamp: TimeInterval) -> String? {
            let message = "auth_\(Int(timestamp))".sha3(.keccak256)
            let privateKey = getPrivateKey()
            let (compressedSignature, _) = SECP256K1.signForRecovery(hash: Data(hex:message), privateKey: Data(hex: privateKey), useExtraEntropy: false)
            
            return compressedSignature!.toHexString()
        }
        
        private func getPrivateKey() -> String {
            let ethereumAddress = EthereumAddress(self.address)!
            let pkData = try! getKeystoreManager().UNSAFE_getPrivateKeyData(password: "", account: ethereumAddress).toHexString()
            return pkData
        }
        
        private func getKeystoreManager() -> KeystoreManager {
            let keystoreManager: KeystoreManager
            // Currently we don't use advanced keystores
            //        if wallet.isHD {
            //            let keystore = BIP32Keystore(data)!
            //            keystoreManager = KeystoreManager([keystore])
            //        } else {
            let keystore = EthereumKeystoreV3(self.key)!
            keystoreManager = KeystoreManager([keystore])
            //        }
            return keystoreManager
        }
        
        func createAccount() {
            let keystore = try! EthereumKeystoreV3(password: "")!
            self.key = try! JSONEncoder().encode(keystore.keystoreParams)
            self.address = keystore.addresses!.first!.address
        }
        
        func setAccountFromKey(privateKey: String) {
            let formattedKey = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let dataKey = Data.fromHex(formattedKey)!
            let keystore = try! EthereumKeystoreV3(privateKey: dataKey, password: "")!
            self.key = try! JSONEncoder().encode(keystore.keystoreParams)
            self.address = keystore.addresses!.first!.address
        }
        
        func saveAccount() throws {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrAccount as String: self.address,
                                        kSecAttrLabel as String: "Magic Credentials",
                                        kSecValueData as String: getPrivateKey()]
            let status = SecItemAdd(query as CFDictionary, nil)
            if status != errSecSuccess { if status != errSecDuplicateItem { throw MagicError.failedToSaveToKeychain} else {print("Account already in keychain")}}
        }
        
        private func retrieveAccountFromKeychain() throws {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecMatchLimit as String: kSecMatchLimitOne,
                                        kSecAttrLabel as String: "Magic Credentials",
                                        kSecReturnAttributes as String: true,
                                        kSecReturnData as String: true]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess {
                guard let existingItem = item as? [String : Any],
                    let passwordData = existingItem[kSecValueData as String] as? Data,
                    let priv_key = String(data: passwordData, encoding: String.Encoding.utf8),
                    let address = existingItem[kSecAttrAccount as String] as? String
                    else {
                        throw MagicError.keychainDataError
                }
                setAccountFromKey(privateKey: priv_key)
                if self.address != address {
                    //Happens if the private key does not match the address retrieved
                    throw MagicError.keychainDataMismatch
                }
            }
            throw MagicError.unhandledError(status: status)
        }
    }
    
    open class EventBus {
        
        struct Static {
            static let instance = Magic.EventBus()
            static let queue = DispatchQueue(label: "co.magic.EventBus", attributes: [])
        }
        
        struct NamedObserver {
            let observer: NSObjectProtocol
            let name: String
        }
        
        var cache = [UInt:[NamedObserver]]()
        
        
        ////////////////////////////////////
        // Publish
        ////////////////////////////////////
        
        
        open class func post(_ status: MagicStatus, sender: Any? = nil) {
            NotificationCenter.default.post(name: Notification.Name(rawValue: status.description), object: sender)
        }
        
        open class func post(_ name: String, sender: Any? = nil) {
            NotificationCenter.default.post(name: Notification.Name(rawValue: name), object: sender)
        }
        
        open class func post(_ name: String, sender: NSObject?) {
            NotificationCenter.default.post(name: Notification.Name(rawValue: name), object: sender)
        }
        
        open class func post(_ name: String, sender: Any? = nil, userInfo: [AnyHashable: Any]?) {
            NotificationCenter.default.post(name: Notification.Name(rawValue: name), object: sender, userInfo: userInfo)
        }
        
        open class func postToMainThread(_ status: MagicStatus, sender: Any? = nil) {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name(rawValue: status.description), object: sender)
            }
        }
        
        open class func postToMainThread(_ name: String, sender: Any? = nil) {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name(rawValue: name), object: sender)
            }
        }
        
        open class func postToMainThread(_ name: String, sender: NSObject?) {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name(rawValue: name), object: sender)
            }
        }
        
        open class func postToMainThread(_ name: String, sender: Any? = nil, userInfo: [AnyHashable: Any]?) {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name(rawValue: name), object: sender, userInfo: userInfo)
            }
        }
        
        open class func postToMainThread(_ status: MagicStatus, sender: Any? = nil, userInfo: [AnyHashable: Any]?) {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name(rawValue: status.description), object: sender, userInfo: userInfo)
            }
        }
        
        
        
        ////////////////////////////////////
        // Subscribe
        ////////////////////////////////////
        
        @discardableResult
        open class func on(_ target: AnyObject, name: String, sender: Any? = nil, queue: OperationQueue?, handler: @escaping ((Notification?) -> Void)) -> NSObjectProtocol {
            let id = UInt(bitPattern: ObjectIdentifier(target))
            let observer = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: name), object: sender, queue: queue, using: handler)
            let namedObserver = NamedObserver(observer: observer, name: name)
            
            Static.queue.sync {
                if let namedObservers = Static.instance.cache[id] {
                    Static.instance.cache[id] = namedObservers + [namedObserver]
                } else {
                    Static.instance.cache[id] = [namedObserver]
                }
            }
            
            return observer
        }
        
        @discardableResult
        open class func onMainThread(_ target: AnyObject, status: MagicStatus, sender: Any? = nil, handler: @escaping ((Notification?) -> Void)) -> NSObjectProtocol {
            return Magic.EventBus.on(target, name: status.description, sender: sender, queue: OperationQueue.main, handler: handler)
        }
        
        @discardableResult
        open class func onMainThread(_ target: AnyObject, name: String, sender: Any? = nil, handler: @escaping ((Notification?) -> Void)) -> NSObjectProtocol {
            return Magic.EventBus.on(target, name: name, sender: sender, queue: OperationQueue.main, handler: handler)
        }
        
        @discardableResult
        open class func onBackgroundThread(_ target: AnyObject, status: MagicStatus, sender: Any? = nil, handler: @escaping ((Notification?) -> Void)) -> NSObjectProtocol {
            return Magic.EventBus.on(target, name: status.description, sender: sender, queue: OperationQueue(), handler: handler)
        }
        
        @discardableResult
        open class func onBackgroundThread(_ target: AnyObject, name: String, sender: Any? = nil, handler: @escaping ((Notification?) -> Void)) -> NSObjectProtocol {
            return Magic.EventBus.on(target, name: name, sender: sender, queue: OperationQueue(), handler: handler)
        }
        
        ////////////////////////////////////
        // Unregister
        ////////////////////////////////////
        
        open class func unregister(_ target: AnyObject) {
            let id = UInt(bitPattern: ObjectIdentifier(target))
            let center = NotificationCenter.default
            
            Static.queue.sync {
                if let namedObservers = Static.instance.cache.removeValue(forKey: id) {
                    for namedObserver in namedObservers {
                        center.removeObserver(namedObserver.observer)
                    }
                }
            }
        }
        
        open class func unregister(_ target: AnyObject, name: String) {
            let id = UInt(bitPattern: ObjectIdentifier(target))
            let center = NotificationCenter.default
            
            Static.queue.sync {
                if let namedObservers = Static.instance.cache[id] {
                    Static.instance.cache[id] = namedObservers.filter({ (namedObserver: NamedObserver) -> Bool in
                        if namedObserver.name == name {
                            center.removeObserver(namedObserver.observer)
                            return false
                        } else {
                            return true
                        }
                    })
                }
            }
        }
    }
}

//currently a hack to get around missing entitlement
import SystemConfiguration.CaptiveNetwork

extension Magic.Connectivity {
    func currentSSID() -> String {
        if let interfaces = CNCopySupportedInterfaces() {
            for interface in interfaces as! [CFString] {
                if let unsafeInterfaceData = CNCopyCurrentNetworkInfo(interface) {
                    let interfaceData = unsafeInterfaceData as Dictionary
                    return interfaceData[kCNNetworkInfoKeySSID] as! String
                }
            }
        }
        return ""
    }
}

fileprivate extension Magic.Connectivity {
    
    func setupNetworkMonitor() {
        // Can we get the gateways uri/ip to use for this?
        var sock = sockaddr()
        sock.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        sock.sa_family = sa_family_t(AF_INET)
        guard let ref = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, &sock) else {
            print("Failed to create Reachability")
            return
        }
        
        var context = SCNetworkReachabilityContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        
        guard SCNetworkReachabilitySetCallback(ref, { (reachability, flags, info) in
            print("Reachability Changed")
            print("Current SSID: \(Magic.Connectivity.shared.currentSSID())")
            print("Last Active Magic Node: \(Magic.Connectivity.shared.lastActiveMagicNetwork)")
            print("Is reachable? \(flags.contains(.reachable))")
            print("Is WWAN? \(flags.contains(.isWWAN))")
            // evidently we can't use self in callbacks for this function
            if !flags.contains(.reachable) || flags.contains(.isWWAN) {
                // When we are switching networks it first triggers with unreachable but with a ssid
                // if the ssid is empty than we actaully have been disconnected
                if Magic.Connectivity.shared.currentSSID().isEmpty && Magic.Connectivity.shared.lastActiveMagicNetwork != nil {
                    // The network state changed, maybe the internet went down or we moved out of range
                    // but we can't reach the internet so disconnect
                    Magic.Connectivity.shared.setDisconnected()
                   Magic.Connectivity.shared.removeMagicConfigAndDisconnect(Magic.Connectivity.shared.lastActiveMagicNetwork!)
                }
            } else if flags.contains(.reachable) {
                // if we are connected but not to a magic network, don't disconnect from that network but remove magic config
                if !Magic.Connectivity.shared.currentSSID().hasPrefix("magic") && Magic.Connectivity.shared.lastActiveMagicNetwork != nil {
                    Magic.Connectivity.shared.setDisconnected()
                   Magic.Connectivity.shared.removeMagicConfigAndDisconnect(Magic.Connectivity.shared.lastActiveMagicNetwork!)
                } else if Magic.Connectivity.shared.currentSSID().hasPrefix("magic") && Magic.Connectivity.shared.lastActiveMagicNetwork != nil && Magic.Connectivity.shared.currentSSID() != Magic.Connectivity.shared.lastActiveMagicNetwork {
                    // We connected to a new magic network, forget the old configuration
                   Magic.Connectivity.shared.removeMagicConfig(Magic.Connectivity.shared.lastActiveMagicNetwork!)
                    
                }
            }
        }, &context) else {
            print("Failed to set callback")
            return
        }
        // Only triggers in foreground currently
        guard SCNetworkReachabilitySetDispatchQueue(ref, .main) else {
            SCNetworkReachabilitySetCallback(ref, nil, nil)
            print("Failed to add to dispatch queue")
            return
        }
        
        print("Successfully registered network status monitor")
    }
}
