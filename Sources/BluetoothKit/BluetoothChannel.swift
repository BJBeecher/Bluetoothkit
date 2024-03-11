//
//  BlueToothService.swift
//  Rub
//
//  Created by BJ Beecher on 3/8/24.
//

import CoreBluetooth
import Combine
import Foundation

public final class BluetoothChannel: NSObject {
    private let channelId: CBUUID
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private let subscribers = PassthroughSubject<CBPeripheral, Never>()
    private let messages = PassthroughSubject<Data, Never>()
    
    public init(channelId: UUID) {
        self.channelId = CBUUID(string: channelId.uuidString)
        super.init()
    }
    
    public func listenForSubscribers() -> PassthroughSubject<CBPeripheral, Never> {
        guard self.centralManager == nil else {
            return self.subscribers
        }
        
        self.centralManager = CBCentralManager(delegate: self, queue: .global())
        return self.subscribers
    }
    
    public func subscribeToChannelMessages() -> PassthroughSubject<Data, Never> {
        guard self.peripheralManager == nil else {
            return self.messages
        }
        
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: .global())
        return self.messages
    }
    
    public func connectPeripheral(peripheral: CBPeripheral) {
        centralManager.connect(peripheral)
    }
}

// MARK: Central delegate methods

extension BluetoothChannel: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            self.centralManager.scanForPeripherals(withServices: [channelId])
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        centralManager.connect(peripheral)
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let error {
            debugPrint(error)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([channelId])
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error {
            debugPrint(error)
        }
    }
}

// MARK: Peripheral manager delegate methods

extension BluetoothChannel: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            let characteristic = CBMutableCharacteristic(
                type: channelId,
                properties: [.notify, .writeWithoutResponse],
                value: nil,
                permissions: [.readable, .writeable]
            )
            let service = CBMutableService(type: channelId, primary: true)
            service.characteristics = [characteristic]
            peripheralManager.add(service)
            peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: service.uuid])
        }
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for aRequest in requests {
            guard let requestValue = aRequest.value,
                let stringFromData = String(data: requestValue, encoding: .utf8) else {
                    continue
            }
            
            debugPrint("Data recieved: ", stringFromData)
        }
    }
}

// MARK: Peripheral delegate methods

extension BluetoothChannel: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if invalidatedServices.contains(where: { $0.uuid == channelId }) {
            peripheral.discoverServices([channelId])
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            debugPrint(error)
            return
        }
        
        for service in peripheral.services ?? [] where service.uuid == channelId {
            peripheral.discoverCharacteristics([channelId], for: service)
        }
    }
    
//    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
//        Task {
//            await RubStore.shared.dispatch(creator: PeripheralDidDiscoverServices(peripheral: peripheral, error: error))
//        }
//    }
    
//    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
//        
//    }
//    
//    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
//        
//    }
    
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        for service in peripheral.services ?? [] where service.uuid == channelId {
            for characteristic in service.characteristics ?? [] where service.uuid == channelId {
                let message = "Hello peripheral: \(peripheral.identifier)"
                let data = try! JSONEncoder().encode(message)
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            }
        }
    }
}
