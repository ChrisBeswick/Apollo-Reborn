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
//   2. Every page is fetched by *name*, funnelling through RDKClient's generic
//      path-based listing builders with a path like "r/<name>/<sort>". The
//      /domain/ endpoint is the identical shape ("domain/<name>/<sort>").
//   3. The tweak already routes reddit URLs into Apollo's native subreddit feed
//      via ApolloRouteResolvedURLViaApolloScheme().
//
// Strategy: carry the domain straight through as the subreddit NAME (the domain
// IS the handle — see "Stateless domain handle" below), then rewrite the listing
// PATH at the RDKClient funnel.
//
//   tap/open  reddit.com/domain/imgur.com   (or search "domain:imgur.com")
//     -> open apollo://reddit.com/r/imgur.com       (Apollo's own router)
//     -> Apollo pushes PostsViewController(.subreddit("imgur.com"))
//     -> listing request builds path "r/imgur.com/<sort>"
//     -> WE rewrite the path -> "domain/imgur.com/<sort>" at the funnel
//     -> feed renders imgur.com posts; title hook shows "imgur.com"
//
// Why the domain as the name (vs. an opaque token): a real subreddit name is
// [A-Za-z0-9_] and can never contain a dot, so the dot is a stateless marker —
// no registry, no persistence. A favourite is then just the string "imgur.com"
// in Apollo's FavoriteSubreddits array, so it survives relaunch and reads
// correctly with zero extra state. (Requires Apollo's /r/ router to accept a
// dotted name verbatim, which it does — no name sanitisation strips the dot.)
//
// =============================================================================

// We redirect domain feeds by rewriting the listing PATH at RDKClient's generic
// funnel (see "API redirect" below) and only ever call the originals via %orig,
// so no RDKClient method declarations are needed here.

// =============================================================================
// MARK: - Stateless domain handle (the domain IS the subreddit name)
// =============================================================================
//
// We carry the domain straight through Apollo as the "subreddit name" — e.g.
// the feed for imgur.com is opened as r/imgur.com. Real subreddit names are
// [A-Za-z0-9_] and can never contain a dot, so the presence of a dot is a
// perfect, stateless marker: no token, no registry, no persistence. A favourite
// is then just the plain string "imgur.com" (Apollo stores FavoriteSubreddits as
// a string array), so it survives relaunch and reads correctly with zero extra
// state. The path rewrite below turns r/imgur.com -> domain/imgur.com.

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

// Treat a subreddit "name" as a domain handle iff it contains a dot. A trailing
// ".json" API suffix is stripped first so a real subreddit fetched as JSON
// ("pics.json") is never misread as a domain. Returns the normalized domain, or
// nil for an ordinary subreddit name.
static NSString *ApolloDomainListingsDomainFromName(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return nil;
    NSString *n = name;
    if ([[n lowercaseString] hasSuffix:@".json"]) n = [n substringToIndex:n.length - 5];
    if ([n rangeOfString:@"."].location == NSNotFound) return nil;
    return ApolloDomainListingsNormalizeDomain(n);
}

// A friendly display label for a domain: "imgur.com" -> "imgur",
// "i.imgur.com" -> "imgur", "bbc.co.uk" -> "bbc". Best-effort — takes the
// registrable label (the one before the public suffix), skipping a known set of
// second-level suffixes (co.uk, com.au, …). This is DISPLAY ONLY; the full domain
// remains the functional handle (favourites, routing, the /domain/ fetch).
static NSString *ApolloDomainListingsDisplayNameForDomain(NSString *domain) {
    NSString *d = ApolloDomainListingsNormalizeDomain(domain);
    if (!d) return domain;
    if ([d hasPrefix:@"www."]) d = [d substringFromIndex:4];

    NSArray<NSString *> *labels = [d componentsSeparatedByString:@"."];
    if (labels.count < 2) return d;

    static NSSet<NSString *> *secondLevel = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        secondLevel = [NSSet setWithArray:@[ @"co", @"com", @"org", @"net", @"gov", @"edu", @"ac", @"or", @"ne", @"gob" ]];
    });

    NSInteger idx = (NSInteger)labels.count - 2;                          // label before the final TLD
    if (idx > 0 && [secondLevel containsObject:labels[idx]]) idx -= 1;    // skip a co.uk-style suffix
    NSString *label = labels[idx];
    return label.length ? label : d;
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
    NSString *d = ApolloDomainListingsNormalizeDomain(domain);
    if (!d) {
        ApolloLog(@"[DomainListings] Open ignored — empty/invalid domain: %@", domain);
        return;
    }

    // Open the domain AS a subreddit named after it. ApolloRouteResolvedURLViaApolloScheme
    // converts this to apollo://reddit.com/r/<domain>/ and opens it via UIApplication,
    // which re-enters our SceneDelegate hook (not as a /domain/ URL, so we don't loop)
    // and lets Apollo push the PostsViewController. The path rewrite then turns the
    // resulting r/<domain> listing request into the /domain/<domain> endpoint.
    NSString *urlString = [NSString stringWithFormat:@"https://reddit.com/r/%@/", d];
    NSURL *url = [NSURL URLWithString:urlString];

    dispatch_block_t route = ^{
        ApolloLog(@"[DomainListings] Opening domain '%@' via %@", d, urlString);
        if (!ApolloRouteResolvedURLViaApolloScheme(url)) {
            ApolloLog(@"[DomainListings] Route failed for %@", url);
        }
    };
    if ([NSThread isMainThread]) route();
    else dispatch_async(dispatch_get_main_queue(), route);
}

// =============================================================================
// MARK: - API redirect: rewrite the listing PATH r/<domain> -> domain/<domain>
// =============================================================================
//
// Every typed links query (linksInSubredditWithName:category:…, its pagination
// follow-ups, etc.) funnels into RDKClient's generic path-based listing builders
// with a fully-formed path like "r/imgur.com/top" — and Apollo has already attached
// the sort suffix and any time-filter params (t=week, …). By rewriting only the
// path PREFIX at that funnel ("r/<domain>" -> "domain/<domain>") and forwarding the
// parameters/pagination/completion untouched, sorting, time-filtering AND
// pagination all work, with no dependency on RDKSubredditCategory's raw values.

// "r/<domain>[/<sort>][.json]" -> "domain/<domain>[/<sort>][.json]" when the name
// component is a domain (contains a dot). Only the "r" segment changes — the
// domain, the sort suffix and any ".json" are preserved verbatim. Returns the SAME
// object when there's nothing to rewrite, so callers detect a no-op via identity.
static NSString *ApolloDomainListingsRewriteListingPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return path;

    NSArray<NSString *> *comps = [path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i + 1 < comps.count; i++) {
        if (![comps[i] isEqualToString:@"r"]) continue;
        // The component after "r" carries the domain (with its dots). A real
        // subreddit name has no dot, so this never matches normal feeds.
        if (!ApolloDomainListingsDomainFromName(comps[i + 1])) continue;

        NSMutableArray<NSString *> *out = [comps mutableCopy];
        out[i] = @"domain";
        NSString *rewritten = [out componentsJoinedByString:@"/"];
        ApolloLog(@"[DomainListings] Path rewrite '%@' -> '%@'", path, rewritten);
        return rewritten;
    }
    return path;
}

%hook RDKClient

// Hook every listing funnel a subreddit feed might use; the rewrite is a no-op
// for non-token paths, and once one funnel rewrites the prefix the inner funnels
// see "domain/<x>" and pass through, so there's no double-rewrite.
- (id)fullPostListingWithPath:(id)path parameters:(id)parameters pagination:(id)pagination completion:(id)completion {
    NSString *rewritten = ApolloDomainListingsRewriteListingPath(path);
    if (rewritten != path) return %orig(rewritten, parameters, pagination, completion);
    return %orig;
}

- (id)postListingTaskWithPath:(id)path parameters:(id)parameters pagination:(id)pagination completion:(id)completion {
    NSString *rewritten = ApolloDomainListingsRewriteListingPath(path);
    if (rewritten != path) return %orig(rewritten, parameters, pagination, completion);
    return %orig;
}

- (id)listingTaskWithPath:(id)path parameters:(id)parameters pagination:(id)pagination completion:(id)completion {
    NSString *rewritten = ApolloDomainListingsRewriteListingPath(path);
    if (rewritten != path) return %orig(rewritten, parameters, pagination, completion);
    return %orig;
}

- (id)fullListingWithPath:(id)path parameters:(id)parameters pagination:(id)pagination completion:(id)completion {
    NSString *rewritten = ApolloDomainListingsRewriteListingPath(path);
    if (rewritten != path) return %orig(rewritten, parameters, pagination, completion);
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
// MARK: - Title polish: show "imgur.com" instead of "r/imgur.com"
// =============================================================================
//
// Apollo titles a subreddit feed with a custom nav-bar control
// (DualLabelTitleButton), NOT navigationItem.title — so rewriting the title
// string alone leaves the visible "r/imgur.com" untouched. We resolve the domain
// from whichever surface carries it (the title string OR a UILabel inside the
// title view) and rewrite them all to the bare domain: the title string (also
// read by the ApolloSubredditHeaders banner as a fallback) plus every matching
// UILabel in the title view. Re-applied on layout so it survives nav-bar relayout.

// Map a displayed string ("imgur.com", "r/imgur.com") to its domain, or nil.
static NSString *ApolloDomainListingsDomainForDisplayText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    NSString *candidate = text;
    if ([candidate hasPrefix:@"r/"] || [candidate hasPrefix:@"R/"]) candidate = [candidate substringFromIndex:2];
    return ApolloDomainListingsDomainFromName(candidate);
}

// Find the domain encoded in any UILabel within a view tree (e.g. the title view).
static NSString *ApolloDomainListingsDomainFromLabelTree(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *d = ApolloDomainListingsDomainForDisplayText(((UILabel *)view).text);
        if (d) return d;
    }
    for (UIView *sub in view.subviews) {
        NSString *d = ApolloDomainListingsDomainFromLabelTree(sub);
        if (d) return d;
    }
    return nil;
}

// Rewrite every token-bearing UILabel in a view tree to the domain. Self-guarding:
// once a label shows the domain (not a token), it no longer matches, so re-runs
// from layout passes don't loop.
static void ApolloDomainListingsRewriteTokenLabels(UIView *view, NSString *domain) {
    if (!view) return;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if (ApolloDomainListingsDomainForDisplayText(label.text)) label.text = domain;
    }
    for (UIView *sub in view.subviews) ApolloDomainListingsRewriteTokenLabels(sub, domain);
}

// Resolve this feed's domain (if it's a token feed) and fix every title surface.
// Idempotent; a no-op for normal subreddit feeds (no token → returns early).
static void ApolloDomainListingsFixDomainTitle(UIViewController *vc) {
    if (!vc) return;
    @try {
        UINavigationItem *navItem = vc.navigationItem;
        UIView *titleView = navItem.titleView;

        NSString *domain = ApolloDomainListingsDomainForDisplayText(navItem.title);
        if (!domain) domain = ApolloDomainListingsDomainForDisplayText(vc.title);
        if (!domain) domain = ApolloDomainListingsDomainFromLabelTree(titleView);
        if (!domain) return;

        // Show the friendly brand ("imgur"), not the raw "r/imgur.com".
        NSString *display = ApolloDomainListingsDisplayNameForDomain(domain);
        if (![navItem.title isEqualToString:display]) navItem.title = display;
        if (![vc.title isEqualToString:display]) vc.title = display;
        ApolloDomainListingsRewriteTokenLabels(titleView, display);
    } @catch (__unused NSException *e) {}
}

%hook PostsViewController

- (void)viewDidLoad {
    %orig;
    ApolloDomainListingsFixDomainTitle((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloDomainListingsFixDomainTitle((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDomainListingsFixDomainTitle((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDomainListingsFixDomainTitle((UIViewController *)self);
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
