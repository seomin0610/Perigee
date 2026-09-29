#import "KS.h"

static NSUInteger KSMaxResults(void) { return MAX(1, KSNum(@"maxResults", 8)); }
static const double kKSArtistBoost = 1000;

@interface KSCandidate : NSObject
@property (nonatomic, copy) NSString *source, *koreanTitle, *latinTitle, *latinArtist;
@property (nonatomic, copy) NSArray<NSString *> *artistNames, *isrcs;
@property (nonatomic) double score;
@end
@implementation KSCandidate
@end

@interface KSHit : NSObject
@property (nonatomic) NSDictionary *track;
@property (nonatomic, copy) NSString *koreanTitle;
@property (nonatomic) BOOL exact, artistMatch;
@end
@implementation KSHit
@end

static KSCandidate *KSCand(NSString *source, NSString *korean, NSString *latinTitle, NSString *latinArtist, NSArray *names, NSArray *isrcs, double score) {
	KSCandidate *c = [KSCandidate new];
	c.source = source;
	c.koreanTitle = korean;
	c.latinTitle = latinTitle;
	c.latinArtist = latinArtist;
	c.artistNames = names;
	c.isrcs = isrcs;
	c.score = score;
	return c;
}

#pragma mark - Network

static NSURLSession *KSSession(void) {
	static NSURLSession *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration]; });
	return s;
}

static NSData *KSLoad(NSMutableURLRequest *r) {
	[NSURLProtocol setProperty:@YES forKey:kKSHandled inRequest:r];
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block NSData *data;
	[[KSSession() dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
		NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
		if (status >= 200 && status < 300) data = d;
		else KSLog(@"%@ %@: %ld %@", r.HTTPMethod, r.URL.host, (long)status, e.localizedDescription ?: @"");
		dispatch_semaphore_signal(done);
	}] resume];
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
	return data;
}

static id KSJSON(NSData *d) { return d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil; }

static NSString *KSEnc(NSString *s) {
	static NSCharacterSet *allowed;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"]; });
	return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static id KSGetJSON(NSString *url) {
	NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:15];
	[r setValue:@"TidalKoreanSearch/1.0 ( https://github.com/seomin0610 )" forHTTPHeaderField:@"User-Agent"]; // MusicBrainz wants one
	return KSJSON(KSLoad(r));
}

static void KSMapLimit(NSArray *items, long limit, void (^fn)(id item)) {
	dispatch_semaphore_t slots = dispatch_semaphore_create(limit);
	dispatch_group_t group = dispatch_group_create();
	for (id item in items) {
		dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
		dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			fn(item);
			dispatch_semaphore_signal(slots);
		});
	}
	dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

#pragma mark - TIDAL (TIDAL's own search request, other query)

static NSMutableURLRequest *KSTidalRequest(NSURLRequest *search, NSURL *url) {
	NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:15];
	r.allHTTPHeaderFields = search.allHTTPHeaderFields;
	return r;
}

static NSString *KSCountry(NSURLRequest *search) {
	for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:search.URL resolvingAgainstBaseURL:NO].queryItems)
		if ([q.name isEqualToString:@"countryCode"]) return q.value;
	return @"US";
}

static NSArray<NSDictionary *> *KSTidalSearch(NSURLRequest *search, NSString *query, NSInteger limit) {
	NSURLComponents *c = [NSURLComponents componentsWithURL:search.URL resolvingAgainstBaseURL:NO];
	NSMutableArray *items = [NSMutableArray array];
	for (NSURLQueryItem *q in c.queryItems)
		if (![@[ @"query", @"limit", @"offset", @"types" ] containsObject:q.name]) [items addObject:q];
	[items addObject:[NSURLQueryItem queryItemWithName:@"query" value:query]];
	[items addObject:[NSURLQueryItem queryItemWithName:@"limit" value:@(limit).stringValue]];
	[items addObject:[NSURLQueryItem queryItemWithName:@"types" value:@"TRACKS"]];
	c.queryItems = items;
	c.percentEncodedQuery = [c.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
	return KSArr(KSDict(KSDict(KSJSON(KSLoad(KSTidalRequest(search, c.URL))))[@"tracks"])[@"items"]);
}

// ponytail: first ISRC hit; luna's MediaItem.fromIsrc picks the best-quality one
static NSDictionary *KSTidalIsrc(NSURLRequest *search, NSString *isrc) {
	NSURLComponents *c = [NSURLComponents componentsWithString:@"https://openapi.tidal.com/v2/tracks"];
	c.queryItems = @[ [NSURLQueryItem queryItemWithName:@"countryCode" value:KSCountry(search)], [NSURLQueryItem queryItemWithName:@"filter[isrc]" value:isrc] ];
	NSMutableURLRequest *r = KSTidalRequest(search, c.URL);
	[r setValue:@"application/vnd.api+json" forHTTPHeaderField:@"Accept"];
	NSString *trackId = [KSDict(KSArr(KSDict(KSJSON(KSLoad(r)))[@"data"]).firstObject)[@"id"] description];
	if (!trackId) return nil;
	NSURLComponents *t = [NSURLComponents componentsWithString:[@"https://api.tidal.com/v1/tracks/" stringByAppendingString:trackId]];
	t.queryItems = @[ [NSURLQueryItem queryItemWithName:@"countryCode" value:KSCountry(search)] ];
	NSDictionary *track = KSDict(KSJSON(KSLoad(KSTidalRequest(search, t.URL))));
	return track[@"id"] ? track : nil;
}

#pragma mark - Apple Music

// The ko store's /search returns no songs at all (any query: 200 OK, videos only), so it goes the other
// way round: search the US store (its index finds Hangul queries too) and look the ids up in ko for the
// Hangul title. Same as the plugin's resolve.ts; test/itunes.live.test.ts there guards the contract.
static NSArray<KSCandidate *> *KSItunesCandidates(NSString *phrase) {
	NSMutableArray *international = [NSMutableArray array];
	for (NSDictionary *t in KSArr(KSDict(KSGetJSON([NSString stringWithFormat:@"https://itunes.apple.com/search?term=%@&country=US&media=music&entity=song&limit=15", KSEnc(phrase)]))[@"results"]))
		if (KSDict(t)[@"trackId"]) [international addObject:t];
	if (!international.count) return @[];

	NSString *ids = [[international valueForKey:@"trackId"] componentsJoinedByString:@","];
	NSMutableDictionary *korean = [NSMutableDictionary dictionary];
	for (NSDictionary *t in KSArr(KSDict(KSGetJSON([NSString stringWithFormat:@"https://itunes.apple.com/lookup?id=%@&country=KR", ids]))[@"results"]))
		if (KSDict(t)[@"trackId"]) korean[t[@"trackId"]] = t;

	NSMutableArray *out = [NSMutableArray array];
	[international enumerateObjectsUsingBlock:^(NSDictionary *intl, NSUInteger index, BOOL *stop) {
		NSDictionary *track = korean[intl[@"trackId"]];
		NSString *latinTitle = KSIsLatin(KSStr(intl[@"trackName"])) ? intl[@"trackName"] : nil;
		if (!latinTitle || !KSStr(track[@"trackName"]).length) return;
		NSString *latinArtist = KSIsLatin(KSStr(intl[@"artistName"])) ? intl[@"artistName"] : KSIsLatin(KSStr(track[@"artistName"])) ? track[@"artistName"] : nil;
		NSMutableArray *names = [NSMutableArray array];
		if (KSStr(track[@"artistName"])) [names addObject:track[@"artistName"]];
		if (KSStr(intl[@"artistName"])) [names addObject:intl[@"artistName"]];
		[out addObject:KSCand(@"itunes", track[@"trackName"], latinTitle, latinArtist, names, @[], 100 - (double)index)];
	}];
	return out;
}

#pragma mark - MusicBrainz

static NSArray<KSCandidate *> *KSMbCandidates(NSString *phrase, NSMutableDictionary *hints) {
	NSString *query = [NSString stringWithFormat:@"https://musicbrainz.org/ws/2/recording?query=%@&fmt=json&limit=25", KSEnc(phrase)];
	NSArray *recordings = KSArr(KSDict(KSGetJSON([query stringByAppendingString:@"&dismax=true"]) ?: KSGetJSON(query))[@"recordings"]);

	for (NSDictionary *recording in recordings)
		for (NSArray *hint in KSMbArtistHints(KSDict(recording)))
			if (!hints[KSNormKo(hint[0])]) hints[KSNormKo(hint[0])] = hint[1];

	double best = [KSDict(recordings.firstObject)[@"score"] doubleValue];
	NSString *koreanPart = KSKoreanPartOf(phrase);
	NSMutableArray *out = [NSMutableArray array];
	for (NSDictionary *recording in recordings) {
		double score = [KSDict(recording)[@"score"] doubleValue];
		if (score < MAX(60, best - 20)) continue;
		NSString *korean = KSStr(recording[@"title"]) ?: phrase;
		NSArray *isrcs = KSArr(recording[@"isrcs"]);
		NSString *latinTitle = KSMbLatinTitle(recording);
		if ((!isrcs.count && !latinTitle) || !KSRelatedToKoreanQuery(koreanPart, korean)) continue;
		[out addObject:KSCand(@"musicbrainz", korean, latinTitle, KSMbLatinArtist(recording), KSMbArtistNames(recording), isrcs, score)];
	}
	return out;
}

#pragma mark - KOMCA

static NSArray<NSDictionary *> *KSKomcaSearch(NSString *title, NSString *artist) {
	title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
	if (!title.length) return @[];
	NSArray *fields = @[
		@[ @"S_PAGENUMBER", @"1" ], @[ @"PAGE_INIT", @"1" ], @[ @"SLCT_SORT_FLDS", @"basic" ], @[ @"S_HNAB_GBN", @"I" ],
		@[ @"S_PROD_TTL", title.uppercaseString ], @[ @"S_PROD_TTL_GB", @"3" ],
		@[ @"S_SINA_NM", [artist ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].uppercaseString ],
		@[ @"S_DISCTITLE_NM", @"" ], @[ @"S_RIGHTPRES_NM", @"" ], @[ @"S_RIGHTPRES_CD", @"" ], @[ @"S_RIGHTPRES_GB", @"1" ],
		@[ @"S_SECT_CD", @"" ], @[ @"S_LIB_YN", @"N" ], @[ @"S_START_DAY", @"" ], @[ @"S_END_DAY", @"" ],
	];
	NSMutableArray *pairs = [NSMutableArray array];
	for (NSArray *f in fields) [pairs addObject:[NSString stringWithFormat:@"%@=%@", f[0], KSEnc(f[1])]];

	NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.komca.or.kr/srch2/srch_01.jsp"] cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:12];
	r.HTTPMethod = @"POST";
	[r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	r.HTTPBody = [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
	NSData *d = KSLoad(r);
	NSString *html = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:d encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_KR)] : nil;
	return html ? KSKomcaParse(html) : @[];
}

static NSArray<KSCandidate *> *KSKomcaToCandidates(NSDictionary *work, NSString *searchedTitle, NSDictionary *hints) {
	NSString *searched = KSNormKo(searchedTitle), *title = KSNormKo(work[@"title"]);
	double base = [title isEqualToString:searched] ? 100 : [title hasPrefix:searched] ? 85 : 70;
	NSString *latinArtist;
	for (NSString *a in work[@"artists"])
		if (KSIsLatin(a)) { latinArtist = a; break; }
	if (!latinArtist)
		for (NSString *a in work[@"artists"])
			if ((latinArtist = hints[KSNormKo(a)])) break;
	NSArray *names = latinArtist ? [work[@"artists"] arrayByAddingObject:latinArtist] : work[@"artists"];

	NSMutableArray *out = [NSMutableArray array];
	for (NSString *alt in work[@"altTitles"])
		if (KSIsLatin(alt)) [out addObject:KSCand(@"komca", work[@"title"], alt, latinArtist, names, @[], base - out.count)];
	return out;
}

static NSArray<NSArray<NSString *> *> *KSKomcaSplits(NSString *phrase) {
	NSArray *words = KSWords(phrase);
	NSMutableArray *splits = [NSMutableArray arrayWithObject:@[ phrase ]];
	if (words.count < 2) return splits;
	NSMutableArray *latin = [NSMutableArray array], *korean = [NSMutableArray array];
	for (NSString *w in words) [KSHasHangul(w) ? korean : latin addObject:w];
	if (latin.count && korean.count) [splits addObject:@[ [korean componentsJoinedByString:@" "], [latin componentsJoinedByString:@" "] ]];
	else {
		[splits addObject:@[ [[words subarrayWithRange:NSMakeRange(1, words.count - 1)] componentsJoinedByString:@" "], words.firstObject ]];
		[splits addObject:@[ [[words subarrayWithRange:NSMakeRange(0, words.count - 1)] componentsJoinedByString:@" "], words.lastObject ]];
	}
	return splits;
}

static NSArray<KSCandidate *> *KSKomcaCandidates(NSString *phrase, NSDictionary *hints) {
	for (NSArray *split in KSKomcaSplits(phrase)) {
		NSString *title = split[0], *artist = split.count > 1 ? split[1] : nil;
		NSArray *works = @[];
		if (artist) works = KSKomcaSearch(title, artist);
		if (!works.count) {
			works = KSKomcaSearch(title, nil);
			if (artist) works = [works filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *w, NSDictionary *_) { return KSQueryMentionsArtist(artist, w[@"artists"]); }]];
		}
		if (works.count) {
			NSMutableArray *out = [NSMutableArray array];
			for (NSDictionary *w in works) [out addObjectsFromArray:KSKomcaToCandidates(w, title, hints)];
			return out;
		}
	}
	return @[];
}

#pragma mark - Candidates -> TIDAL tracks

static NSUInteger KSRank(KSHit *h) { return (h.artistMatch ? 2 : 0) + (h.exact ? 1 : 0); }

static void KSAdd(NSMutableArray<KSHit *> *resolved, NSDictionary *track, KSCandidate *c, BOOL exact) {
	if (!track[@"id"] || track[@"id"] == NSNull.null) return;
	// ISRC lookups ignore the region: an unplayable row is worse than none
	if ([track[@"allowStreaming"] isEqual:@NO]) return;
	KSHit *next = [KSHit new];
	next.track = track;
	next.koreanTitle = c.koreanTitle;
	next.exact = exact;
	next.artistMatch = c.score >= kKSArtistBoost;
	NSString *key = [track[@"id"] description];
	@synchronized(resolved) {
		NSUInteger i = [resolved indexOfObjectPassingTest:^BOOL(KSHit *h, NSUInteger idx, BOOL *stop) { return [[h.track[@"id"] description] isEqualToString:key]; }];
		if (i == NSNotFound) [resolved addObject:next];
		else if (KSRank(resolved[i]) < KSRank(next)) resolved[i] = next;
	}
}

static BOOL KSAny(NSMutableArray<KSHit *> *resolved, BOOL (^test)(KSHit *h)) {
	@synchronized(resolved) {
		for (KSHit *h in resolved)
			if (test(h)) return YES;
		return NO;
	}
}

static void KSCollect(NSMutableArray<KSHit *> *resolved, NSString *phrase, NSArray<KSCandidate *> *candidates, NSURLRequest *search) {
	if (!candidates.count) return;
	for (KSCandidate *c in candidates)
		if (KSQueryMentionsArtist(phrase, c.artistNames)) c.score += kKSArtistBoost;
	candidates = [candidates sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(KSCandidate *a, KSCandidate *b) {
		return a.score > b.score ? NSOrderedAscending : a.score < b.score ? NSOrderedDescending : NSOrderedSame;
	}];
	BOOL wantsArtist = [candidates.firstObject score] >= kKSArtistBoost;
	BOOL (^needsMore)(void) = ^BOOL {
		return resolved.count < KSMaxResults() || (wantsArtist && !KSAny(resolved, ^BOOL(KSHit *h) { return h.artistMatch; }));
	};

	NSMutableArray *isrcJobs = [NSMutableArray array];
	for (KSCandidate *c in candidates)
		for (NSString *isrc in c.isrcs)
			if (isrcJobs.count < 15) [isrcJobs addObject:@[ isrc, c ]];
	KSMapLimit(isrcJobs, 4, ^(NSArray *job) { KSAdd(resolved, KSTidalIsrc(search, job[0]), job[1], YES); });

	if (needsMore()) {
		NSMutableArray *textJobs = [NSMutableArray array];
		NSMutableSet *seen = [NSMutableSet set];
		for (KSCandidate *c in candidates) {
			if (!c.latinTitle) continue;
			NSString *query = c.latinArtist.length ? [NSString stringWithFormat:@"%@ %@", c.latinTitle, c.latinArtist] : c.latinTitle;
			if ([seen containsObject:KSNorm(query)]) continue;
			[seen addObject:KSNorm(query)];
			[textJobs addObject:@[ query, c ]];
			if (textJobs.count >= 6) break;
		}
		KSMapLimit(textJobs, 3, ^(NSArray *job) {
			KSCandidate *c = job[1];
			for (NSDictionary *track in KSTidalSearch(search, job[0], 10))
				if (KSTitleMatches(KSStr(KSDict(track)[@"title"]), c.latinTitle)) KSAdd(resolved, track, c, NO);
		});
	}

	if (needsMore()) {
		NSMutableArray<NSMutableArray<KSCandidate *> *> *groups = [NSMutableArray array];
		NSMutableDictionary *byArtist = [NSMutableDictionary dictionary];
		for (KSCandidate *c in candidates) {
			if (!c.latinArtist) continue;
			NSMutableArray *group = byArtist[c.latinArtist.lowercaseString];
			if (!group) [groups addObject:byArtist[c.latinArtist.lowercaseString] = group = [NSMutableArray array]];
			[group addObject:c];
		}
		KSMapLimit([groups subarrayWithRange:NSMakeRange(0, MIN(groups.count, 3))], 3, ^(NSArray<KSCandidate *> *group) {
			for (NSDictionary *track in KSTidalSearch(search, group[0].latinArtist, 50)) {
				NSString *title = KSStr(KSDict(track)[@"title"]);
				for (KSCandidate *c in group)
					if (KSKoreanTitleMatches(title, c.koreanTitle) || KSTitleMatches(title, c.latinTitle)) {
						KSAdd(resolved, track, c, NO);
						break;
					}
			}
		});
	}
}

static NSDictionary *KSMarked(NSDictionary *track, NSString *koreanTitle) {
	NSString *mark = koreanTitle.length && !KSKoreanTitleMatches(KSStr(track[@"title"]), koreanTitle) ? koreanTitle : @"한국어 검색";
	NSString *version = KSStr(track[@"version"]);
	NSMutableDictionary *marked = [track mutableCopy];
	marked[@"version"] = version.length ? [NSString stringWithFormat:@"%@ · %@", version, mark] : mark;
	return marked;
}

NSArray<NSDictionary *> *KSResolve(NSString *phrase, NSURLRequest *search) {
	NSMutableArray<KSHit *> *resolved = [NSMutableArray array];
	NSString *koreanQuery = KSKoreanPartOf(phrase);

	if (KSBool(@"itunes", YES)) {
		NSArray *itunes = [KSItunesCandidates(phrase) filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(KSCandidate *c, NSDictionary *_) {
			return KSRelatedToKoreanQuery(koreanQuery, c.koreanTitle);
		}]];
		KSCollect(resolved, phrase, itunes, search);
	}

	NSMutableDictionary *hints = [NSMutableDictionary dictionary];
	if (KSBool(@"musicbrainz", YES)) KSCollect(resolved, phrase, KSMbCandidates(phrase, hints), search);

	BOOL missedArtist = KSWords(phrase).count > 1 && !KSAny(resolved, ^BOOL(KSHit *h) { return h.artistMatch; });
	BOOL missedTitle = koreanQuery.length && !KSAny(resolved, ^BOOL(KSHit *h) { return KSKoreanTitleMatches(koreanQuery, h.koreanTitle); });
	if (KSBool(@"komca", YES) && (!resolved.count || missedArtist || missedTitle)) KSCollect(resolved, phrase, KSKomcaCandidates(phrase, hints), search);

	NSArray *sorted = [resolved sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(KSHit *a, KSHit *b) {
		if (a.artistMatch != b.artistMatch) return a.artistMatch ? NSOrderedAscending : NSOrderedDescending;
		double pa = [KSDict(a.track)[@"popularity"] doubleValue], pb = [KSDict(b.track)[@"popularity"] doubleValue];
		if (pa != pb) return pa > pb ? NSOrderedAscending : NSOrderedDescending;
		if (a.exact != b.exact) return a.exact ? NSOrderedAscending : NSOrderedDescending;
		return NSOrderedSame;
	}];
	NSMutableArray *tracks = [NSMutableArray array], *log = [NSMutableArray array];
	for (KSHit *h in [sorted subarrayWithRange:NSMakeRange(0, MIN(sorted.count, KSMaxResults()))]) {
		[tracks addObject:KSMarked(h.track, h.koreanTitle)];
		[log addObject:[NSString stringWithFormat:@"%@=%@", h.koreanTitle, h.track[@"title"]]];
	}
	KSLog(@"%@ -> %@", phrase, log.count ? [log componentsJoinedByString:@", "] : @"none");
	return tracks;
}
