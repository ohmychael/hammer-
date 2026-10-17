// A stand-in for Apple's CoreBluetooth, for running the Bluetooth scenarios where
// the real one doesn't exist (Linux). It mirrors the public Swift API that Hammer
// uses (names, labels, optionality, get-only properties). Optional delegate
// methods can't be declared without Objective-C, so the scenarios call them
// directly, the way macOS would. The sim* hooks let a scenario play the bulb.
import Foundation

public enum CBManagerState: Int { case unknown = 0, resetting, unsupported, unauthorized, poweredOff, poweredOn }
public enum CBPeripheralState: Int { case disconnected = 0, connecting, connected, disconnecting }
public enum CBCharacteristicWriteType: Int { case withResponse = 0, withoutResponse }

public struct CBCharacteristicProperties: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static var broadcast: CBCharacteristicProperties { .init(rawValue: 0x01) }
    public static var read: CBCharacteristicProperties { .init(rawValue: 0x02) }
    public static var writeWithoutResponse: CBCharacteristicProperties { .init(rawValue: 0x04) }
    public static var write: CBCharacteristicProperties { .init(rawValue: 0x08) }
    public static var notify: CBCharacteristicProperties { .init(rawValue: 0x10) }
    public static var indicate: CBCharacteristicProperties { .init(rawValue: 0x20) }
}

public let CBAdvertisementDataLocalNameKey = "kCBAdvDataLocalName"
public let CBCentralManagerScanOptionAllowDuplicatesKey = "kCBScanOptionAllowDuplicates"

open class CBUUID: NSObject {
    public let uuidString: String
    public init(string theString: String) { uuidString = theString.uppercased() }
    open override func isEqual(_ object: Any?) -> Bool { (object as? CBUUID)?.uuidString == uuidString }
    open override var hash: Int { uuidString.hashValue }
}

open class CBAttribute: NSObject {
    let _uuid: CBUUID
    init(uuid: CBUUID) { _uuid = uuid }
    open var uuid: CBUUID { _uuid }
}

open class CBCharacteristic: CBAttribute {
    var _properties: CBCharacteristicProperties
    public var _value: Data?
    public init(_sim uuid: CBUUID, properties: CBCharacteristicProperties) { _properties = properties; super.init(uuid: uuid) }
    open var properties: CBCharacteristicProperties { _properties }
    open var value: Data? { _value }
}

open class CBService: CBAttribute {
    public var _characteristics: [CBCharacteristic]?
    public init(_sim uuid: CBUUID) { super.init(uuid: uuid) }
    open var characteristics: [CBCharacteristic]? { _characteristics }
}

public protocol CBPeripheralDelegate: NSObjectProtocol {}
public protocol CBCentralManagerDelegate: NSObjectProtocol {
    func centralManagerDidUpdateState(_ central: CBCentralManager)
}

open class CBPeer: NSObject {
    let _identifier: UUID
    init(identifier: UUID) { _identifier = identifier }
    open var identifier: UUID { _identifier }
}

public struct SimWrite { public let id: UUID; public let data: Data; public let type: CBCharacteristicWriteType; public let at: Date }
public var simWrites: [SimWrite] = []
public var simLog: [String] = []

open class CBPeripheral: CBPeer {
    weak open var delegate: CBPeripheralDelegate?
    public var _name: String?
    public var _state: CBPeripheralState = .disconnected
    public var _services: [CBService]?
    public var _canSend = true
    public var _discoverServicesCalls = 0
    public init(_sim identifier: UUID, name: String?) { _name = name; super.init(identifier: identifier) }
    open var name: String? { _name }
    open var state: CBPeripheralState { _state }
    open var services: [CBService]? { _services }
    open var canSendWriteWithoutResponse: Bool { _canSend }
    open func discoverServices(_ serviceUUIDs: [CBUUID]?) {
        _discoverServicesCalls += 1
        if _state != .connected { simMisuse.append("discoverServices while \(_state)") }
        simOnDiscoverServices?(self)
    }
    open func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {
        if _state != .connected { simMisuse.append("discoverCharacteristics while \(_state)") }
        simOnDiscoverCharacteristics?(self, service)
    }
    open func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        if _state != .connected { simMisuse.append("write while \(_state)") }
        simWrites.append(SimWrite(id: identifier, data: data, type: type, at: Date()))
        simOnWrite?(self, data, type)
    }
    public var _notifying: Set<String> = []
    open func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        if enabled { _notifying.insert(characteristic.uuid.uuidString) } else { _notifying.remove(characteristic.uuid.uuidString) }
    }
}

open class CBManager: NSObject {
    public var _state: CBManagerState = .unknown
    open var state: CBManagerState { _state }
}

public weak var simCentral: CBCentralManager?
public var simKnown: [UUID: CBPeripheral] = [:]          // what retrievePeripherals can hand back
public var simConnectCalls: [UUID: Int] = [:]
public var simCancelCalls: [UUID: Int] = [:]
public var simRetrieveCalls = 0

open class CBCentralManager: CBManager {
    unowned(unsafe) open var delegate: CBCentralManagerDelegate?
    public init(delegate: CBCentralManagerDelegate?, queue: DispatchQueue?, options: [String: Any]? = nil) {
        self.delegate = delegate
        super.init()
        simCentral = self
    }
    open func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] {
        simRetrieveCalls += 1
        precondition(state == .poweredOn, "API MISUSE: retrieve while not powered on")
        return identifiers.compactMap { simKnown[$0] }
    }
    open func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]? = nil) {}
    open func stopScan() {}
    open func connect(_ peripheral: CBPeripheral, options: [String: Any]? = nil) {
        precondition(state == .poweredOn, "API MISUSE: connect while not powered on")
        simConnectCalls[peripheral.identifier, default: 0] += 1
        if peripheral._state == .disconnected { peripheral._state = .connecting }
        simOnConnect?(peripheral)
    }
    open func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        if state != .poweredOn { simMisuse.append("cancel while not powered on") }
        simCancelCalls[peripheral.identifier, default: 0] += 1
        peripheral._state = .disconnected
        simOnCancel?(peripheral)
    }
}
public var simOnConnect: ((CBPeripheral) -> Void)?
public var simOnDiscoverServices: ((CBPeripheral) -> Void)?
public var simOnDiscoverCharacteristics: ((CBPeripheral, CBService) -> Void)?
public var simOnWrite: ((CBPeripheral, Data, CBCharacteristicWriteType) -> Void)?
public var simMisuse: [String] = []
public var simOnCancel: ((CBPeripheral) -> Void)?
