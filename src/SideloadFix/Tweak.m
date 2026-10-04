// Re-signed TIDAL still asks for the old team's keychain/app group: every keychain call fails
// (errSecMissingEntitlement) and the login is lost on relaunch. Drop the access group, fake the app-group container.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <string.h>

static CFDictionaryRef SFNoGroup(CFDictionaryRef d) {
	if (!d || !CFDictionaryContainsKey(d, kSecAttrAccessGroup)) return d;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ NSLog(@"[TidalSideloadFix] keychain: dropping access group %@", CFDictionaryGetValue(d, kSecAttrAccessGroup)); });
	CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
	CFDictionaryRemoveValue(m, kSecAttrAccessGroup);
	return (CFDictionaryRef)CFAutorelease(m);
}

static OSStatus SFSecItemAdd(CFDictionaryRef q, CFTypeRef *r) { return SecItemAdd(SFNoGroup(q), r); }
static OSStatus SFSecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r) { return SecItemCopyMatching(SFNoGroup(q), r); }
static OSStatus SFSecItemUpdate(CFDictionaryRef q, CFDictionaryRef a) { return SecItemUpdate(SFNoGroup(q), SFNoGroup(a)); }
static OSStatus SFSecItemDelete(CFDictionaryRef q) { return SecItemDelete(SFNoGroup(q)); }

static void SFRebind(const struct mach_header *mh, intptr_t slide) {
	Dl_info me, info;
	if (!dladdr((void *)SFRebind, &me) || !dladdr(mh, &info) || info.dli_fbase == me.dli_fbase) return;
	if (!info.dli_fname || !strstr(info.dli_fname, ".app/")) return;

	void *from[] = { (void *)SecItemAdd, (void *)SecItemCopyMatching, (void *)SecItemUpdate, (void *)SecItemDelete };
	void *to[] = { (void *)SFSecItemAdd, (void *)SFSecItemCopyMatching, (void *)SFSecItemUpdate, (void *)SFSecItemDelete };

	const struct load_command *lc = (const void *)((const struct mach_header_64 *)mh + 1);
	for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
		if (lc->cmd != LC_SEGMENT_64) continue;
		const struct segment_command_64 *seg = (const void *)lc;
		if (strncmp(seg->segname, "__DATA", 6) && strncmp(seg->segname, "__AUTH", 6)) continue;
		BOOL readOnly = strstr(seg->segname, "_CONST") != NULL;
		const struct section_64 *sec = (const void *)(seg + 1);
		for (uint32_t j = 0; j < seg->nsects; j++) {
			uint32_t type = sec[j].flags & SECTION_TYPE;
			if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
			void **p = (void **)(sec[j].addr + slide);
			for (size_t k = 0; k < sec[j].size / sizeof(void *); k++)
				for (size_t m = 0; m < sizeof(from) / sizeof(*from); m++) {
					if (p[k] != from[m]) continue;
					vm_address_t page = (vm_address_t)&p[k] & ~(vm_address_t)(vm_page_size - 1);
					if (readOnly && vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) continue;
					p[k] = to[m];
					if (readOnly) vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ);
				}
		}
	}
}

static NSURL *(*orig_container)(NSFileManager *, SEL, NSString *);
static NSURL *hook_container(NSFileManager *self, SEL _cmd, NSString *group) {
	NSURL *url = orig_container(self, _cmd, group);
	if (url || !group.length) return url;
	url = [[self URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:[@"AppGroup/" stringByAppendingString:group] isDirectory:YES];
	[self createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
	static dispatch_once_t once;
	dispatch_once(&once, ^{ NSLog(@"[TidalSideloadFix] app group %@ not entitled, using %@", group, url.path); });
	return url;
}

typedef id (*SFAssetTaskIMP)(id, SEL, id, NSString *, NSData *, NSDictionary *);
static SFAssetTaskIMP orig_assetTask, orig_baseAssetTask;
static __thread BOOL gInLegacy;

static id SFLegacyAssetTask(id self, id asset, NSDictionary *options) {
	SEL legacy = NSSelectorFromString(@"assetDownloadTaskWithURLAsset:destinationURL:options:");
	if (gInLegacy || ![self respondsToSelector:legacy]) return nil;
	NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"TidalOffline" isDirectory:YES];
	[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
	NSURL *dest = [dir URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"movpkg"]];
	gInLegacy = YES;
	id task = ((id (*)(id, SEL, id, NSURL *, NSDictionary *))objc_msgSend)(self, legacy, asset, dest, options);
	gInLegacy = NO;
	if (task) NSLog(@"[TidalSideloadFix] asset download: into Documents/TidalOffline");
	else NSLog(@"[TidalSideloadFix] asset download: legacy API refused");
	return task;
}

static id hook_assetTask(id self, SEL _cmd, id asset, NSString *title, NSData *art, NSDictionary *options) {
	return SFLegacyAssetTask(self, asset, options) ?: orig_assetTask(self, _cmd, asset, title, art, options);
}
static id hook_baseAssetTask(id self, SEL _cmd, id asset, NSString *title, NSData *art, NSDictionary *options) {
	return SFLegacyAssetTask(self, asset, options) ?: orig_baseAssetTask(self, _cmd, asset, title, art, options);
}

__attribute__((constructor)) static void SFSideloadFix(void) {
	_dyld_register_func_for_add_image(SFRebind);
	Method m = class_getInstanceMethod(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:));
	orig_container = (void *)method_setImplementation(m, (IMP)hook_container);
	SEL sel = NSSelectorFromString(@"assetDownloadTaskWithURLAsset:assetTitle:assetArtworkData:options:");
	Method t = class_getInstanceMethod(NSClassFromString(@"AVAssetDownloadURLSession"), sel), base = class_getInstanceMethod(NSURLSession.class, sel);
	if (base) orig_baseAssetTask = (SFAssetTaskIMP)method_setImplementation(base, (IMP)hook_baseAssetTask);
	if (t && t != base) orig_assetTask = (SFAssetTaskIMP)method_setImplementation(t, (IMP)hook_assetTask);
}
