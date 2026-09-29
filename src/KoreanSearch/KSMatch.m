#import "KS.h"

static NSRegularExpression *KSRe(NSString *pattern) {
	static NSMutableDictionary<NSString *, NSRegularExpression *> *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
	@synchronized(cache) {
		NSRegularExpression *re = cache[pattern];
		if (!re) cache[pattern] = re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
		return re;
	}
}

static NSString *KSReplace(NSString *s, NSString *pattern, NSString *with) {
	return [KSRe(pattern) stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:with];
}

static NSString *KSGroup(NSString *s, NSString *pattern) {
	NSTextCheckingResult *m = [KSRe(pattern) firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
	return m && [m rangeAtIndex:1].location != NSNotFound ? [s substringWithRange:[m rangeAtIndex:1]] : nil;
}

static NSString *KSTrim(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }

#pragma mark - match.ts

BOOL KSHasHangul(NSString *s) {
	static NSCharacterSet *hangul;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableCharacterSet *set = [NSMutableCharacterSet characterSetWithRange:NSMakeRange(0x1100, 0x100)];
		[set addCharactersInRange:NSMakeRange(0x3130, 0x60)];
		[set addCharactersInRange:NSMakeRange(0xAC00, 0xD7A4 - 0xAC00)];
		hangul = set;
	});
	return s && [s rangeOfCharacterFromSet:hangul].location != NSNotFound;
}

BOOL KSIsLatin(NSString *s) {
	return KSStr(s).length && [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"]].location != NSNotFound && !KSHasHangul(s);
}

NSString *KSNorm(NSString *s) { return KSReplace(s.lowercaseString ?: @"", @"[^a-z0-9]+", @""); }

NSString *KSNormKo(NSString *s) { return KSReplace(s ?: @"", @"[\\s\\p{P}\\p{S}]+", @""); }

NSArray<NSString *> *KSWords(NSString *s) {
	return [[s ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
}

NSString *KSKoreanPartOf(NSString *phrase) {
	NSMutableArray *korean = [NSMutableArray array];
	for (NSString *w in KSWords(phrase))
		if (KSHasHangul(w)) [korean addObject:w];
	return [korean componentsJoinedByString:@" "];
}

static NSString *KSStripBrackets(NSString *s) { return KSReplace(s, @"[(\\[\\{][^)\\]\\}]*[)\\]\\}]", @" "); }

// Whole-title compare, not substring: "Invitation" must not hit "Invitation from Me"
BOOL KSTitleMatches(NSString *trackTitle, NSString *latinTitle) {
	if (!KSStr(trackTitle) || !KSStr(latinTitle)) return NO;
	NSString *a = KSNorm(KSStripBrackets(trackTitle)), *b = KSNorm(KSStripBrackets(latinTitle));
	return a.length && [a isEqualToString:b];
}

BOOL KSKoreanTitleMatches(NSString *trackTitle, NSString *koreanTitle) {
	if (!KSStr(trackTitle) || !KSStr(koreanTitle)) return NO;
	NSString *a = KSNormKo(KSStripBrackets(trackTitle)), *b = KSNormKo(KSStripBrackets(koreanTitle));
	return a.length && [a isEqualToString:b];
}

BOOL KSRelatedToKoreanQuery(NSString *koreanPart, NSString *koreanTitle) {
	NSString *query = KSNormKo(koreanPart);
	if (!query.length) return YES;
	NSString *title = KSNormKo(koreanTitle);
	return title.length && ([title containsString:query] || [query containsString:title]);
}

NSString *KSUnsortName(NSString *name) {
	NSArray *parts = [KSRe(@",\\s*") matchesInString:name options:0 range:NSMakeRange(0, name.length)];
	if (!parts.count) return name;
	NSRange first = [parts[0] range];
	NSString *last = [name substringToIndex:first.location];
	NSUInteger start = NSMaxRange(first), end = parts.count > 1 ? [parts[1] range].location : name.length;
	NSString *given = [name substringWithRange:NSMakeRange(start, end - start)];
	return given.length ? [NSString stringWithFormat:@"%@ %@", given, last] : name;
}

// Never the release title: 백예린 "우주를 건너" is on `FRANK EP`, which would send the TIDAL search nowhere.
NSString *KSMbLatinTitle(NSDictionary *recording) {
	if (KSIsLatin(KSStr(recording[@"title"]))) return recording[@"title"];
	for (NSDictionary *release in KSArr(recording[@"releases"]))
		for (NSDictionary *media in KSArr(KSDict(release)[@"media"]))
			for (NSDictionary *track in KSArr(KSDict(media)[@"track"]))
				if (KSIsLatin(KSStr(KSDict(track)[@"title"]))) return track[@"title"];
	return nil;
}

static NSString *KSLatinNameOf(NSDictionary *credit) {
	NSDictionary *artist = KSDict(credit[@"artist"]);
	if (KSIsLatin(KSStr(credit[@"name"]))) return credit[@"name"];
	if (KSIsLatin(KSStr(artist[@"name"]))) return artist[@"name"];
	NSArray *aliases = KSArr(artist[@"aliases"]);
	for (NSDictionary *alias in aliases)
		if (KSIsLatin(KSStr(KSDict(alias)[@"name"])) && [(KSStr(alias[@"locale"]) ?: @"").lowercaseString hasPrefix:@"en"]) return alias[@"name"];
	if (KSIsLatin(KSStr(artist[@"sort-name"]))) return KSUnsortName(artist[@"sort-name"]);
	for (NSDictionary *alias in aliases)
		if (KSIsLatin(KSStr(KSDict(alias)[@"name"]))) return alias[@"name"];
	return nil;
}

NSString *KSMbLatinArtist(NSDictionary *recording) {
	for (NSDictionary *credit in KSArr(recording[@"artist-credit"])) {
		NSString *latin = KSLatinNameOf(KSDict(credit));
		if (latin) return latin;
	}
	return nil;
}

static NSArray<NSString *> *KSCreditNames(NSDictionary *credit) {
	NSDictionary *artist = KSDict(credit[@"artist"]);
	NSMutableArray *names = [NSMutableArray array];
	for (id name in @[ credit[@"name"] ?: NSNull.null, artist[@"name"] ?: NSNull.null ])
		if (KSStr(name).length) [names addObject:name];
	for (NSDictionary *alias in KSArr(artist[@"aliases"]))
		if (KSStr(KSDict(alias)[@"name"]).length) [names addObject:alias[@"name"]];
	return names;
}

NSArray<NSString *> *KSMbArtistNames(NSDictionary *recording) {
	NSMutableArray *names = [NSMutableArray array];
	for (NSDictionary *credit in KSArr(recording[@"artist-credit"])) [names addObjectsFromArray:KSCreditNames(KSDict(credit))];
	return names;
}

NSArray<NSArray<NSString *> *> *KSMbArtistHints(NSDictionary *recording) {
	NSMutableArray *hints = [NSMutableArray array];
	for (NSDictionary *credit in KSArr(recording[@"artist-credit"])) {
		NSString *latin = KSLatinNameOf(KSDict(credit));
		if (!latin) continue;
		for (NSString *name in KSCreditNames(KSDict(credit)))
			if (KSHasHangul(name)) [hints addObject:@[ name, latin ]];
	}
	return hints;
}

BOOL KSQueryMentionsArtist(NSString *phrase, NSArray<NSString *> *names) {
	NSMutableArray *koWords = [NSMutableArray array], *latinWords = [NSMutableArray array];
	for (NSString *w in KSWords(phrase)) {
		if (KSNormKo(w).length >= 2) [koWords addObject:KSNormKo(w)];
		if (KSNorm(w).length >= 3) [latinWords addObject:KSNorm(w)]; // 2-letter Latin names hit anything
	}
	for (NSString *name in names) {
		BOOL korean = KSHasHangul(name);
		NSString *n = korean ? KSNormKo(name) : KSNorm(name);
		if (n.length < (korean ? 1 : 3)) continue;
		for (NSString *w in korean ? koWords : latinWords)
			if ([n containsString:w] || [w containsString:n]) return YES;
	}
	return NO;
}

#pragma mark - komca.native.ts parsing

static NSString *KSDecodeEntities(NSString *s) {
	NSArray *pairs = @[ @[ @"&nbsp;", @" " ], @[ @"&amp;", @"&" ], @[ @"&lt;", @"<" ], @[ @"&gt;", @">" ], @[ @"&quot;", @"\"" ], @[ @"&#39;", @"'" ] ];
	for (NSArray *p in pairs) s = [s stringByReplacingOccurrencesOfString:p[0] withString:p[1]];
	return s;
}

static NSString *KSClean(NSString *s) { return KSTrim(KSReplace(KSDecodeEntities(KSReplace(s, @"<[^>]*>", @" ")), @"\\s+", @" ")); }

static NSArray<NSString *> *KSSplitMulti(NSString *s) {
	NSMutableArray *out = [NSMutableArray array];
	for (NSString *part in [s componentsSeparatedByString:@"|^#"])
		if (KSClean(part).length) [out addObject:KSClean(part)];
	return out;
}

static NSArray<NSString *> *KSMultiField(NSString *block, NSString *fieldId, NSString *inlinePattern) {
	NSString *script = KSGroup(block, [NSString stringWithFormat:@"commaToTable\\('([^']*)','%@'", fieldId]);
	if (script.length) return KSSplitMulti(script);
	NSString *inlineValue = KSGroup(block, inlinePattern);
	if (!inlineValue) return @[];
	NSString *value = KSTrim(KSReplace(KSClean(inlineValue), @"외\\s*\\d+\\s*[개명]$", @""));
	return value.length ? @[ value ] : @[];
}

NSArray<NSDictionary *> *KSKomcaParse(NSString *html) {
	NSMutableArray *works = [NSMutableArray array];
	for (NSTextCheckingResult *m in [KSRe(@"<dl class=\"works_info\">([\\s\\S]*?)</dl>") matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
		NSString *block = [html substringWithRange:[m rangeAtIndex:1]];
		NSString *raw = KSGroup(block, @"<dt class=\"tit2\">([\\s\\S]*?)</dt>");
		NSString *title = raw ? KSTrim(KSReplace(KSReplace(KSClean(raw), @"^\\[[^\\]]*\\]\\s*", @""), @"\\s*-\\s*\\d+\\s*$", @"")) : @"";
		if (!title.length) continue;
		[works addObject:@{
			@"title": title,
			@"altTitles": KSMultiField(block, @"assttttl", @"<strong>부제목\\s*:</strong>([^<]*)"),
			@"artists": KSMultiField(block, @"sinaNm", @"\\[가수명\\s*:([^\\]<]*)"),
		}];
	}
	return works;
}

#pragma mark - Response

NSData *KSMerge(NSData *body, NSArray<NSDictionary *> *tracks) {
	if (!tracks.count || !body.length) return nil;
	NSMutableDictionary *doc = [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingMutableContainers error:nil];
	if (![doc isKindOfClass:NSMutableDictionary.class]) return nil;

	NSMutableSet *ids = [NSMutableSet set];
	for (NSDictionary *t in tracks)
		if ([KSDict(t)[@"id"] description]) [ids addObject:[t[@"id"] description]];
	BOOL (^ours)(id) = ^BOOL(id track) {
		NSString *i = [KSDict(track)[@"id"] description];
		return i && [ids containsObject:i];
	};

	NSMutableDictionary *section = [doc[@"tracks"] isKindOfClass:NSMutableDictionary.class] ? doc[@"tracks"] : nil;
	NSMutableArray *items = [section[@"items"] isKindOfClass:NSMutableArray.class] ? section[@"items"] : nil;
	if (items) {
		[items filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id t, NSDictionary *_) { return !ours(t); }]];
		[items insertObjects:tracks atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, tracks.count)]];
		NSNumber *total = [section[@"totalNumberOfItems"] isKindOfClass:NSNumber.class] ? section[@"totalNumberOfItems"] : @0;
		section[@"totalNumberOfItems"] = @(MAX(total.integerValue, (NSInteger)items.count));
	}

	NSMutableArray *hits = [doc[@"topHits"] isKindOfClass:NSMutableArray.class] ? doc[@"topHits"] : nil;
	if (hits) {
		[hits filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id h, NSDictionary *_) {
			return !([KSDict(h)[@"type"] isEqual:@"TRACKS"] && ours(KSDict(h)[@"value"]));
		}]];
		for (NSUInteger i = 0; i < MIN(tracks.count, 3); i++) [hits insertObject:@{ @"type": @"TRACKS", @"value": tracks[i] } atIndex:i];
	}

	return items || hits ? [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil] : nil;
}
