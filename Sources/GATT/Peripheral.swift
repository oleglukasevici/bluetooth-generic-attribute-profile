//
//  Peripheral.swift
//  GATT
//
//  Created by Alsey Coleman Miller on 4/1/16.
//  Copyright © 2016 PureSwift. All rights reserved.
//

import Bluetooth
import SwiftFoundation

/// GATT Peripheral Manager Interface
public protocol PeripheralManager {
    
    /// Attempts to add the specified service to the GATT database.
    func add(service: Service) throws
    
    /// Removes the service with the specified UUID.
    func remove(service UUID: Bluetooth.UUID)
    
    /// Clears the local GATT database.
    func clearServices()
    
    /// Update the value if the characteristic with specified UUID.
    func update(value: Data, forCharacteristic UUID: Bluetooth.UUID)
}

// MARK: - Typealiases

public typealias Service = GATT.Service
public typealias Characteristic = GATT.Characteristic
public typealias Descriptor = GATT.Descriptor