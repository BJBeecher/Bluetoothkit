//
//  File.swift
//  
//
//  Created by BJ Beecher on 9/12/24.
//

import Foundation
import Combine
import CoreBluetooth

// Combine and concurrency wrapper
public final class BluetoothPeripheralService: NSObject {
    private var peripheralManager: CBPeripheralManager!
    
    private var cancellables = Set<AnyCancellable>()
    
    // continuations with associated actions
    private var didStartAdvertisingCallback: ((Error?) -> Void)?
    private var didAddServiceCallback: ((CBService, Error?) -> Void)?
    
    public let statePublisher = CurrentValueSubject<CBManagerState, Never>(.unknown)
    public let didSubscribePublisher = PassthroughSubject<(CBCentral, CBCharacteristic), Never>()
    public let didUnSubscribePublisher = PassthroughSubject<(CBCentral, CBCharacteristic), Never>()
    public let didReceiveReadRequestPublisher = PassthroughSubject<CBATTRequest, Never>()
    public let didReceiveWriteRequestsPublisher = PassthroughSubject<[CBATTRequest], Never>()
    public let isReadyToUpdateSubscribersPublisher = PassthroughSubject<Void, Never>()
    
    public var isAdvertising: Bool {
        peripheralManager.isAdvertising
    }
    
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
            
            self.peripheralManager = CBPeripheralManager(delegate: self, queue: .global())
        }
    }
    
    public func startAdvertising(_ advertisementData: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<Void, Error>) in
            self?.didStartAdvertisingCallback = { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            
            self?.peripheralManager.startAdvertising(advertisementData)
        }
        
        self.didStartAdvertisingCallback = nil
    }
    
    public func stopAdvertising() {
        peripheralManager.stopAdvertising()
    }
    
    @discardableResult
    public func addService(_ service: CBMutableService) async throws -> CBService {
        let service: CBService = try await withCheckedThrowingContinuation { [weak self] continuation in
            self?.didAddServiceCallback = { service, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: service)
                }
            }
            
            self?.peripheralManager.add(service)
        }
        
        self.didAddServiceCallback = nil
        return service
    }
    
    public func respond(to request: CBATTRequest, withResult result: CBATTError.Code) {
        peripheralManager.respond(to: request, withResult: result)
    }
    
    public func cleanup() {
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
    }
}

// MARK: Peripheral manager delegate methods

extension BluetoothPeripheralService: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        statePublisher.send(peripheral.state)
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        didAddServiceCallback?(service, error)
    }
    
    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        didStartAdvertisingCallback?(error)
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        didSubscribePublisher.send((central, characteristic))
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        didUnSubscribePublisher.send((central, characteristic))
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        didReceiveReadRequestPublisher.send(request)
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        didReceiveWriteRequestsPublisher.send(requests)
    }
    
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        isReadyToUpdateSubscribersPublisher.send(())
    }
}
