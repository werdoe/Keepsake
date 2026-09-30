import Foundation

/// Login state for each platform, based on the session cookies saved in the shared app group.
enum Accounts {
    static func isLoggedIn(_ platform: Platform) -> Bool {
        !cookies(for: platform).filter { $0.name == platform.sessionCookieName && !$0.value.isEmpty }.isEmpty
    }

    static func cookies(for platform: Platform) -> [HTTPCookie] {
        (AppGroup.cookieStorage.cookies ?? []).filter { cookie in
            platform.cookieDomains.contains { cookie.domain.hasSuffix($0) }
        }
    }

    /// Saves cookies from a login web view.
    static func store(_ cookies: [HTTPCookie], for platform: Platform) {
        for cookie in cookies where platform.cookieDomains.contains(where: { cookie.domain.hasSuffix($0) }) {
            AppGroup.cookieStorage.setCookie(cookie)
        }
    }

    static func logOut(_ platform: Platform) {
        for cookie in cookies(for: platform) {
            AppGroup.cookieStorage.deleteCookie(cookie)
        }
    }

    /// Cookie header value for a platform, e.g. for CDN downloads that need the session.
    static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
