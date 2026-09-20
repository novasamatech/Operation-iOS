import Foundation
import CoreData

/**
 *  Sub-entity of ``CDFeed``, adding nothing of its own: the point is that its ``entity.name`` differs from
 *  its parent's while its instances are still ``CDFeed`` objects. That is the distinction observation has to
 *  follow, and the one an exact entity-name comparison gets wrong.
 *
 *  Declared by hand rather than pointing the model's ``representedClassName`` at ``CDFeed``: two entities
 *  claiming one class makes ``+[NSManagedObject entity]`` ambiguous, which breaks ``CDFeed(context:)``.
 */
@objc(CDVideoFeed)
public final class CDVideoFeed: CDFeed {}
