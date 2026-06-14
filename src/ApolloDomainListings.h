#import <Foundation/Foundation.h>

__BEGIN_DECLS

// Opens a Reddit domain listing (the equivalent of old.reddit.com/domain/<domain>)
// inside Apollo, reusing the native subreddit feed UI. `domain` is a bare host
// such as @"imgur.com"; a full URL is also accepted and reduced to its host.
// No-op when `domain` is empty/invalid. Safe to call from any thread — the
// actual navigation is marshalled to the main thread.
//
// Exposed so other modules (e.g. a post long-press "Posts from this domain"
// action in ApolloNativeActionMenus.xm) can originate a domain feed.
void ApolloDomainListingsOpen(NSString *domain);

// Extracts the domain from a Reddit "/domain/<x>" URL (apollo://, http, or https
// with a reddit.com host). Returns nil if `url` is not a domain-listing URL.
NSString *ApolloDomainListingsDomainFromURL(NSURL *url);

__END_DECLS
