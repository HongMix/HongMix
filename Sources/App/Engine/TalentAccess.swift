import Foundation

/// Who may use the Talent Cue moderator link (TalentRemote). Kept free of app types so it is tested on its own
/// (tests/talentcue): these rules decide which requests skip the HTTP password.
enum TalentAccess {
    static func isTalentPath(_ path: String) -> Bool {
        path == "/talent" || path == "/talent/" || path == "/talent.json" || path == "/talent/cmd"
    }

    static func keyMatches(_ key: String?, token: String) -> Bool {
        guard let key, !key.isEmpty, !token.isEmpty else { return false }
        return key == token
    }

    /// The moderator page itself may be opened from a link inside another web page (Gmail, Slack, WhatsApp Web:
    /// the browser then sends Sec-Fetch-Site: cross-site). It changes nothing and still needs the key; the
    /// page's own calls (state, commands) stay same-origin only.
    static func allowsCrossSiteNavigation(path: String, fetchMode: String?) -> Bool {
        (path == "/talent" || path == "/talent/") && fetchMode == "navigate"
    }
}
