//
//  Item.swift
//  TigreChat
//
//  Created by Jorgito on 7/6/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
