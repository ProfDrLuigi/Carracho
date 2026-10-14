import AppKit

@main
struct BookmarkReorderRegression {
    static func main() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            stack.widthAnchor.constraint(equalToConstant: 220),
        ])
        for i in 0..<4 {
            let row = NSView()
            row.identifier = NSUserInterfaceItemIdentifier("bookmark-\(i)")
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 32).isActive = true
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.contentView!.layoutSubtreeIfNeeded()
        let rows = stack.arrangedSubviews
        let centers = rows.map { $0.frame.midY }
        precondition(centers.count == 4 && centers.allSatisfy(\.isFinite))
        let name = ["Alpha", "Beta", "Gamma", "Delta"]
        var checks = 0

        func check(source: Int, target: Int, y: CGFloat, expected: [String], label: String) {
            guard let destination = BookmarkReorderPolicy.destinationIndex(
                rowCenters: centers, dragging: source, droppingAt: y
            ) else {
                fatalError("\(label): expected reorder, got nil")
            }
            precondition(destination == target, "\(label): inserted at \(destination) instead of \(target)")
            var reordered = name
            let moving = reordered.remove(at: source)
            reordered.insert(moving, at: destination)
            precondition(reordered == expected, "\(label): got \(reordered)")
            // Bookmarks persist in array order via the existing UserDefaults JSON path.
            let restored = try! JSONDecoder().decode([String].self, from: JSONEncoder().encode(reordered))
            precondition(restored == expected, "\(label): persisted order wrong")
            checks += 1
            print("PASS: \(label)")
        }

        // AppKit's native stack is unflipped, so the upper half of a lower row is
        // numerically ABOVE its center. This used to be a no-op for downward moves.
        precondition(!stack.isFlipped && centers[0] > centers[1])
        check(source: 0, target: 1, y: rows[1].frame.maxY - 4,
              expected: ["Beta", "Alpha", "Gamma", "Delta"], label: "first bookmark down onto top half of next row")
        check(source: 0, target: 1, y: rows[1].frame.minY + 4,
              expected: ["Beta", "Alpha", "Gamma", "Delta"], label: "first bookmark down onto bottom half of next row")
        check(source: 0, target: 3, y: centers[3],
              expected: ["Beta", "Gamma", "Delta", "Alpha"], label: "first bookmark all the way to bottom")
        check(source: 1, target: 3, y: centers[3],
              expected: ["Alpha", "Gamma", "Delta", "Beta"], label: "middle bookmark moved down multiple positions")
        check(source: 3, target: 0, y: centers[0],
              expected: ["Delta", "Alpha", "Beta", "Gamma"], label: "last bookmark all the way to top")
        check(source: 3, target: 2, y: rows[2].frame.maxY - 4,
              expected: ["Alpha", "Beta", "Delta", "Gamma"], label: "last bookmark up onto top half of previous row")
        check(source: 2, target: 1, y: rows[1].frame.minY + 4,
              expected: ["Alpha", "Gamma", "Beta", "Delta"], label: "middle bookmark up onto bottom half of previous row")
        let flipped = centers.map { stack.bounds.height - $0 }
        precondition(BookmarkReorderPolicy.destinationIndex(rowCenters: flipped,
                        dragging: 0, droppingAt: flipped[3]) == 3)
        precondition(BookmarkReorderPolicy.destinationIndex(rowCenters: flipped,
                        dragging: 3, droppingAt: flipped[0]) == 0)
        print("PASS: flipped-coordinate row order works in both directions")
        precondition(BookmarkReorderPolicy.destinationIndex(rowCenters: centers,
                        dragging: 1, droppingAt: centers[1]) == nil)
        precondition(BookmarkReorderPolicy.destinationIndex(rowCenters: centers,
                        dragging: -1, droppingAt: centers[2]) == nil)
        precondition(BookmarkReorderPolicy.destinationIndex(rowCenters: centers,
                        dragging: 4, droppingAt: centers[2]) == nil)
        precondition(BookmarkReorderPolicy.destinationIndex(rowCenters: centers,
                        dragging: 1, droppingAt: .nan) == nil)
        precondition(BookmarkReorderPolicy.destinationIndex(rowCenters: [],
                        dragging: 0, droppingAt: 20) == nil)
        print("PASS: no-op, invalid source and invalid coordinate are rejected")
        print("PASS: \(checks + 2) Bookmark reorder scenarios")
    }
}
