import Foundation
import CoreData

extension TransportEndpointEntity {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<TransportEndpointEntity> {
        return NSFetchRequest<TransportEndpointEntity>(entityName: "TransportEndpoint")
    }

    @NSManaged public var endpointId: String?
    @NSManaged public var transport: String?
    @NSManaged public var url: String?
    @NSManaged public var isActive: Bool
    @NSManaged public var lastConnectedAt: Date?
    @NSManaged public var priority: Int16
    @NSManaged public var agent: AgentEntity?
}
