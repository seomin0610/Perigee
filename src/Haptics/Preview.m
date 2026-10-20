#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>
#import "Scene.h"

NSString *HTL(NSString *en, NSString *ko);

static NSString *const kShader = @"#include <metal_stdlib>\n"
                                 "using namespace metal;\n"
                                 "struct Dot { float x, y, radius, bright, white, base; };\n"
                                 "struct Frag {\n"
                                 "	float4 position [[position]];\n"
                                 "	float2 local;\n"
                                 "	float radius [[flat]];\n"
                                 "	float bright [[flat]];\n"
                                 "	float white [[flat]];\n"
                                 "	float base [[flat]];\n"
                                 "};\n"
                                 "vertex Frag vmain(uint v [[vertex_id]], uint i [[instance_id]], const device Dot *dots [[buffer(0)]], constant float2 &size [[buffer(1)]]) {\n"
                                 "	Dot d = dots[i];\n"
                                 "	float span = d.radius * (d.bright > 0.01 ? 4.0 : 1.5) + 1.0;\n"
                                 "	float2 corner = float2((v & 1) ? 1.0 : -1.0, (v & 2) ? 1.0 : -1.0) * span;\n"
                                 "	float2 p = float2(d.x, d.y) + corner;\n"
                                 "	Frag o;\n"
                                 "	o.position = float4(p.x / size.x * 2.0 - 1.0, 1.0 - p.y / size.y * 2.0, 0.0, 1.0);\n"
                                 "	o.local = corner;\n"
                                 "	o.radius = d.radius;\n"
                                 "	o.bright = d.bright;\n"
                                 "	o.white = d.white;\n"
                                 "	o.base = d.base;\n"
                                 "	return o;\n"
                                 "}\n"
                                 "fragment float4 fmain(Frag f [[stage_in]], constant float4 &accent [[buffer(0)]]) {\n"
                                 "	float d = length(f.local);\n"
                                 "	float core = saturate(f.radius + 0.5 - d);\n"
                                 "	float lit = min(f.bright, 1.5);\n"
                                 "	float3 tint = mix(accent.rgb, float3(1.0), float3(f.white));\n"
                                 "	float halo = exp(-d * d / (f.radius * f.radius * 4.0)) * lit * 0.6;\n"
                                 "	return float4(core * (f.base + lit * tint) + halo * tint, 1.0);\n"
                                 "}\n";

@interface HTDisc : UIView
@end

@implementation HTDisc {
	id<MTLDevice> _device;
	id<MTLCommandQueue> _queue;
	id<MTLRenderPipelineState> _pipe;
	id<MTLBuffer> _buffers[3];
	NSUInteger _frame;
	dispatch_semaphore_t _free;
	CADisplayLink *_link;
	UILabel *_caption;
	UIImpactFeedbackGenerator *_tapper;
	simd_float4 _accent;
	HSScene _scene;
}

+ (Class)layerClass { return CAMetalLayer.class; }

- (instancetype)initWithFrame:(CGRect)frame {
	if (!(self = [super initWithFrame:frame])) return nil;
	self.backgroundColor = UIColor.blackColor;
	_device = MTLCreateSystemDefaultDevice();
	_queue = [_device newCommandQueue];
	NSError *e;
	id<MTLLibrary> lib = [_device newLibraryWithSource:kShader options:nil error:&e];
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [lib newFunctionWithName:@"vmain"];
	d.fragmentFunction = [lib newFunctionWithName:@"fmain"];
	MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[0];
	c.pixelFormat = MTLPixelFormatBGRA8Unorm;
	c.blendingEnabled = YES;
	c.sourceRGBBlendFactor = c.destinationRGBBlendFactor = c.sourceAlphaBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorOne;
	_pipe = lib ? [_device newRenderPipelineStateWithDescriptor:d error:&e] : nil;
	if (!_pipe) os_log(OS_LOG_DEFAULT, "[TidalHaptics] preview off: %{public}@", e);
	for (int i = 0; i < 3; i++) _buffers[i] = [_device newBufferWithLength:sizeof(HSDot) * HSMaxDots options:MTLResourceStorageModeShared];
	_free = dispatch_semaphore_create(3);

	CAMetalLayer *l = (CAMetalLayer *)self.layer;
	l.device = _device;
	l.pixelFormat = MTLPixelFormatBGRA8Unorm;
	l.framebufferOnly = YES;
	l.opaque = YES;

	_caption = [UILabel new];
	_caption.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	_caption.textColor = [UIColor colorWithWhite:1 alpha:0.6];
	_caption.textAlignment = NSTextAlignmentCenter;
	[self addSubview:_caption];
	_tapper = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
	[self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap)]];
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGSize size = self.bounds.size;
	CGFloat scale = self.traitCollection.displayScale ?: 2;
	((CAMetalLayer *)self.layer).contentsScale = scale;
	((CAMetalLayer *)self.layer).drawableSize = CGSizeMake(size.width * scale, size.height * scale);
	_caption.frame = CGRectMake(16, size.height - self.safeAreaInsets.bottom - 40, size.width - 32, 24);
}

- (void)tintColorDidChange {
	[super tintColorDidChange];
	UIColor *c = [self.tintColor resolvedColorWithTraitCollection:self.traitCollection];
	CGFloat r = 1, g = 1, b = 1, a = 1, hue = 0, sat = 0;
	[c getHue:&hue saturation:&sat brightness:&b alpha:&a];
	[(sat < 0.2 ? UIColor.systemTealColor : c) getRed:&r green:&g blue:&b alpha:&a];
	_accent = (simd_float4){ r, g, b, 1 };
}

- (void)didMoveToWindow {
	[super didMoveToWindow];
	[_link invalidate];
	_link = nil;
	if (!self.window) return;
	[self tintColorDidChange];
	HSInit(&_scene, CACurrentMediaTime());
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step)];
	[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)tap {
	[_tapper impactOccurredWithIntensity:1];
	HSAddHit(CACurrentMediaTime(), 1, HSControl);
}

- (void)step {
	CAMetalLayer *l = (CAMetalLayer *)self.layer;
	CGSize size = l.drawableSize;
	if (!_pipe || size.width < 1 || size.height < 1 || dispatch_semaphore_wait(_free, DISPATCH_TIME_NOW)) return;
	id<MTLBuffer> buffer = _buffers[_frame++ % 3];
	double now = CACurrentMediaTime();
	_scene.calm = UIAccessibilityIsReduceMotionEnabled();
	NSUInteger count = HSFrame(&_scene, now, size.width, size.height, buffer.contents);
	NSString *text = now - _scene.followed < 1.5 ? HTL(@"Following the song", @"곡을 따라가는 중") : HTL(@"Tap to feel it", @"탭해서 느껴보세요");
	if (![_caption.text isEqualToString:text]) _caption.text = text;

	id<CAMetalDrawable> drawable = [l nextDrawable];
	if (!drawable) {
		dispatch_semaphore_signal(_free);
		return;
	}
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = drawable.texture;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLCommandBuffer> cb = [_queue commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
	simd_float2 viewport = { size.width, size.height };
	[enc setRenderPipelineState:_pipe];
	[enc setVertexBuffer:buffer offset:0 atIndex:0];
	[enc setVertexBytes:&viewport length:sizeof viewport atIndex:1];
	[enc setFragmentBytes:&_accent length:sizeof _accent atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:count];
	[enc endEncoding];
	[cb presentDrawable:drawable];
	dispatch_semaphore_t sem = _free;
	[cb addCompletedHandler:^(id<MTLCommandBuffer> b) { dispatch_semaphore_signal(sem); }];
	[cb commit];
}
@end

void HTShowPreview(void) {
	UIViewController *top = nil;
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
		if ([scene isKindOfClass:UIWindowScene.class])
			for (UIWindow *w in ((UIWindowScene *)scene).windows)
				if (w.isKeyWindow) top = w.rootViewController;
	while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
	if (!top) return;
	UIViewController *vc = [UIViewController new];
	vc.view = [HTDisc new];
	vc.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
	vc.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent ];
	vc.sheetPresentationController.prefersGrabberVisible = YES;
	[top presentViewController:vc animated:YES completion:nil];
}
