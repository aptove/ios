import Foundation
import CoreData

@objc(TransportEndpointEntity)
public class TransportEndpointEntity: NSManagedObject {

    convenience init(
        context: NSManagedObjectContext,
        endpointId: String,
        transport: String,
        url: String,
        priority: Int16 = 0
    ) {
        self.init(context: context)
        self.endpointId = endpointId
        self.transport = transport
        self.url = url
        self.priority = priority
        self.isActive = false
    }
}
