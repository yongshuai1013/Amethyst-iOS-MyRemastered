// Natives/metalfx/ame_mfx.m
// 阶段 0：能力探针。只打印，不建资源、不改渲染行为。
//
// 刻意不 #import <MetalFX/MetalFX.h>：MetalFX 以 weak_framework 链接，且
// 只有 iOS 16+ 才有。全部走 NSClassFromString + objc_msgSend，这样在没有
// MetalFX 头文件的 SDK 上也能编译，在旧系统上运行时也只是「类不存在」，
// 不会崩。

#import "ame_mfx.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <dlfcn.h>

#ifndef EGL_EXTENSIONS
#define EGL_EXTENSIONS 0x3055
#endif

static BOOL s_probeDone = NO;

static void AmeMfxLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[MFX] %@", msg);
}

/// 安全地调用一个类方法 +selName，返回 BOOL。
/// 类不存在（framework 缺席 / 系统过旧）或不响应该选择器时返回 NO 并说明原因。
static BOOL AmeMfxBoolClassMethod(NSString *className, NSString *selName, id arg) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        AmeMfxLog(@"    %@: class not found (MetalFX absent or OS too old)", className);
        return NO;
    }
    SEL sel = NSSelectorFromString(selName);
    if (![cls respondsToSelector:sel]) {
        AmeMfxLog(@"    %@: does not respond to +%@", className, selName);
        return NO;
    }
    BOOL (*fn)(Class, SEL, id) = (BOOL (*)(Class, SEL, id))objc_msgSend;
    return fn(cls, sel, arg);
}

void ameMfxProbe(void) {
    if (s_probeDone) return;
    s_probeDone = YES;

    AmeMfxLog(@"==== MetalFX capability probe ====");

    // (1) MTLDevice —— MetalFX 只吃 MTLTexture，没有它就整条路不成立
    id<MTLDevice> dev = nil;
    if (@available(iOS 13.0, *)) {
        dev = MTLCreateSystemDefaultDevice();
    }
    AmeMfxLog(@"(1) MTLDevice=%@ name='%@'",
              dev ? @"YES" : @"NO", dev ? dev.name : @"(nil)");
    if (!dev) {
        AmeMfxLog(@"    -> 无 MTLDevice，MetalFX 不可用");
        AmeMfxLog(@"==== probe end ====");
        return;
    }

    // (2) ANGLE 的 Metal 互操作扩展 —— 零拷贝枢纽
    void *(*eglGetCurrentDisplay)(void) =
        (void *(*)(void))dlsym(RTLD_DEFAULT, "eglGetCurrentDisplay");
    const char *(*eglQueryString)(void *, unsigned int) =
        (const char *(*)(void *, unsigned int))dlsym(RTLD_DEFAULT, "eglQueryString");

    if (!eglGetCurrentDisplay || !eglQueryString) {
        AmeMfxLog(@"(2) eglGetCurrentDisplay/eglQueryString 无法解析（当前不走 ANGLE EGL？）");
    } else {
        void *dpy = eglGetCurrentDisplay();
        if (!dpy) {
            AmeMfxLog(@"(2) eglGetCurrentDisplay == NULL（此刻还没有当前 EGL display）");
        } else {
            const char *exts = eglQueryString(dpy, EGL_EXTENSIONS);
            NSString *s = exts ? [NSString stringWithUTF8String:exts] : @"";
            BOOL hasMetalTex   = [s containsString:@"EGL_ANGLE_metal_texture_client_buffer"];
            BOOL hasDeviceMetal = [s containsString:@"EGL_ANGLE_device_metal"];
            AmeMfxLog(@"(2) EGL_ANGLE_metal_texture_client_buffer=%d", hasMetalTex ? 1 : 0);
            AmeMfxLog(@"(2) EGL_ANGLE_device_metal=%d", hasDeviceMetal ? 1 : 0);
            if (!hasMetalTex) {
                AmeMfxLog(@"    -> 关键缺失：无法把 MTLTexture 导入成 GL 纹理，");
                AmeMfxLog(@"       零拷贝通路不成立（只能退回到 readPixels 拷一份，代价极高）");
            }
        }
    }

    // (3) MetalFX 各组件
    if (@available(iOS 16.0, *)) {
        AmeMfxLog(@"(3) SpatialScaler supportsDevice=%d",
                  AmeMfxBoolClassMethod(@"MTLFXSpatialScalerDescriptor",
                                        @"supportsDevice:", dev) ? 1 : 0);
        AmeMfxLog(@"(3) TemporalScaler supportsDevice=%d",
                  AmeMfxBoolClassMethod(@"MTLFXTemporalScalerDescriptor",
                                        @"supportsDevice:", dev) ? 1 : 0);
    } else {
        AmeMfxLog(@"(3) 系统 < iOS 16，Spatial / Temporal 均不可用");
    }

    if (@available(iOS 26.0, *)) {
        AmeMfxLog(@"(3) FrameInterpolator supportsDevice=%d",
                  AmeMfxBoolClassMethod(@"MTLFXFrameInterpolatorDescriptor",
                                        @"supportsDevice:", dev) ? 1 : 0);
        AmeMfxLog(@"(3) FrameInterpolator supportsMetal4FX=%d",
                  AmeMfxBoolClassMethod(@"MTLFXFrameInterpolatorDescriptor",
                                        @"supportsMetal4FX:", dev) ? 1 : 0);
    } else {
        AmeMfxLog(@"(3) 系统 < iOS 26，FrameInterpolator 不可用（随 Metal 4 引入）");
    }

    AmeMfxLog(@"==== probe end ====");
}
