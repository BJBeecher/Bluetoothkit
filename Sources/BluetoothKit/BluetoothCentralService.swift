//
//  File.swift
//  
//
//  Created by BJ Beecher on 3/11/24.
//

import CoreBluetooth
import Combine
import Foundation

public final class BluetoothCentralService: NSObject {
    private var centralManager: CBCentralManager!
    
    private var cancellables = Set<AnyCancellable>()
    private var discoveredPeripherals = Set<CBPeripheral>()
    
    public let statePublisher = CurrentValueSubject<CBManagerState, Never>(.unknown)
    public let isScanningPublisher = CurrentValueSubject<Bool, Never>(false)
    public let discoveredPeripheralPublisher = PassthroughSubject<CBPeripheral, Never>()
    
    // publishers with associated triggering actions (no need to expose just use async function)
    
    private let connectToPeripheralSubject = PassthroughSubject<(id: UUID, result: Result<CBPeripheral, Error>), Never>()
    private let discoverServicesSubject = PassthroughSubject<(id: UUID, result: Result<CBPeripheral, Error>), Never>()
    private let discoverCharacteristicsSubject = PassthroughSubject<(id: CBUUID, result: Result<CBService, Error>), Never>()
    private let valueSubject = PassthroughSubject<(id: CBUUID, result: Result<Data?, Error>), Never>()
    
    public func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.statePublisher
                .dropFirst()
                .first()
                .sink { state in
                    switch state {
                    case .poweredOn:
                        continuation.resume()
                    default:
                        continuation.resume(throwing: Failure(message: "Unable to start due to state: \(state)"))
                    }
                }
                .store(in: &cancellables)
            
            self.centralManager = CBCentralManager(delegate: self, queue: .global())
        }
    }
    
    public func scanForPeripherals(services: [CBUUID]?, options: [String: Any]? = nil) {
        self.centralManager.scanForPeripherals(withServices: services, options: options)
        self.isScanningPublisher.send(true)
    }
    
    public func forgetDiscoveredPeripheral(peripheral: CBPeripheral) {
        self.centralManager.cancelPeripheralConnection(peripheral)
        self.discoveredPeripherals.remove(peripheral)
    }
    
    public func disconnect(peripheral: CBPeripheral) throws {
        for service in peripheral.services ?? [] {
            for characteristic in service.characteristics ?? [] where characteristic.isNotifying {
                peripheral.setNotifyValue(false, for: characteristic)
            }
        }
        
        self.centralManager.cancelPeripheralConnection(peripheral)
    }
    
    public func cleanup() {
        for peripheral in discoveredPeripherals where [CBPeripheralState.connected, .connecting].contains(peripheral.state) {
            try? disconnect(peripheral: peripheral)
        }
        self.centralManager.stopScan()
        self.isScanningPublisher.send(false)
        self.discoveredPeripherals = []
    }
    
    public func connect(to peripheral: CBPeripheral) async throws -> CBPeripheral {
        try await withCheckedThrowingContinuation { continuation in
            connectToPeripheralSubject
                .first(where: { $0.id == peripheral.identifier })
                .map(\.result)
                .sink { continuation.resume(with: $0) }
                .store(in: &cancellables)
            
            self.centralManager.connect(peripheral)
        }
    }
    
    public func discoverService(on peripheral: CBPeripheral, serviceId: CBUUID) async throws -> CBService {
        try await withCheckedThrowingContinuation { continuation in
            discoverServicesSubject
                .first(where: { $0.id == peripheral.identifier })
                .map(\.result)
                .map { result -> Result<CBService, Error> in
                    switch result {
                    case .success(let peripheral):
                        guard let service = peripheral.services?.first(where: { $0.uuid == serviceId }) else {
                            return .failure(Failure(message: "Failed to discover service: \(serviceId)"))
                        }
                        return .success(service)
                    case .failure(let error):
                        return .failure(error)
                    }
                }
                .sink { continuation.resume(with: $0) }
                .store(in: &cancellables)
            
            peripheral.delegate = self
            peripheral.discoverServices([serviceId])
        }
    }
    
    public func discoverCharacteristic(charactersticId: CBUUID, on peripheral: CBPeripheral, for service: CBService) async throws -> CBCharacteristic {
        try await withCheckedThrowingContinuation { continuation in
            discoverCharacteristicsSubject
                .first(where: { $0.id == service.uuid })
                .map(\.result)
                .map { result -> Result<CBCharacteristic, Error> in
                    switch result {
                    case .success(let peripheral):
                        guard let characteristic = peripheral.characteristics?.first(where: { $0.uuid == charactersticId }) else {
                            return .failure(Failure(message: "Failed to discover characteristic: \(charactersticId)"))
                        }
                        return .success(characteristic)
                    case .failure(let error):
                        return .failure(error)
                    }
                }
                .sink { continuation.resume(with: $0) }
                .store(in: &cancellables)
            
            peripheral.discoverCharacteristics([charactersticId], for: service)
        }
    }
    
    public func readValue(characteristic: CBCharacteristic, peripheral: CBPeripheral) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            valueSubject
                .first(where: { $0.id == characteristic.uuid })
                .map(\.result)
                .sink { continuation.resume(with: $0) }
                .store(in: &cancellables)
            
            peripheral.readValue(for: characteristic)
        }
    }
    
    public func readValue<Value: Decodable>(characteristic: CBCharacteristic, peripheral: CBPeripheral, with decoder: JSONDecoder = .init()) async throws -> Value {
        guard let data = try await readValue(characteristic: characteristic, peripheral: peripheral) else {
            throw Failure(message: "Failed to decode value on characteristic: \(characteristic.uuid)")
        }
        return try decoder.decode(Value.self, from: data)
    }
}

// MARK: Central delegate methods

extension BluetoothCentralService: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        debugPrint("Bluetooth central - State did change: \(central.state)")
        self.statePublisher.send(central.state)
        self.isScanningPublisher.send(central.isScanning)
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredPeripherals.contains(peripheral) {
            debugPrint("Bluetooth central - Did discover new peripheral: \(peripheral.identifier)")
            self.discoveredPeripheralPublisher.send(peripheral)
            self.discoveredPeripherals.insert(peripheral)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        debugPrint("Bluetooth central - Failed to connect to peripheral. Error: \(error?.localizedDescription ?? "")")
        self.connectToPeripheralSubject.send((peripheral.identifier, .failure(error ?? Failure(message: "Failed to connect to peripheral"))))
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        debugPrint("Bluetooth central - Did connect to peripheral: \(peripheral.debugDescription)")
        self.connectToPeripheralSubject.send((peripheral.identifier, .success(peripheral)))
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        debugPrint("Bluetooth central - did disconnect to peripheral. Error: \(error?.localizedDescription ?? "")")
    }
}

// MARK: Peripheral delegate methods

extension BluetoothCentralService: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            self.discoverServicesSubject.send((peripheral.identifier, .failure(error)))
        } else {
            self.discoverServicesSubject.send((peripheral.identifier, .success(peripheral)))
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        debugPrint(invalidatedServices.map(\.uuid))
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            self.discoverCharacteristicsSubject.send((service.uuid, .failure(error)))
        } else {
            self.discoverCharacteristicsSubject.send((service.uuid, .success(service)))
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            self.valueSubject.send((characteristic.uuid, .failure(error)))
        } else {
            self.valueSubject.send((characteristic.uuid, .success(characteristic.value)))
        }
    }
}
