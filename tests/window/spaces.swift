import Foundation
import CoreGraphics
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ c: Int32) -> CFArray
let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as! [[String: Any]]
for d in displays {
    let id = d["Display Identifier"] as? String ?? "?"
    let cur = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int ?? -1
    let spaces = d["Spaces"] as? [[String: Any]] ?? []
    print("display \(id.prefix(8)) current=\(cur)")
    for s in spaces {
        let t = s["type"] as? Int ?? -1      // 0 = desktop, 4 = full screen
        let sid = s["ManagedSpaceID"] as? Int ?? -1
        let tile = (s["TileLayoutManager"] as? [String: Any]).map { "\($0["TileSpaces"].map { _ in "tiles" } ?? "")" } ?? ""
        let owners = (s["fs_wid"] != nil) ? " fs_wid=\(s["fs_wid"]!)" : ""
        print("  space \(sid) type=\(t == 4 ? "FULLSCREEN" : (t == 0 ? "desktop" : "\(t)"))\(owners) \(tile)")
    }
}
