// Standalone check of the Talent Cue timer (bash tests/talentcue/run.sh).
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: String) { if !ok { failures += 1; print("FAIL: \(msg)") } }

let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

// The user's example: 20 minutes — green the first 15, orange until 19, red the last minute
var t = TalentTimer(duration: 20 * 60, warnAt: 5 * 60, criticalAt: 60)
check(!t.running && t.remaining(at: at(500)) == 1200, "not started: full time, clock not running")
t.start(at: t0)
check(t.phase(at: at(0)) == .normal && t.phase(at: at(14 * 60 + 59)) == .normal, "green for the first 15 minutes")
check(t.phase(at: at(15 * 60)) == .warning && t.phase(at: at(18 * 60 + 59)) == .warning, "orange from 15 until 19 minutes")
check(t.phase(at: at(19 * 60)) == .critical && t.phase(at: at(19 * 60 + 59)) == .critical, "red in the last minute")
check(t.phase(at: at(20 * 60)) == .overtime && t.remaining(at: at(20 * 60 + 12)) == -12, "overtime after 20 minutes, counts on")

// pause keeps the time, start continues
t.pause(at: at(100))
check(!t.running && t.remaining(at: at(5000)) == 1100, "paused: time stands still")
t.start(at: at(200))
check(t.remaining(at: at(210)) == 1090, "resumed where it was paused")
t.add(seconds: 60)
check(t.remaining(at: at(210)) == 1150, "+1 minute")
t.add(seconds: -2000)
check(t.duration == 0, "can't go below zero length")
t.reset()
check(!t.running && t.remaining(at: at(9999)) == 0, "reset: stopped at full (zero) length")

// what the display shows: whole seconds, rounded up while counting down, minus sign in overtime
check(TalentTimer.format(1200) == "20:00", "20:00")
check(TalentTimer.format(0.2) == "0:01", "last fraction still shows 0:01")
check(TalentTimer.format(0) == "0:00", "0:00 at the end")
check(TalentTimer.format(-0.5) == "0:00", "first half second of overtime still 0:00")
check(TalentTimer.format(-75) == "-1:15", "overtime -1:15")
check(TalentTimer.format(3725) == "1:02:05", "hours")

// count-up timer: no colour phases, shows elapsed time
var up = TalentTimer(duration: 0, warnAt: 0, criticalAt: 0, countUp: true)
up.start(at: t0)
check(up.displaySeconds(at: at(65)) == 65 && up.phase(at: at(65)) == .normal, "count up shows elapsed time, stays normal")

// Moderator link access: only the Talent paths skip the HTTP password, and only with the right key
for p in ["/talent", "/talent/", "/talent.json", "/talent/cmd"] { check(TalentAccess.isTalentPath(p), "\(p) is a Talent path") }
for p in ["/api", "/", "/talentx", "/talent.jsonx", "/tally", "/remote.json"] { check(!TalentAccess.isTalentPath(p), "\(p) is NOT a Talent path") }
check(TalentAccess.keyMatches("abc123", token: "abc123"), "right key")
check(!TalentAccess.keyMatches("abc12", token: "abc123") && !TalentAccess.keyMatches(nil, token: "abc123")
      && !TalentAccess.keyMatches("", token: ""), "wrong, missing or empty key refused")
// a link clicked inside a web page (Gmail, Slack…) is a cross-site navigation: allowed for the page only
check(TalentAccess.allowsCrossSiteNavigation(path: "/talent", fetchMode: "navigate"), "page opened from a link elsewhere")
check(!TalentAccess.allowsCrossSiteNavigation(path: "/talent/cmd", fetchMode: "navigate"), "commands never cross-site")
check(!TalentAccess.allowsCrossSiteNavigation(path: "/talent", fetchMode: "cors"), "page fetched by another site's script: no")
check(!TalentAccess.allowsCrossSiteNavigation(path: "/api", fetchMode: "navigate"), "other paths: no")

if failures == 0 { print("talentcue: all checks passed") } else { print("talentcue: \(failures) failed"); exit(1) }
