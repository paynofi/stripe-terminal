import Flutter
import UIKit
import Foundation
import StripeTerminal
import ProximityReader

public class SwiftStripeTerminalPlugin: NSObject, FlutterPlugin, DiscoveryDelegate, BluetoothReaderDelegate, LocalMobileReaderDelegate, TerminalDelegate {
    
    
    let stripeAPIClient: StripeAPIClient
    let methodChannel: FlutterMethodChannel
    var discoverCancelable: Cancelable?
    var readers: [Reader] = []
    var iphoneReader: PaymentCardReader?
    var collectCancelable: Cancelable? = nil
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "stripe_terminal", binaryMessenger: registrar.messenger())
        let instance = SwiftStripeTerminalPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    
    
    public init(channel: FlutterMethodChannel) {
        self.methodChannel = channel
        stripeAPIClient = StripeAPIClient(methodChannel: channel)
        Terminal.initialize()
    }
    
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        self.discoverCancelable?.cancel({ error in
            
        })
        
        self.discoverCancelable = nil
        if (Terminal.shared.connectedReader != nil){
            Terminal.shared.disconnectReader { error in
                
            }
        }

        self.collectCancelable?.cancel({ error in
            
        })
        
        self.collectCancelable = nil
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "init":
            if(!Terminal.hasTokenProvider()){
                Terminal.setTokenProvider(stripeAPIClient)
                Terminal.shared.delegate = self
            }
            result(nil)
            break;
            
        case "clearReaderDisplay":
            Terminal.shared.clearReaderDisplay { error in
                if(error == nil){
                    result(true)
                } else {
                    result(
                        FlutterError(
                            code: "stripeTerminal#unableToClearDisplay",
                            message: error!.localizedDescription,
                            details: nil
                        )
                    )
                }
            }
        case "setReaderDisplay":
            do {
                let arguments = call.arguments as! Dictionary<String, Any>
                let rawReaderDisplay = arguments["readerDisplay"] as! Dictionary<String, Any>
                let dataReaderDisplay = try JSONSerialization.data(withJSONObject: rawReaderDisplay, options: .prettyPrinted)
                let readerDisplay = try? JSONDecoder().decode(ReaderDisplay.self, from: dataReaderDisplay)
                if(readerDisplay == nil) {
                    return result(
                        FlutterError(
                            code: "stripeTerminal#unableToDisplay",
                            message: "Invalid `readerDisplay` value provided",
                            details: nil
                        )
                    )
                }
                
                    
                let cart = Cart(
                    currency: readerDisplay!.cart.currency,
                    tax: readerDisplay!.cart.tax,
                    total: readerDisplay!.cart.total
                )
                    
                readerDisplay?.cart.lineItems.forEach({ item in
                    cart.lineItems.add(CartLineItem(displayName: item.description, quantity: item.quantity, amount: item.amount))
                })

                Terminal.shared.setReaderDisplay(cart) { (error) in
                    if(error == nil){
                        result(true)
                    } else {
                        result(
                            FlutterError(
                                code: "stripeTerminal#unableToDisplay",
                                message: error!.localizedDescription,
                                details: nil
                            )
                        )
                    }
                }
                
            } catch {
                result(
                    FlutterError(
                        code: "stripeTerminal#unableToDisplay",
                        message: "Invalid `readerDisplay` value provided",
                        details: nil
                    )
                )
            }
            break;
        case "discoverReaders#start":
            let arguments = call.arguments as! Dictionary<String, Any>
            let configData = arguments["config"] as! Dictionary<String, Any>
            let simulated = configData["simulated"] as! Bool
            let locationId = configData["locationId"] as? String
            let discoveryMethodString = configData["discoveryMethod"] as! String
            let discoveryMethod = StripeTerminalParser.getScanMethod(discoveryMethod: discoveryMethodString)
            
            if(discoveryMethod == nil){
                return result(
                    FlutterError(
                        code: "stripeTerminal#invalidRequest",
                        message: "`discoveryMethod` is not provided on discoverReaders function",
                        details: nil
                    )
                )
            }
            
            let config = DiscoveryConfiguration(
                discoveryMethod: discoveryMethod!,
                locationId: locationId,
                simulated: simulated
            )
            
            self.discoverCancelable = Terminal.shared.discoverReaders(config, delegate: self) { error in
                if let error = error {
                    result(
                        FlutterError(
                            code: "stripeTerminal#unabelToDiscover",
                            message: "Unable to discover readers because \(error.localizedDescription) ",
                            details: nil
                        )
                    )
                } else {
                    result(true)
                }
            }
            break;
        case "discoverReaders#stop":
            if(self.discoverCancelable == nil){
                result(
                    FlutterError(
                        code: "stripeTerminal#unabelToCancelDiscover",
                        message: "There is no discover action running to stop.",
                        details: nil
                    )
                )
            } else {
                self.discoverCancelable?.cancel({ error in
                    if let error = error {
                        result(
                            FlutterError(
                                code: "stripeTerminal#unabelToCancelDiscover",
                                message: "Unable to stop the discover action because \(error.localizedDescription) ",
                                details: nil
                            )
                        )
                    } else {
                        result(true)
                    }
                })
            }
            self.discoverCancelable = nil;
            break;
        case "fetchConnectedReader":
            result(Terminal.shared.connectedReader?.toDict())
            break;
        case "connectionStatus":
            result(Terminal.shared.connectionStatus.rawValue)
            break;
        case "disconnectFromReader":
            Terminal.shared.disconnectReader { err in
                if(err != nil) {
                    result(
                        FlutterError(
                            code: "stripeTerminal#unableToDisconnect",
                            message: "Unable to disconnect from device because \(err?.localizedDescription)",
                            details: nil
                        )
                    )
                } else {
                    result(true)
                }
                
            }
            break;
            
        case "connectLocalMobileReader":
            if(Terminal.shared.connectionStatus == ConnectionStatus.notConnected){
                let arguments = call.arguments as! Dictionary<String, Any>?
                
                let readerSerialNumber = arguments!["readerSerialNumber"] as! String?
                
                let reader = readers.first { reader in
                    return reader.serialNumber == readerSerialNumber
                }
                
                if(reader == nil) {
                    result(
                        FlutterError(
                            code: "stripeTerminal#readerNotFound",
                            message: "Reader with provided serial number no longer exists",
                            details: nil
                        )
                    )
                    return
                }
                
                let locationId = arguments!["locationId"] as? String? ?? reader?.locationId
                
                let onBehalfOf = arguments!["onBehalfOf"] as! String?
                let merchantDisplayName = arguments!["displayName"] as? String? ?? ""
                
                if(locationId == nil) {
                    result(
                        FlutterError(
                            code: "stripeTerminal#locationNotProvided",
                            message: "Either you have to provide the location id or device should be attached to a location",
                            details: nil
                        )
                    )
                    return
                }
                
                let connectionConfig = LocalMobileConnectionConfiguration(
                    locationId: locationId!,
                    merchantDisplayName: merchantDisplayName,
                    onBehalfOf: onBehalfOf
                )
                
                Terminal.shared.connectLocalMobileReader(reader!, delegate: self, connectionConfig: connectionConfig) { reader, error in
                    if reader != nil {
                        result(true)
                    } else {
                        result(
                            FlutterError(
                                code: "stripeTerminal#unableToConnect",
                                message: error?.localizedDescription,
                                details: nil
                            )
                        )
                    }
                }
                
            } else if(Terminal.shared.connectionStatus == .connecting) {
                result(
                    FlutterError(
                        code: "stripeTerminal#deviceConnecting",
                        message: "A new connection is being established with a device thus you cannot request a new connection at the moment.",
                        details: nil
                    )
                )
            } else {
                result(
                    FlutterError(
                        code: "stripeTerminal#deviceAlreadyConnected",
                        message: "A device with serial number \(Terminal.shared.connectedReader!.serialNumber) is already connected",
                        details: nil
                    )
                )
            }
            break;
        case "connectBluetoothReader":
            if(Terminal.shared.connectionStatus == ConnectionStatus.notConnected){
                let arguments = call.arguments as! Dictionary<String, Any>?
                
                let readerSerialNumber = arguments!["readerSerialNumber"] as! String?
                
                let reader = readers.first { reader in
                    return reader.serialNumber == readerSerialNumber
                }
                
                if(reader == nil) {
                    result(
                        FlutterError(
                            code: "stripeTerminal#readerNotFound",
                            message: "Reader with provided serial number no longer exists",
                            details: nil
                        )
                    )
                    return
                }
                
                let locationId = arguments!["locationId"] as? String? ?? reader?.locationId
                
                if(locationId == nil) {
                    result(
                        FlutterError(
                            code: "stripeTerminal#locationNotProvided",
                            message: "Either you have to provide the location id or device should be attached to a location",
                            details: nil
                        )
                    )
                    return
                }
                
                let connectionConfig = BluetoothConnectionConfiguration(
                    locationId: locationId!
                )
                
                Terminal.shared.connectBluetoothReader(reader!, delegate: self, connectionConfig: connectionConfig) { reader, error in
                    if reader != nil {
                        result(true)
                    } else {
                        result(
                            FlutterError(
                                code: "stripeTerminal#unableToConnect",
                                message: error?.localizedDescription,
                                details: nil
                            )
                        )
                    }
                }
                
            } else if(Terminal.shared.connectionStatus == .connecting) {
                result(
                    FlutterError(
                        code: "stripeTerminal#deviceConnecting",
                        message: "A new connection is being established with a device thus you cannot request a new connection at the moment.",
                        details: nil
                    )
                )
            } else {
                result(
                    FlutterError(
                        code: "stripeTerminal#deviceAlreadyConnected",
                        message: "A device with serial number \(Terminal.shared.connectedReader!.serialNumber) is already connected",
                        details: nil
                    )
                )
            }
            break;
        case "connectToInternetReader":
            if(Terminal.shared.connectionStatus == ConnectionStatus.notConnected){
                let arguments = call.arguments as! Dictionary<String, Any>?
                
                let readerSerialNumber = arguments!["readerSerialNumber"] as! String?
                let failIfInUse = arguments!["failIfInUse"] as! Bool?
                
                let reader = readers.first { reader in
                    return reader.serialNumber == readerSerialNumber
                }
                
                if(reader == nil) {
                    result(
                        FlutterError(
                            code: "stripeTerminal#readerNotFound",
                            message: "Reader with provided serial number no longer exists",
                            details: nil
                        )
                    )
                    return
                }
                
                let connectionConfig = InternetConnectionConfiguration(
                    failIfInUse: failIfInUse!
                )
                
                Terminal.shared.connectInternetReader(reader!, connectionConfig: connectionConfig) { reader, error in
                    if reader != nil {
                        result(true)
                    } else {
                        result(
                            FlutterError(
                                code: "stripeTerminal#unableToConnect",
                                message: error?.localizedDescription,
                                details: nil
                            )
                        )
                    }
                }
                
            } else if(Terminal.shared.connectionStatus == .connecting) {
                result(
                    FlutterError(
                        code: "stripeTerminal#deviceConnecting",
                        message: "A new connection is being established with a device thus you cannot request a new connection at the moment.",
                        details: nil
                    )
                )
            } else {
                result(
                    FlutterError(
                        code: "stripeTerminal#deviceAlreadyConnected",
                        message: "A device with serial number \(Terminal.shared.connectedReader!.serialNumber) is already connected",
                        details: nil
                    )
                )
            }
            break;
        case "readReusableCardDetail":
            if(Terminal.shared.connectedReader == nil){
                result(
                    FlutterError(
                        code: "stripeTerminal#deviceNotConnected",
                        message: "You must connect to a device before you can use it.",
                        details: nil
                    )
                )
            } else {
                let params =  ReadReusableCardParameters()
                Terminal.shared.readReusableCard(params) { paymentMethod, error in
                    if(paymentMethod != nil){
                        result(paymentMethod?.originalJSON)
                    } else {
                        result(
                            FlutterError(
                                code: "stripeTerminal#unabletToReadCardDetail",
                                message: "Device was not able to read payment method details.",
                                details: nil
                            )
                        )
                    }
                }
            }
            break;
        case "collectPaymentMethod":
            if(Terminal.shared.connectedReader == nil){
                result(
                    FlutterError(
                        code: "stripeTerminal#deviceNotConnected",
                        message: "You must connect to a device before you can use it.",
                        details: nil
                    )
                )
                return
            }
            
            let arguments = call.arguments as! Dictionary<String, Any>?
            
            let paymentIntentClientSecret = arguments!["paymentIntentClientSecret"] as! String?
            
            if (paymentIntentClientSecret == nil) {
                result(
                    FlutterError(
                        code:   "stripeTerminal#invalidPaymentIntentClientSecret",
                        message:  "The payment intent client_secret seems to be invalid or missing.",
                        details:   nil
                    )
                )
                return
            }
            
            let collectConfiguration = arguments!["collectConfiguration"] as! Dictionary<String, Any>?
            let collectConfig = CollectConfiguration(skipTipping: collectConfiguration!["skipTipping"] as! Bool)
            Terminal.shared.retrievePaymentIntent(clientSecret: paymentIntentClientSecret!) { paymentIntent, error in
                if let error = error {
                    result(
                        FlutterError(
                            code: "stripeTerminal#unableToRetrivePaymentIntent",
                            message: "Stripe was not able to fetch the payment intent with the provided client secret. \(error.localizedDescription)",
                            details: nil
                        )
                    )
                } else {
                    self.collectCancelable = Terminal.shared.collectPaymentMethod(paymentIntent!, collectConfig: collectConfig) { paymentIntent, error in
                        if let error = error {
                            result(
                                FlutterError(
                                    code: "stripeTerminal#unableToCollectPaymentMethod",
                                    message: "Stripe reader was not able to collect the payment method for the provided payment intent.  \(error.localizedDescription)",
                                    details: error.localizedDescription
                                )
                            )
                        } else {
                            self.generateLog(code: "collectPaymentMethod", message: paymentIntent!.originalJSON.description)
                            Terminal.shared.processPayment(paymentIntent!) { paymentIntent, error in
                                if let error = error {
                                    result(
                                        FlutterError(
                                            code: "stripeTerminal#unableToProcessPayment",
                                            message: "Stripe reader was not able to process the payment for the provided payment intent.  \(error.localizedDescription)",
                                            details: nil
                                        )
                                    )
                                } else {
                                    self.generateLog(code: "processPayment", message: paymentIntent!.originalJSON.description)
                                    result(paymentIntent?.originalJSON)
                                }
                            }
                        }
                    }
                }
            }
            break;
        case "collectPaymentMethod#stop":
            if(self.collectCancelable == nil){
                result(
                    FlutterError(
                        code: "stripeTerminal#unableToCancelCollect",
                        message: "There is no collect action running to stop.",
                        details: nil
                    )
                )
            } else {
                self.collectCancelable?.cancel({ error in
                    if let error = error {
                        result(
                            FlutterError(
                                code: "stripeTerminal#unableToCancelCollect",
                                message: "Unable to stop the collect action because \(error.localizedDescription) ",
                                details: nil
                            )
                        )
                    } else {
                        result(true)
                    }
                })
            }
            self.collectCancelable = nil;
            break;
        case "tapToPayOnIphoneIsSupported":
            do {
                var isSupported = PaymentCardReader.isSupported
                if isSupported {
                    iphoneReader = PaymentCardReader()
                }
                result(isSupported)
            } catch {
                result(
                    FlutterError(
                        code: "stripeTerminal#unableToCheckIfTTPOIIsSupported",
                        message: "Unable to check if Tap to Pay on iPhone is supported.  \(error.localizedDescription)",
                        details: nil
                    )
                )
            }
            break;
        default:
            result(
                FlutterError(
                    code: "stripeTerminal#unsupportedFunctionCall",
                    message: "A method call of name \(call.method) is not supported by the plugin.",
                    details: nil
                )
            )
        }
    }
    
    public func terminal(_ terminal: Terminal, didUpdateDiscoveredReaders readers: [Reader]) {
        self.readers = readers;
        let parsedReaders = readers.map { reader -> Dictionary<String, Any> in
            return reader.toDict()
        }
        
        methodChannel.invokeMethod("onReadersFound", arguments: parsedReaders)
    }

    public func terminal(_ terminal: Terminal, didReportReaderEvent event: ReaderEvent, info: [AnyHashable : Any]?) {
        methodChannel.invokeMethod("onReaderReportedEvent", arguments: Terminal.stringFromReaderEvent(event))
    }

    public func terminal(_ terminal: Terminal, didReportUnexpectedReaderDisconnect reader: Reader) {
        // Consider displaying a UI to notify the user and start rediscovering readers
        methodChannel.invokeMethod("onReaderUnexpectedDisconnect", arguments: reader.toDict())
    }

    public func localMobileReader(_ reader: Reader, didStartInstallingUpdate update: ReaderSoftwareUpdate, cancelable: Cancelable?) {
        // An update or configuration process has started.
        print("Entra a didStartInstallingUpdate")
    }

    public func localMobileReader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {
        // The update or configuration process has reached the specified progress (0.0 to 1.0).
        print("Entra a didReportReaderSoftwareUpdateProgress")
    }

    public func localMobileReader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {
        // The update or configuration process has ended.
        print("Entra a didFinishInstallingUpdate")
    }

    public func localMobileReaderDidAcceptTermsOfService(_ reader: Reader) {
        print("Entra a localMobileReaderDidAcceptTermsOfService")
    }

    public func localMobileReader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions = []) {
        methodChannel.invokeMethod("onReaderInput", arguments: Terminal.stringFromReaderInputOptions(inputOptions))
    }

    public func localMobileReader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {
        methodChannel.invokeMethod("onReaderDisplayMessage", arguments: Terminal.stringFromReaderDisplayMessage(displayMessage))
    }
    
    public func reader(_ reader: Reader, didReportAvailableUpdate update: ReaderSoftwareUpdate) {
        
    }
    
    public func reader(_ reader: Reader, didStartInstallingUpdate update: ReaderSoftwareUpdate, cancelable: Cancelable?) {
        
    }
    
    public func reader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {
        
    }
    
    public func reader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {
        
    }
    
    public func reader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions = []) {
        methodChannel.invokeMethod("onReaderInput", arguments: Terminal.stringFromReaderInputOptions(inputOptions))
    }
    
    public func reader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {
        methodChannel.invokeMethod("onReaderDisplayMessage", arguments: Terminal.stringFromReaderDisplayMessage(displayMessage))
    }
    
    public func reader(_ reader: Reader, didReportReaderEvent event: ReaderEvent, info: [AnyHashable : Any]?) {
        methodChannel.invokeMethod("onReaderReportedEvent", arguments: Terminal.stringFromReaderEvent(event))
    }
    
    private func generateLog(code: String, message: String) {
        var log: Dictionary<String, String> = Dictionary<String, String>()
        
        log["code"] = code
        log["message"] = message
        
        methodChannel.invokeMethod("onNativeLog", arguments: log)
    }
}


extension Reader{
    func toDict()-> Dictionary<String, Any>{
        var dict =  Dictionary<String, Any>()
        dict["serialNumber"] = self.serialNumber
        dict["originalJSON"] = self.originalJSON
        dict["availableUpdate"] = self.availableUpdate != nil
        dict["batteryLevel"] = self.batteryLevel
        dict["batteryStatus"] = self.batteryStatus.rawValue
        dict["deviceSoftwareVersion"] = self.deviceSoftwareVersion
        dict["deviceType"] = self.deviceType.rawValue
        dict["locationId"] = self.locationId
        dict["ipAddress"] = self.ipAddress
        dict["isCharging"] = self.isCharging
        dict["label"] = self.label
        dict["locationStatus"] = self.locationStatus.rawValue
        dict["stripeId"] = self.stripeId
        dict["simulated"] = self.simulated
        return dict;
    }
}

extension PaymentMethod {
    func toDict()->Dictionary<String, Any> {
        var dict =  Dictionary<String, Any>()
        dict["card"] = card?.toDict()
        dict["id"] = stripeId
        return dict;
    }
}

extension CardDetails {
    func toDict() ->Dictionary<String, Any>{
        var dict =  Dictionary<String, Any>()
        dict["brand"] = self.brand
        dict["country"] = self.country
        dict["expMonth"] = self.expMonth
        dict["expYear"] = self.expYear
        dict["fingerprint"] = self.fingerprint
        dict["last4"] = self.last4
        dict["funding"] = self.funding.rawValue
        return dict;
    }
}
