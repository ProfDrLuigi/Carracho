import Foundation

/// Dragging a bookmark ONTO another bookmark moves it to that row's position.
///
/// Using the hovered row's full height (rather than only the second half of it)
/// makes moving the first bookmark down just as easy as moving the last one up.
/// The row centers are supplied in arranged-subview order, not view-coordinate order,
/// so the same rule works in flipped and unflipped AppKit layouts.
enum BookmarkReorderPolicy {
    static func destinationIndex(rowCenters: [CGFloat],
                                 dragging sourceIndex: Int,
                                 droppingAt y: CGFloat) -> Int? {
        guard rowCenters.indices.contains(sourceIndex), y.isFinite,
              rowCenters.allSatisfy(\.isFinite) else { return nil }
        let hoveredIndex = rowCenters.indices.min { left, right in
            abs(rowCenters[left] - y) < abs(rowCenters[right] - y)
        }
        guard let hoveredIndex, hoveredIndex != sourceIndex else { return nil }
        // The original hover index is also the correct Array.insert index after
        // removing the source, both for an upward and for a downward move.
        return hoveredIndex
    }
}
