//
//  DarwinPeripheral.swift
//  GATT
//
//  Created by Alsey Coleman Miller on 4/1/16.
//  Copyright © 2016 PureSwift. All rights reserved.
//

import SwiftFoundation
import Bluetooth

#if os(OSX) || os(iOS) || os(tvOS)
    
    import Foundation
    import CoreBluetooth
    
    /// The platform specific peripheral. 
    public typealias Server = DarwinPeripheral
    
    public final class DarwinPeripheral: NSObject, CBPeripheralManagerDelegate, PeripheralManager {
        
        // MARK: - Properties
        
        public var stateChanged: (CBPeripheralManagerState) -> () = { _ in }
        
        public var state: CBPeripheralManagerState {
            
            return internalManager.state
        }
        
        public let localName: String
        
        public var willRead: ((central: Central, UUID: Bluetooth.UUID, value: Data, offset: Int) -> ATT.Error?)?
        
        public var willWrite: ((central: Central, UUID: Bluetooth.UUID, value: Data, newValue: (newValue: Data, newBytes: Data, offset: Int)) -> ATT.Error?)?
        
        // MARK: - Private Properties
        
        private lazy var internalManager: CBPeripheralManager = CBPeripheralManager(delegate: self, queue: self.queue)
        
        private lazy var queue: dispatch_queue_t = dispatch_queue_create("\(self.dynamicType) Internal Queue", nil)
        
        private var addServiceState: (semaphore: dispatch_semaphore_t, error: NSError?)?
        
        private var startAdvertisingState: (semaphore: dispatch_semaphore_t, error: NSError?)?
        
        private var services = [CBMutableService]()
        
        private var characteristicValues = [[(characteristic: CBMutableCharacteristic, value: Data)]]()
        
        // MARK: - Initialization
        
        public init(localName: String = "GATT Server") {
            
            self.localName = localName
        }
        
        // MARK: - Methods
        
        public func start() throws {
            
            assert(startAdvertisingState == nil, "Already started advertising")
            
            let semaphore = dispatch_semaphore_create(0)
            
            startAdvertisingState = (semaphore, nil) // set semaphore
            
            internalManager.startAdvertising([CBAdvertisementDataLocalNameKey: localName])
            
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
            
            let error = startAdvertisingState?.error
            
            // clear
            startAdvertisingState = nil
            
            if let error = error {
                
                throw error
            }
        }
        
        public func stop() {
            
            internalManager.stopAdvertising()
        }
        
        public func add(service: Service) throws -> Int {
            
            assert(addServiceState == nil, "Already adding another Service")
            
            /// wait
            
            let semaphore = dispatch_semaphore_create(0)
            
            addServiceState = (semaphore, nil) // set semaphore
            
            // add service
            let coreService = service.toCoreBluetooth()
            internalManager.addService(coreService)
            
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
            
            let error = addServiceState?.error
            
            // clear
            addServiceState = nil
            
            if let error = error {
                
                throw error
            }
            
            services.append(coreService)
            
            var characteristics = [(characteristic: CBMutableCharacteristic, value: Data)]()
            
            for (index, characteristic) in ((coreService.characteristics ?? []) as! [CBMutableCharacteristic]).enumerate()  {
                
                let data = service.characteristics[index].value
                
                characteristics.append((characteristic, data))
            }
            
            characteristicValues.append(characteristics)
            
            return services.endIndex
        }
        
        public func remove(service index: Int) {
            
            internalManager.removeService(services[index])
            
            services.removeAtIndex(index)
            characteristicValues.removeAtIndex(index)
        }
        
        public func clear() {
            
            internalManager.removeAllServices()
            
            services = []
            characteristicValues = []
        }
        
        public func update(value: Data, forCharacteristic UUID: Bluetooth.UUID) {
            
            internalManager.updateValue(value.toFoundation(), forCharacteristic: characteristic(UUID), onSubscribedCentrals: nil)
        }
        
        // MARK: - CBPeripheralManagerDelegate
        
        public func peripheralManagerDidUpdateState(peripheral: CBPeripheralManager) {
            
            stateChanged(peripheral.state)
        }
        
        public func peripheralManagerDidStartAdvertising(peripheral: CBPeripheralManager, error: NSError?) {
            
            guard let semaphore = startAdvertisingState?.semaphore else { fatalError("Did not expect \(#function)") }
            
            startAdvertisingState?.error = error
            
            dispatch_semaphore_signal(semaphore)
        }
        
        public func peripheralManager(peripheral: CBPeripheralManager, didAddService service: CBService, error: NSError?) {
            
            guard let semaphore = addServiceState?.semaphore else { fatalError("Did not expect \(#function)") }
            
            addServiceState?.error = error
            
            dispatch_semaphore_signal(semaphore)
        }
        
        public func peripheralManager(peripheral: CBPeripheralManager, didReceiveReadRequest request: CBATTRequest) {
            
            let peer = Central(request.central)
            
            let value = self[request.characteristic].byteValue
            
            let UUID = Bluetooth.UUID(foundation: request.characteristic.UUID)
            
            guard request.offset <= value.count
                else { internalManager.respondToRequest(request, withResult: .InvalidOffset); return }
            
            if let error = willRead?(central: peer, UUID: UUID, value: Data(byteValue: value), offset: request.offset) {
                
                internalManager.respondToRequest(request, withResult: CBATTError(rawValue: Int(error.rawValue))!)
                return
            }
            
            let requestedValue = request.offset == 0 ? value : Array(value.suffixFrom(request.offset))
            
            request.value = Data(byteValue: requestedValue).toFoundation()
            
            internalManager.respondToRequest(request, withResult: .Success)
        }
        
        public func peripheralManager(peripheral: CBPeripheralManager, didReceiveWriteRequests requests: [CBATTRequest]) {
            
            assert(requests.isEmpty == false)
            
            var newValues = [Data](count: requests.count, repeatedValue: (Data()))
            
            // validate write requests
            for (index, request) in requests.enumerate() {
                
                let peer = Central(request.central)
                
                let value = self[request.characteristic]
                
                let UUID = Bluetooth.UUID(foundation: request.characteristic.UUID)
                
                let newBytes = Data(foundation: request.value ?? NSData())
                
                var newValue = value
                
                newValue.byteValue.replaceRange(request.offset ..< request.offset + newBytes.byteValue.count, with: newBytes.byteValue)
                
                if let error = willWrite?(central: peer, UUID: UUID, value: value, newValue: (newValue, newBytes, request.offset)) {
                    
                    internalManager.respondToRequest(requests[0], withResult: CBATTError(rawValue: Int(error.rawValue))!)
                    
                    return
                }
                
                // compute new data
                
                newValues[index] = newValue
            }
            
            // write new values
            for (index, request) in requests.enumerate() {
                
                let newValue = newValues[index]
                
                self[request.characteristic] = newValue
            }
            
            internalManager.respondToRequest(requests[0], withResult: .Success)
        }
        
        // MARK: - Private Methods
        
        /// Find the characteristic with the specified UUID.
        private func characteristic(UUID: Bluetooth.UUID) -> CBMutableCharacteristic {
            
            var foundCharacteristic: CBMutableCharacteristic!
            
            for service in services {
                
                for characteristic in (service.characteristics ?? []) as! [CBMutableCharacteristic] {
                    
                    guard UUID != Bluetooth.UUID(foundation: characteristic.UUID!)
                        else { foundCharacteristic = characteristic; break }
                }
            }
            
            guard foundCharacteristic != nil
                else { fatalError("No Characterstic with UUID \(UUID)") }
            
            return foundCharacteristic
        }
        
        private subscript(characteristic: CBCharacteristic) -> Data {
            
            get {
                
                for service in characteristicValues {
                    
                    for characteristicValue in service {
                        
                        if characteristicValue.characteristic === characteristic {
                            
                            return characteristicValue.value
                        }
                    }
                }
                
                fatalError("No stored characteristic matches \(characteristic)")
            }
            
            set {
                
                for (serviceIndex, service) in characteristicValues.enumerate() {
                    
                    for (characteristicIndex, characteristicValue) in service.enumerate() {
                        
                        if characteristicValue.characteristic === characteristic {
                            
                            characteristicValues[serviceIndex][characteristicIndex].value = newValue
                            return
                        }
                    }
                }
                
                fatalError("No stored characteristic matches \(characteristic)")
            }
        }
    }

#endif
