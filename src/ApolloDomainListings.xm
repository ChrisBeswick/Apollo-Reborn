#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloDomainListings.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Reddit domain listings — browse posts by source website, e.g.
//   old.reddit.com/domain/imgur.com
//   old.reddit.com/domain/youtube.com
//
// Apollo has no `PostsType.domain` case (it's a Swift enum baked into the
// closed-source binary, so we can't add one) and PostsViewController's link
// loader is pure Swift with no @objc selector to hook. But three facts make
// this cheap:
//
//   1. PostsViewController is listing-type-agnostic: render any feed by handing
//      it a PostsType.subreddit(name). The whole UI (cells, sort bar, jump bar,
//      pull-to-refresh, infinite scroll, media) comes for free.
//   2. The first (and, for a non-existent subreddit, every) page is fetched by
//      *name* via the ObjC-visible RDKClient -linksInSubredditWithName:… — which
//      internally just builds path "r/<name>/<sort>" and calls
//      -fullPostListingWithPath:…. The /domain/ endpoint is the identical shape.
//   3. The tweak already routes reddit URLs into Apollo's native subreddit feed
//      via ApolloRouteResolvedURLViaApolloScheme().
//
// Strategy: carry the domain through the subreddit pipeline behind an opaque,
// validation-safe token, then redirect the fetch at the RDKClient layer.
//
//   tap/open  reddit.com/domain/imgur.com
//     -> mint token "ardomain0" <-> "imgur.com"   (token registry)
//     -> open apollo://reddit.com/r/ardomain0      (Apollo's own router)
//     -> Apollo pushes PostsViewController(.subreddit("ardomain0"))
//     -> RDKClient -linksInSubredditWithName:@"ardomain0" …
//     -> WE redirect to -fullPostListingWithPath:@"domain/imgur.com" …
//     -> feed renders imgur.com posts; title hook shows "imgur.com"
//
// A token (vs. passing the bare domain as the name) deliberately sidesteps
// Apollo's subreddit-name validation — a real domain like "imgur.com" contains
// a dot, which is illegal in subreddit names. The token is plain lowercase
// alphanumerics that the /r/ router accepts verbatim.
//
// =============================================================================

// Redirect targets on RDKClient. `linksFromWebsite:` is RedditKit's purpose-built
// /domain/<website> listing primitive — a sibling of -linksInSubredditWithName:
// in the same Links category, so its completion block has the identical shape
// (NSArray<RDKLink*>*, RDKPagination*, NSError*) and we can forward Apollo's own
// block unchanged. `fullPostListingWithPath:` is the generic listing builder both
// of those funnel into; kept declared here as a drop-in fallback (path
// "domain/<x>") if a Hopper pass ever shows linksFromWebsite: doesn't hit /domain/.
// Declared on NSObject so we don't need RDKClient's full @interface here.
@interface NSObject (ApolloDomainListingsRDK)
- (id)linksFromWebsite:(id)website pagination:(id)pagination completion:(id)completion;
- (id)fullPostListingWithPath:(id)path parameters:(id)parameters pagination:(id)pagination completion:(id)completion;
@end

// =============================================================================
// MARK: - Token registry (domain <-> opaque subreddit-name slug)
// =============================================================================

static NSMutableDictionary<NSString *, NSString *> *sDomainForToken; // token  -> domain
static NSMutableDictionary<NSString *, NSString *> *sTokenForDomain; // domain -> token
static NSUInteger sTokenCounter;
static NSLock *sTokenLock;

// Normalize a domain to Reddit's canonical form for the /domain/ endpoint:
// lowercase, no scheme, no path/slashes. Subdomains are preserved on purpose —
// reddit treats domain/imgur.com and domain/i.imgur.com as distinct listings.
static NSString *ApolloDomainListingsNormalizeDomain(NSString *domain) {
    if (![domain isKindOfClass:[NSString class]]) return nil;
    NSString *d = [[domain stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (d.length == 0) return nil;

    // If a full URL slipped in, reduce it to its host.
    if ([d hasPrefix:@"http://"] || [d hasPrefix:@"https://"] || [d hasPrefix:@"apollo://"]) {
        NSURL *u = [NSURL URLWithString:d];
        if (u.host.length) d = [u.host lowercaseString];
    }

    // Strip any leading/trailing slashes and a trailing path, keep just the host.
    d = [d stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSRange slash = [d rangeOfString:@"/"];
    if (slash.location != NSNotFound) d = [d substringToIndex:slash.location];
    if (d.length == 0) return nil;
    return d;
}

// Stable token for a domain (re-used across taps in a session so the same
// domain doesn't leak unbounded tokens). The token is a clean lowercase
// alphanumeric slug that passes Apollo's subreddit-name validation.
static NSString *ApolloDomainListingsTokenForDomain(NSString *domain) {
    NSString *d = ApolloDomainListingsNormalizeDomain(domain);
    if (!d) return nil;

    [sTokenLock lock];
    NSString *token = sTokenForDomain[d];
    if (!token) {
        token = [NSString stringWithFormat:@"ardomain%lu", (unsigned long)sTokenCounter++];
        sTokenForDomain[d] = token;
        sDomainForToken[token] = d;
    }
    [sTokenLock unlock];
    return token;
}

// Domain backing a token, or nil if `token` was never minted by us. Only tokens
// we generated live in the map, so a real subreddit named "ardomain0" that the
// user happens to open is never misrouted.
static NSString *ApolloDomainListingsDomainForToken(NSString *token) {
    if (![token isKindOfClass:[NSString class]] || token.length == 0) return nil;
    [sTokenLock lock];
    NSString *d = sDomainForToken[token];
    [sTokenLock unlock];
    return d;
}

// =============================================================================
// MARK: - URL parsing + public open entry point
// =============================================================================

NSString *ApolloDomainListingsDomainFromURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;

    NSString *scheme = [url.scheme lowercaseString];
    if (!([scheme isEqualToString:@"apollo"] || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return nil;
    }

    NSString *host = [url.host lowercaseString];
    if (![host isKindOfClass:[NSString class]]) return nil;
    if (!([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])) return nil;

    // pathComponents for /domain/imgur.com -> ("/", "domain", "imgur.com")
    NSArray<NSString *> *parts = url.pathComponents;
    NSUInteger idx = [parts indexOfObject:@"domain"];
    if (idx == NSNotFound || idx + 1 >= parts.count) return nil;

    return ApolloDomainListingsNormalizeDomain(parts[idx + 1]);
}

void ApolloDomainListingsOpen(NSString *domain) {
    NSString *token = ApolloDomainListingsTokenForDomain(domain);
    if (!token) {
        ApolloLog(@"[DomainListings] Open ignored — empty/invalid domain: %@", domain);
        return;
    }

    // Route through Apollo's own subreddit feed. ApolloRouteResolvedURLViaApolloScheme
    // converts this to apollo://reddit.com/r/<token>/ and opens it via UIApplication,
    // which re-enters SceneDelegate -scene:openURLContexts: (not as a /domain/ URL,
    // so we don't loop) and lets Apollo push the PostsViewController for us.
    NSString *urlString = [NSString stringWithFormat:@"https://reddit.com/r/%@/", token];
    NSURL *url = [NSURL URLWithString:urlString];

    dispatch_block_t route = ^{
        ApolloLog(@"[DomainListings] Opening domain '%@' via token feed %@", ApolloDomainListingsDomainForToken(token), urlString);
        if (!ApolloRouteResolvedURLViaApolloScheme(url)) {
            ApolloLog(@"[DomainListings] Route failed for %@", url);
        }
    };
    if ([NSThread isMainThread]) route();
    else dispatch_async(dispatch_get_main_queue(), route);
}

// =============================================================================
// MARK: - API redirect: subreddit-name fetch -> /domain/ endpoint
// =============================================================================

%hook RDKClient

- (id)linksInSubredditWithName:(id)name category:(long long)category pagination:(id)pagination completion:(id)completion {
    NSString *domain = ApolloDomainListingsDomainForToken(name);
    if (domain) {
        // NOTE: `category` (the sort: hot/new/top/…) is dropped — linksFromWebsite:
        // has no sort variant, so v1 serves the default (hot) listing. To add sort,
        // swap to -fullPostListingWithPath:[@"domain/<x>" + confirmed suffix]…
        // once Apollo's RDKSubredditCategory raw integer values are verified.
        ApolloLog(@"[DomainListings] Redirect r/%@ (cat=%lld) -> /domain/%@", name, category, domain);
        return [self linksFromWebsite:domain pagination:pagination completion:completion];
    }
    return %orig;
}

- (id)linksInSubredditWithName:(id)name pagination:(id)pagination completion:(id)completion {
    NSString *domain = ApolloDomainListingsDomainForToken(name);
    if (domain) {
        ApolloLog(@"[DomainListings] Redirect r/%@ -> /domain/%@", name, domain);
        return [self linksFromWebsite:domain pagination:pagination completion:completion];
    }
    return %orig;
}

%end

// =============================================================================
// MARK: - Deep-link interception: reddit.com/domain/<x> -> token feed
// =============================================================================
//
// In-app taps on a domain link already reach Apollo's apollo:// scheme handler
// (ApolloShareLinks routes every reddit.com URL through
// ApolloRouteResolvedURLViaApolloScheme). External opens and universal links
// arrive here too. We translate /domain/<x> into our token feed and swallow the
// original so Apollo's router never sees the unrecognized /domain/ path.

%hook SceneDelegate

- (void)scene:(id)scene openURLContexts:(NSSet *)urlContexts {
    NSUInteger total = 0, handled = 0;
    for (id ctx in urlContexts) {
        NSURL *url = nil;
        if ([ctx respondsToSelector:@selector(URL)]) {
            url = ((NSURL *(*)(id, SEL))objc_msgSend)(ctx, @selector(URL));
        }
        if (![url isKindOfClass:[NSURL class]]) continue;
        total++;

        NSString *domain = ApolloDomainListingsDomainFromURL(url);
        if (domain) {
            ApolloDomainListingsOpen(domain);
            handled++;
        }
    }

    // Only swallow when every context was a domain URL we handled; otherwise let
    // Apollo process the rest normally.
    if (handled > 0 && handled == total) {
        ApolloLog(@"[DomainListings] Consumed %lu domain URL context(s)", (unsigned long)handled);
        return;
    }
    %orig;
}

- (void)scene:(id)scene continueUserActivity:(NSUserActivity *)userActivity {
    NSURL *web = nil;
    if ([userActivity isKindOfClass:[NSUserActivity class]]) web = userActivity.webpageURL;
    NSString *domain = ApolloDomainListingsDomainFromURL(web);
    if (domain) {
        ApolloLog(@"[DomainListings] Universal link -> domain '%@'", domain);
        ApolloDomainListingsOpen(domain);
        return;
    }
    %orig;
}

%end

%hook AppDelegate

- (BOOL)application:(id)application openURL:(NSURL *)url options:(id)options {
    NSString *domain = ApolloDomainListingsDomainFromURL(url);
    if (domain) {
        ApolloLog(@"[DomainListings] application:openURL: -> domain '%@'", domain);
        ApolloDomainListingsOpen(domain);
        return YES;
    }
    return %orig;
}

%end

// =============================================================================
// MARK: - Title polish: show the domain instead of the token slug
// =============================================================================

%hook PostsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @try {
        UIViewController *vc = (UIViewController *)self;
        NSString *title = vc.navigationItem.title.length ? vc.navigationItem.title : vc.title;
        NSString *domain = ApolloDomainListingsDomainForToken(title);
        if (domain) {
            vc.navigationItem.title = domain;
            vc.title = domain;
        }
    } @catch (__unused NSException *e) {}
}

%end

// =============================================================================
// MARK: - Discoverable entry: "domain:<x>" in the search bar
// =============================================================================
//
// Typing e.g. `domain:imgur.com` (or `domain/imgur.com`) into Apollo's search
// and hitting Search opens the domain feed. An explicit prefix avoids hijacking
// normal queries like "amazon.com deals". Everything else falls through to
// Apollo's real search via %orig.

%hook SearchViewController

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    @try {
        NSString *text = [searchBar respondsToSelector:@selector(text)] ? searchBar.text : nil;
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *lower = [trimmed lowercaseString];
        if ([lower hasPrefix:@"domain:"] || [lower hasPrefix:@"domain/"]) {
            NSString *domain = [trimmed substringFromIndex:7]; // after "domain:" / "domain/"
            if (ApolloDomainListingsNormalizeDomain(domain)) {
                ApolloLog(@"[DomainListings] Search entry -> domain '%@'", domain);
                ApolloDomainListingsOpen(domain);
                return; // swallow — don't also run a normal search
            }
        }
    } @catch (__unused NSException *e) {}
    %orig;
}

%end

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    sTokenLock = [[NSLock alloc] init];
    sDomainForToken = [NSMutableDictionary dictionary];
    sTokenForDomain = [NSMutableDictionary dictionary];

    Class sceneDelegate = objc_getClass("_TtC6Apollo13SceneDelegate");
    Class appDelegate = objc_getClass("_TtC6Apollo11AppDelegate");
    Class postsVC = objc_getClass("_TtC6Apollo19PostsViewController");
    Class searchVC = objc_getClass("_TtC6Apollo20SearchViewController");
    Class rdkClient = objc_getClass("RDKClient");

    ApolloLog(@"[DomainListings] ctor: SceneDelegate=%p AppDelegate=%p PostsVC=%p SearchVC=%p RDKClient=%p",
              (void *)sceneDelegate, (void *)appDelegate, (void *)postsVC, (void *)searchVC, (void *)rdkClient);

    if (!rdkClient) {
        ApolloLog(@"[DomainListings] ctor: FATAL — RDKClient class not found; domain feeds disabled");
        return;
    }

    %init(SceneDelegate = sceneDelegate,
          AppDelegate = appDelegate,
          PostsViewController = postsVC,
          SearchViewController = searchVC,
          RDKClient = rdkClient);
}
