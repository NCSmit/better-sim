// Method replacement shared by the libraries BetterSim loads into simulator apps.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

/// Replaces a method and returns the old implementation. An inherited method gets an override on this class, so the
/// superclass's other subclasses are left alone.
static inline IMP BetterSimReplace(Class cls, SEL selector, id block) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
    return original;
}

static inline IMP BetterSimReplaceClassMethod(Class cls, SEL selector, id block) {
    return BetterSimReplace(object_getClass(cls), selector, block);
}

/// Whether the code at `caller` belongs to one of the system frameworks named in `frameworks`, so a replaced method
/// can answer the system as it always did and only change its answer for the app.
static inline BOOL BetterSimCalledFrom(const void *caller, const char *const frameworks[]) {
    Dl_info info;
    if (!dladdr(caller, &info) || !info.dli_fname) return NO;
    for (const char *const *framework = frameworks; *framework; framework++) {
        if (strstr(info.dli_fname, *framework)) return YES;
    }
    return NO;
}
