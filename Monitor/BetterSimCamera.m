// BetterSim loads this into a simulator app through DYLD_INSERT_LIBRARIES when you turn on the simulator camera. The
// Simulator has no camera, so AVFoundation is given a pretend one. Capture sessions that use it receive the frames
// BetterSim streams from the Mac to 127.0.0.1:$BETTERSIM_CAMERA_PORT, each a 4-byte big-endian length and a JPEG.
// Preview layers, video data outputs and photo outputs work. Without that variable the library does nothing.

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "BetterSimSwizzle.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <stdatomic.h>

static long BetterSimCameraPort;
static const int32_t BetterSimWidth = 1280;
static const int32_t BetterSimHeight = 720;
static const int32_t BetterSimFrameRate = 30;

#pragma mark - Fakes

static void BetterSimDispose(__unsafe_unretained id self, SEL _cmd) {
    static void (*dispose)(void *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dispose = (void (*)(void *))dlsym(RTLD_DEFAULT, "object_dispose"); });
    dispose((__bridge void *)self);
}

/// Makes an AVFoundation object without AVFoundation's private state. Its own dealloc would trip over that missing
/// state, so these are freed the way NSObject frees objects, which still releases their instance variables.
static id BetterSimMake(Class cls) {
    static NSMutableSet<NSString *> *prepared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ prepared = [NSMutableSet set]; });
    @synchronized (prepared) {
        if (![prepared containsObject:NSStringFromClass(cls)]) {
            class_addMethod(cls, sel_registerName("dealloc"), (IMP)BetterSimDispose, "v@:");
            [prepared addObject:NSStringFromClass(cls)];
        }
    }
    return class_createInstance(cls, 0);
}

@interface BetterSimWeakBox : NSObject
@property (nonatomic, weak) id value;
@end
@implementation BetterSimWeakBox
@end

static void BetterSimSetWeak(id object, const void *key, id value) {
    BetterSimWeakBox *box = [BetterSimWeakBox new];
    box.value = value;
    objc_setAssociatedObject(object, key, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id BetterSimWeak(id object, const void *key) {
    return [(BetterSimWeakBox *)objc_getAssociatedObject(object, key) value];
}

@interface BetterSimFrameRateRange : AVFrameRateRange
@end

@implementation BetterSimFrameRateRange
- (Float64)minFrameRate { return 1; }
- (Float64)maxFrameRate { return BetterSimFrameRate; }
- (CMTime)minFrameDuration { return CMTimeMake(1, BetterSimFrameRate); }
- (CMTime)maxFrameDuration { return CMTimeMake(1, 1); }
- (NSString *)description { return @"<BetterSimFrameRateRange 1-30 fps>"; }
- (BOOL)isEqual:(id)object { return self == object; }
- (NSUInteger)hash { return (NSUInteger)(__bridge void *)self; }
@end

@interface BetterSimDeviceFormat : AVCaptureDeviceFormat
@end

@implementation BetterSimDeviceFormat
- (AVMediaType)mediaType { return AVMediaTypeVideo; }
- (CMFormatDescriptionRef)formatDescription {
    static CMVideoFormatDescriptionRef description;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, BetterSimWidth, BetterSimHeight, NULL, &description);
    });
    return description;
}
- (NSArray<AVFrameRateRange *> *)videoSupportedFrameRateRanges {
    static NSArray *ranges;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ranges = @[BetterSimMake(BetterSimFrameRateRange.class)]; });
    return ranges;
}
- (float)videoFieldOfView { return 70; }
- (float)geometricDistortionCorrectedVideoFieldOfView { return 70; }
- (BOOL)isVideoBinned { return NO; }
- (BOOL)isVideoStabilizationModeSupported:(AVCaptureVideoStabilizationMode)mode { return mode == AVCaptureVideoStabilizationModeOff; }
- (CGFloat)videoMaxZoomFactor { return 5; }
- (CGFloat)videoZoomFactorUpscaleThreshold { return 1; }
- (CMTime)minExposureDuration { return CMTimeMake(1, 8000); }
- (CMTime)maxExposureDuration { return CMTimeMake(1, 3); }
- (float)minISO { return 50; }
- (float)maxISO { return 1600; }
- (BOOL)isVideoHDRSupported { return NO; }
- (BOOL)isGlobalToneMappingSupported { return NO; }
- (BOOL)isMultiCamSupported { return NO; }
- (BOOL)isHighestPhotoQualitySupported { return YES; }
- (BOOL)isHighPhotoQualitySupported { return YES; }
- (CMVideoDimensions)highResolutionStillImageDimensions { return (CMVideoDimensions){BetterSimWidth, BetterSimHeight}; }
- (NSArray<NSValue *> *)supportedMaxPhotoDimensions {
    return @[[NSValue valueWithCMVideoDimensions:(CMVideoDimensions){BetterSimWidth, BetterSimHeight}]];
}
- (NSArray<NSNumber *> *)supportedColorSpaces { return @[@(AVCaptureColorSpace_sRGB)]; }
- (AVCaptureAutoFocusSystem)autoFocusSystem { return AVCaptureAutoFocusSystemContrastDetection; }
- (NSArray<AVCaptureDeviceFormat *> *)supportedDepthDataFormats { return @[]; }
- (NSArray<NSValue *> *)videoMinZoomFactorsForDepthDataDelivery { return @[]; }
- (NSArray<NSValue *> *)systemRecommendedVideoZoomRange { return nil; }
// AVFoundation asks the default camera's format for its capture details while setting up a photo output. With
// none, it falls back to its defaults as it would without a camera.
- (id)figCaptureSourceVideoFormat { return nil; }
- (NSString *)description { return @"<BetterSimDeviceFormat 1280x720 30 fps>"; }
- (BOOL)isEqual:(id)object { return self == object; }
- (NSUInteger)hash { return (NSUInteger)(__bridge void *)self; }
@end

@interface BetterSimCaptureDevice : AVCaptureDevice
@property (nonatomic) AVCaptureDevicePosition cameraPosition;
@property (nonatomic, strong) AVCaptureDeviceFormat *cameraFormat;
@property (nonatomic) CGFloat zoom;
@property (nonatomic) AVCaptureFocusMode cameraFocusMode;
@property (nonatomic) AVCaptureExposureMode cameraExposureMode;
@property (nonatomic) AVCaptureWhiteBalanceMode cameraWhiteBalanceMode;
@property (nonatomic) CGPoint focusPoint;
@property (nonatomic) CGPoint exposurePoint;
@property (nonatomic) float exposureBias;
@property (nonatomic) BOOL monitorsSubjectArea;
@property (nonatomic) BOOL lowLightBoost;
@property (nonatomic) CMTime minFrameDuration;
@property (nonatomic) CMTime maxFrameDuration;
@end

@implementation BetterSimCaptureDevice
- (NSString *)uniqueID { return self.cameraPosition == AVCaptureDevicePositionFront ? @"BetterSimCamera.front" : @"BetterSimCamera.back"; }
- (NSString *)modelID { return @"BetterSimCamera"; }
- (NSString *)localizedName { return self.cameraPosition == AVCaptureDevicePositionFront ? @"Front Camera" : @"Back Camera"; }
- (NSString *)manufacturer { return @"BetterSim"; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (AVCaptureDevicePosition)position { return self.cameraPosition; }
- (BOOL)hasMediaType:(AVMediaType)mediaType { return [mediaType isEqualToString:AVMediaTypeVideo]; }
- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)preset { return YES; }
- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (NSArray<AVCaptureDevice *> *)linkedDevices { return @[]; }
- (NSArray<AVCaptureDeviceFormat *> *)formats { return @[self.activeFormat]; }
- (AVCaptureDeviceFormat *)activeFormat {
    if (!self.cameraFormat) self.cameraFormat = BetterSimMake(BetterSimDeviceFormat.class);
    return self.cameraFormat;
}
- (void)setActiveFormat:(AVCaptureDeviceFormat *)format {}
- (CMTime)activeVideoMinFrameDuration { return CMTIME_IS_VALID(self.minFrameDuration) ? self.minFrameDuration : CMTimeMake(1, BetterSimFrameRate); }
- (void)setActiveVideoMinFrameDuration:(CMTime)duration { self.minFrameDuration = duration; }
- (CMTime)activeVideoMaxFrameDuration { return CMTIME_IS_VALID(self.maxFrameDuration) ? self.maxFrameDuration : CMTimeMake(1, BetterSimFrameRate); }
- (void)setActiveVideoMaxFrameDuration:(CMTime)duration { self.maxFrameDuration = duration; }
- (BOOL)lockForConfiguration:(NSError **)error { return YES; }
- (void)unlockForConfiguration {}
- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)mode { return YES; }
- (AVCaptureFocusMode)focusMode { return self.cameraFocusMode; }
- (void)setFocusMode:(AVCaptureFocusMode)mode { self.cameraFocusMode = mode; }
- (BOOL)isFocusPointOfInterestSupported { return YES; }
- (CGPoint)focusPointOfInterest { return self.focusPoint; }
- (void)setFocusPointOfInterest:(CGPoint)point { self.focusPoint = point; }
- (BOOL)isAdjustingFocus { return NO; }
- (BOOL)isAutoFocusRangeRestrictionSupported { return NO; }
- (BOOL)isSmoothAutoFocusSupported { return NO; }
- (BOOL)isLockingFocusWithCustomLensPositionSupported { return YES; }
- (float)lensPosition { return 0.5; }
- (void)setFocusModeLockedWithLensPosition:(float)lensPosition completionHandler:(void (^)(CMTime))handler {
    if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(CMClockGetTime(CMClockGetHostTimeClock())); });
}
- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)mode { return YES; }
- (AVCaptureExposureMode)exposureMode { return self.cameraExposureMode; }
- (void)setExposureMode:(AVCaptureExposureMode)mode { self.cameraExposureMode = mode; }
- (BOOL)isExposurePointOfInterestSupported { return YES; }
- (CGPoint)exposurePointOfInterest { return self.exposurePoint; }
- (void)setExposurePointOfInterest:(CGPoint)point { self.exposurePoint = point; }
- (BOOL)isAdjustingExposure { return NO; }
- (CMTime)exposureDuration { return CMTimeMake(1, BetterSimFrameRate); }
- (float)ISO { return 100; }
- (float)exposureTargetBias { return self.exposureBias; }
- (float)minExposureTargetBias { return -8; }
- (float)maxExposureTargetBias { return 8; }
- (float)exposureTargetOffset { return 0; }
- (float)lensAperture { return 1.8; }
- (void)setExposureTargetBias:(float)bias completionHandler:(void (^)(CMTime))handler {
    self.exposureBias = bias;
    if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(CMClockGetTime(CMClockGetHostTimeClock())); });
}
- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)mode { return YES; }
- (AVCaptureWhiteBalanceMode)whiteBalanceMode { return self.cameraWhiteBalanceMode; }
- (void)setWhiteBalanceMode:(AVCaptureWhiteBalanceMode)mode { self.cameraWhiteBalanceMode = mode; }
- (BOOL)isAdjustingWhiteBalance { return NO; }
- (BOOL)hasFlash { return NO; }
- (BOOL)isFlashAvailable { return NO; }
- (BOOL)hasTorch { return NO; }
- (BOOL)isTorchAvailable { return NO; }
- (BOOL)isTorchActive { return NO; }
- (float)torchLevel { return 0; }
- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)mode { return mode == AVCaptureTorchModeOff; }
- (AVCaptureTorchMode)torchMode { return AVCaptureTorchModeOff; }
- (void)setTorchMode:(AVCaptureTorchMode)mode {}
- (CGFloat)videoZoomFactor { return MAX(self.zoom, 1); }
- (void)setVideoZoomFactor:(CGFloat)factor { self.zoom = MIN(MAX(factor, 1), 5); }
- (void)rampToVideoZoomFactor:(CGFloat)factor withRate:(float)rate { self.videoZoomFactor = factor; }
- (void)cancelVideoZoomRamp {}
- (BOOL)isRampingVideoZoom { return NO; }
- (CGFloat)minAvailableVideoZoomFactor { return 1; }
- (CGFloat)maxAvailableVideoZoomFactor { return 5; }
- (CGFloat)displayVideoZoomFactorMultiplier { return 1; }
- (NSArray<NSNumber *> *)virtualDeviceSwitchOverVideoZoomFactors { return @[]; }
- (BOOL)isSubjectAreaChangeMonitoringEnabled { return self.monitorsSubjectArea; }
- (void)setSubjectAreaChangeMonitoringEnabled:(BOOL)enabled { self.monitorsSubjectArea = enabled; }
- (BOOL)isLowLightBoostSupported { return NO; }
- (BOOL)isLowLightBoostEnabled { return NO; }
- (BOOL)automaticallyEnablesLowLightBoostWhenAvailable { return self.lowLightBoost; }
- (void)setAutomaticallyEnablesLowLightBoostWhenAvailable:(BOOL)enabled { self.lowLightBoost = enabled; }
- (BOOL)isVirtualDevice { return NO; }
- (NSArray<AVCaptureDevice *> *)constituentDevices { return @[]; }
- (AVCaptureColorSpace)activeColorSpace { return AVCaptureColorSpace_sRGB; }
- (void)setActiveColorSpace:(AVCaptureColorSpace)space {}
- (BOOL)isVideoHDREnabled { return NO; }
- (BOOL)automaticallyAdjustsVideoHDREnabled { return NO; }
- (void)setAutomaticallyAdjustsVideoHDREnabled:(BOOL)enabled {}
- (BOOL)isGlobalToneMappingEnabled { return NO; }
- (AVCaptureDeviceFormat *)activeDepthDataFormat { return nil; }
- (NSString *)description { return [NSString stringWithFormat:@"<BetterSimCaptureDevice %@>", self.localizedName]; }
- (NSString *)debugDescription { return self.description; }
- (BOOL)isEqual:(id)object { return self == object; }
- (NSUInteger)hash { return (NSUInteger)(__bridge void *)self; }
@end

static BetterSimCaptureDevice *BetterSimCamera(AVCaptureDevicePosition position) {
    static BetterSimCaptureDevice *back, *front;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        back = BetterSimMake(BetterSimCaptureDevice.class);
        back.cameraPosition = AVCaptureDevicePositionBack;
        back.cameraFocusMode = AVCaptureFocusModeContinuousAutoFocus;
        back.cameraExposureMode = AVCaptureExposureModeContinuousAutoExposure;
        back.focusPoint = back.exposurePoint = CGPointMake(0.5, 0.5);
        back.minFrameDuration = back.maxFrameDuration = kCMTimeInvalid;
        front = BetterSimMake(BetterSimCaptureDevice.class);
        front.cameraPosition = AVCaptureDevicePositionFront;
        front.cameraFocusMode = AVCaptureFocusModeContinuousAutoFocus;
        front.cameraExposureMode = AVCaptureExposureModeContinuousAutoExposure;
        front.focusPoint = front.exposurePoint = CGPointMake(0.5, 0.5);
        front.minFrameDuration = front.maxFrameDuration = kCMTimeInvalid;
    });
    return position == AVCaptureDevicePositionFront ? front : back;
}

@interface BetterSimDeviceInput : AVCaptureDeviceInput
@property (nonatomic, strong) AVCaptureDevice *camera;
@property (nonatomic) BOOL unifiedExposure;
@end

@implementation BetterSimDeviceInput
- (AVCaptureDevice *)device { return self.camera; }
- (NSArray<AVCaptureInputPort *> *)ports { return @[]; }
- (BOOL)unifiedAutoExposureDefaultsEnabled { return self.unifiedExposure; }
- (void)setUnifiedAutoExposureDefaultsEnabled:(BOOL)enabled { self.unifiedExposure = enabled; }
- (CMTime)videoMinFrameDurationOverride { return kCMTimeInvalid; }
- (void)setVideoMinFrameDurationOverride:(CMTime)duration {}
- (NSString *)description { return [NSString stringWithFormat:@"<BetterSimDeviceInput %@>", self.camera.localizedName]; }
- (BOOL)isEqual:(id)object { return self == object; }
- (NSUInteger)hash { return (NSUInteger)(__bridge void *)self; }
@end

static id BetterSimMakeInput(AVCaptureDevice *device) {
    BetterSimDeviceInput *input = BetterSimMake(BetterSimDeviceInput.class);
    input.camera = device;
    return input;
}

@interface BetterSimConnection : AVCaptureConnection
@property (nonatomic, weak) AVCaptureOutput *owner;
@property (nonatomic, weak) AVCaptureVideoPreviewLayer *layer;
@property (nonatomic) CGFloat rotation;
@property (nonatomic) BOOL mirrored;
@property (nonatomic) BOOL adjustsMirroring;
@property (nonatomic) BOOL off;
@property (nonatomic) AVCaptureVideoStabilizationMode stabilization;
@end

@implementation BetterSimConnection
- (NSArray<AVCaptureInputPort *> *)inputPorts { return @[]; }
- (AVCaptureOutput *)output { return self.owner; }
- (AVCaptureVideoPreviewLayer *)videoPreviewLayer { return self.layer; }
- (BOOL)isEnabled { return !self.off; }
- (void)setEnabled:(BOOL)enabled { self.off = !enabled; }
- (BOOL)isActive { return YES; }
- (NSArray *)audioChannels { return @[]; }
- (BOOL)isVideoMirroringSupported { return YES; }
- (BOOL)isVideoMirrored { return self.mirrored; }
- (void)setVideoMirrored:(BOOL)mirrored { self.mirrored = mirrored; }
- (BOOL)automaticallyAdjustsVideoMirroring { return self.adjustsMirroring; }
- (void)setAutomaticallyAdjustsVideoMirroring:(BOOL)adjusts { self.adjustsMirroring = adjusts; }
- (BOOL)isVideoOrientationSupported { return YES; }
- (AVCaptureVideoOrientation)videoOrientation {
    long angle = lround(self.rotation) % 360;
    if (angle == 90) return AVCaptureVideoOrientationPortrait;
    if (angle == 180) return AVCaptureVideoOrientationLandscapeLeft;
    if (angle == 270) return AVCaptureVideoOrientationPortraitUpsideDown;
    return AVCaptureVideoOrientationLandscapeRight;
}
- (void)setVideoOrientation:(AVCaptureVideoOrientation)orientation {
    switch (orientation) {
        case AVCaptureVideoOrientationPortrait: self.rotation = 90; break;
        case AVCaptureVideoOrientationLandscapeLeft: self.rotation = 180; break;
        case AVCaptureVideoOrientationPortraitUpsideDown: self.rotation = 270; break;
        default: self.rotation = 0; break;
    }
}
- (BOOL)isVideoRotationAngleSupported:(CGFloat)angle { return YES; }
- (CGFloat)videoRotationAngle { return self.rotation; }
- (void)setVideoRotationAngle:(CGFloat)angle { self.rotation = angle; }
- (BOOL)isVideoStabilizationSupported { return NO; }
- (AVCaptureVideoStabilizationMode)preferredVideoStabilizationMode { return self.stabilization; }
- (void)setPreferredVideoStabilizationMode:(AVCaptureVideoStabilizationMode)mode { self.stabilization = mode; }
- (AVCaptureVideoStabilizationMode)activeVideoStabilizationMode { return AVCaptureVideoStabilizationModeOff; }
- (BOOL)isCameraIntrinsicMatrixDeliverySupported { return NO; }
- (BOOL)isCameraIntrinsicMatrixDeliveryEnabled { return NO; }
- (void)setCameraIntrinsicMatrixDeliveryEnabled:(BOOL)enabled {}
- (NSString *)description { return [NSString stringWithFormat:@"<BetterSimConnection rotation %.0f>", self.rotation]; }
- (BOOL)isEqual:(id)object { return self == object; }
- (NSUInteger)hash { return (NSUInteger)(__bridge void *)self; }
@end

static const void *BetterSimConnectionKey = &BetterSimConnectionKey;

/// One connection per output or preview layer. Previews start in portrait like the real thing, and data outputs in
/// the sensor's landscape orientation.
static BetterSimConnection *BetterSimConnectionFor(id owner, BOOL preview) {
    @synchronized (owner) {
        BetterSimConnection *connection = objc_getAssociatedObject(owner, BetterSimConnectionKey);
        if (!connection) {
            connection = BetterSimMake(BetterSimConnection.class);
            connection.rotation = preview ? 90 : 0;
            connection.adjustsMirroring = YES;
            if (preview) connection.layer = owner; else connection.owner = owner;
            objc_setAssociatedObject(owner, BetterSimConnectionKey, connection, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return connection;
    }
}

@interface BetterSimResolvedSettings : AVCaptureResolvedPhotoSettings
@property (nonatomic) int64_t identifier;
@property (nonatomic) CMVideoDimensions dimensions;
@end

@implementation BetterSimResolvedSettings
- (int64_t)uniqueID { return self.identifier; }
- (CMVideoDimensions)photoDimensions { return self.dimensions; }
- (CMVideoDimensions)rawPhotoDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)previewDimensions { return self.dimensions; }
- (CMVideoDimensions)embeddedThumbnailDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)rawEmbeddedThumbnailDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)livePhotoMovieDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)portraitEffectsMatteDimensions { return (CMVideoDimensions){0, 0}; }
- (CMVideoDimensions)deferredPhotoProxyDimensions { return (CMVideoDimensions){0, 0}; }
- (BOOL)isFlashEnabled { return NO; }
- (BOOL)isRedEyeReductionEnabled { return NO; }
- (BOOL)isStillImageStabilizationEnabled { return NO; }
- (BOOL)isDualCameraFusionEnabled { return NO; }
- (BOOL)isVirtualDeviceFusionEnabled { return NO; }
- (BOOL)isContentAwareDistortionCorrectionEnabled { return NO; }
- (BOOL)isFastCapturePrioritizationEnabled { return NO; }
- (NSUInteger)expectedPhotoCount { return 1; }
- (CMTimeRange)photoProcessingTimeRange { return CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 10)); }
- (NSString *)description { return [NSString stringWithFormat:@"<BetterSimResolvedSettings %lld>", self.identifier]; }
- (BOOL)isEqual:(id)object { return self == object; }
- (NSUInteger)hash { return (NSUInteger)(__bridge void *)self; }
@end

@interface BetterSimPhoto : AVCapturePhoto
@property (nonatomic, strong) NSData *data;
@property (nonatomic) CGImageRef image;
@property (nonatomic, strong) AVCaptureResolvedPhotoSettings *settings;
@property (nonatomic) CMTime time;
@property (nonatomic) CVPixelBufferRef buffer;
@end

@implementation BetterSimPhoto
- (NSData *)fileDataRepresentation { return self.data; }
- (NSData *)fileDataRepresentationWithCustomizer:(id<AVCapturePhotoFileDataRepresentationCustomizer>)customizer { return self.data; }
- (NSData *)fileDataRepresentationWithReplacementMetadata:(NSDictionary *)metadata replacementEmbeddedThumbnailPhotoFormat:(NSDictionary *)format replacementEmbeddedThumbnailPixelBuffer:(CVPixelBufferRef)buffer replacementDepthData:(AVDepthData *)depthData {
    return self.data;
}
- (CGImageRef)CGImageRepresentation { return self.image; }
- (CGImageRef)previewCGImageRepresentation { return self.image; }
- (CVPixelBufferRef)pixelBuffer { return self.buffer; }
- (CVPixelBufferRef)previewPixelBuffer { return self.buffer; }
- (NSDictionary<NSString *, id> *)metadata { return @{(NSString *)kCGImagePropertyOrientation: @1}; }
- (CMTime)timestamp { return self.time; }
- (AVCaptureResolvedPhotoSettings *)resolvedSettings { return self.settings; }
- (NSInteger)photoCount { return 1; }
- (BOOL)isRawPhoto { return NO; }
- (AVDepthData *)depthData { return nil; }
- (AVPortraitEffectsMatte *)portraitEffectsMatte { return nil; }
- (AVCameraCalibrationData *)cameraCalibrationData { return nil; }
- (AVCaptureDeviceType)sourceDeviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (NSDictionary *)embeddedThumbnailPhotoFormat { return nil; }
- (AVCaptureBracketedStillImageSettings *)bracketSettings { return nil; }
- (NSInteger)sequenceCount { return 1; }
- (AVCaptureLensStabilizationStatus)lensStabilizationStatus { return AVCaptureLensStabilizationStatusUnsupported; }
- (BOOL)isConstantColorFallbackPhoto { return NO; }
- (AVSemanticSegmentationMatte *)semanticSegmentationMatteForType:(AVSemanticSegmentationMatteType)type { return nil; }
- (NSString *)description { return [NSString stringWithFormat:@"<BetterSimPhoto %lu bytes>", (unsigned long)self.data.length]; }
- (BOOL)isEqual:(id)object { return self == object; }
- (NSUInteger)hash { return (NSUInteger)(__bridge void *)self; }
- (void)setImage:(CGImageRef)image {
    if (image) CGImageRetain(image);
    if (_image) CGImageRelease(_image);
    _image = image;
}
- (void)setBuffer:(CVPixelBufferRef)buffer {
    if (buffer) CVPixelBufferRetain(buffer);
    if (_buffer) CVPixelBufferRelease(_buffer);
    _buffer = buffer;
}
@end

#pragma mark - Sessions

static const void *BetterSimInputsKey = &BetterSimInputsKey;
static const void *BetterSimRunningKey = &BetterSimRunningKey;
static const void *BetterSimLayersKey = &BetterSimLayersKey;
static const void *BetterSimSessionKey = &BetterSimSessionKey;
static const void *BetterSimSettingsKey = &BetterSimSettingsKey;
static const void *BetterSimPresetKey = &BetterSimPresetKey;
static const void *BetterSimBusyKey = &BetterSimBusyKey;
static const void *BetterSimContentKey = &BetterSimContentKey;

static NSLock *BetterSimLock;
static NSHashTable<AVCaptureSession *> *BetterSimRunningSessions;
static NSCondition *BetterSimWake;

static NSMutableArray<AVCaptureInput *> *BetterSimInputs(AVCaptureSession *session) {
    @synchronized (session) {
        NSMutableArray *inputs = objc_getAssociatedObject(session, BetterSimInputsKey);
        if (!inputs) {
            inputs = [NSMutableArray array];
            objc_setAssociatedObject(session, BetterSimInputsKey, inputs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return inputs;
    }
}

static BOOL BetterSimUsesCamera(AVCaptureSession *session) {
    if (!session) return NO;
    @synchronized (session) {
        return [objc_getAssociatedObject(session, BetterSimInputsKey) count] > 0;
    }
}

static AVCaptureSession *BetterSimSessionOf(id outputOrLayer) {
    return BetterSimWeak(outputOrLayer, BetterSimSessionKey);
}

static BetterSimCaptureDevice *BetterSimDeviceOf(AVCaptureSession *session) {
    @synchronized (session) {
        for (AVCaptureInput *input in objc_getAssociatedObject(session, BetterSimInputsKey)) {
            if ([input isKindOfClass:BetterSimDeviceInput.class]) return (BetterSimCaptureDevice *)[(BetterSimDeviceInput *)input camera];
        }
    }
    return nil;
}

static NSArray<AVCaptureVideoPreviewLayer *> *BetterSimLayers(AVCaptureSession *session) {
    NSHashTable *layers = objc_getAssociatedObject(session, BetterSimLayersKey);
    @synchronized (layers) {
        return layers.allObjects ?: @[];
    }
}

static void BetterSimRegisterLayer(AVCaptureVideoPreviewLayer *layer, AVCaptureSession *session) {
    BetterSimSetWeak(layer, BetterSimSessionKey, session);
    if (!session) return;
    NSHashTable *layers;
    @synchronized (session) {
        layers = objc_getAssociatedObject(session, BetterSimLayersKey);
        if (!layers) {
            layers = [NSHashTable weakObjectsHashTable];
            objc_setAssociatedObject(session, BetterSimLayersKey, layers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    @synchronized (layers) {
        [layers addObject:layer];
    }
}

static void BetterSimSetRunning(AVCaptureSession *session, BOOL running) {
    BOOL wasRunning = [objc_getAssociatedObject(session, BetterSimRunningKey) boolValue];
    if (wasRunning == running) return;
    [session willChangeValueForKey:@"running"];
    objc_setAssociatedObject(session, BetterSimRunningKey, @(running), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [session didChangeValueForKey:@"running"];
    [BetterSimLock lock];
    if (running) [BetterSimRunningSessions addObject:session]; else [BetterSimRunningSessions removeObject:session];
    [BetterSimLock unlock];
    [BetterSimWake lock];
    [BetterSimWake broadcast];
    [BetterSimWake unlock];
    NSString *name = running ? AVCaptureSessionDidStartRunningNotification : AVCaptureSessionDidStopRunningNotification;
    [NSNotificationCenter.defaultCenter postNotificationName:name object:session];
}

static NSArray<AVCaptureSession *> *BetterSimSessions(void) {
    [BetterSimLock lock];
    NSArray *sessions = BetterSimRunningSessions.allObjects;
    [BetterSimLock unlock];
    return sessions;
}

#pragma mark - Frames

static CGImageRef BetterSimLatest;

static void BetterSimStore(CGImageRef image) {
    [BetterSimLock lock];
    if (image) CGImageRetain(image);
    if (BetterSimLatest) CGImageRelease(BetterSimLatest);
    BetterSimLatest = image;
    [BetterSimLock unlock];
}

/// The newest frame, retained for the caller.
static CGImageRef BetterSimCopyLatest(void) {
    [BetterSimLock lock];
    CGImageRef image = BetterSimLatest;
    if (image) CGImageRetain(image);
    [BetterSimLock unlock];
    return image;
}

/// Crops the middle of the frame for digital zoom, and to portrait when the connection is turned to portrait, so the
/// picture stays upright the way it would on a phone held that way.
static CGImageRef BetterSimCopyShaped(CGImageRef image, CGFloat zoom, BOOL portrait) {
    CGFloat width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGFloat cropWidth = width, cropHeight = height;
    if (portrait && width > height) cropWidth = height * height / width;
    zoom = MAX(zoom, 1);
    cropWidth /= zoom;
    cropHeight /= zoom;
    if (cropWidth >= width - 0.5 && cropHeight >= height - 0.5) return CGImageRetain(image);
    CGRect crop = CGRectIntegral(CGRectMake((width - cropWidth) / 2, (height - cropHeight) / 2, cropWidth, cropHeight));
    return CGImageCreateWithImageInRect(image, crop);
}

static CVPixelBufferRef BetterSimCopyPixelBuffer(CGImageRef image, OSType format, BOOL mirrored) {
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateWithName(kCGColorSpaceSRGB)}]; });
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferCGImageCompatibilityKey: @YES, (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES};
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, (__bridge CFDictionaryRef)attributes, &buffer) != kCVReturnSuccess) return NULL;
    CIImage *source = [CIImage imageWithCGImage:image];
    if (mirrored) source = [source imageByApplyingTransform:CGAffineTransformMake(-1, 0, 0, 1, width, 0)];
    [context render:source toCVPixelBuffer:buffer];
    return buffer;
}

static CMSampleBufferRef BetterSimCopySampleBuffer(CVPixelBufferRef buffer) {
    CMVideoFormatDescriptionRef description = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, buffer, &description) != noErr) return NULL;
    CMSampleTimingInfo timing = {CMTimeMake(1, BetterSimFrameRate), CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, buffer, description, &timing, &sample);
    CFRelease(description);
    return sample;
}

static OSType BetterSimPixelFormat(NSDictionary *settings) {
    NSNumber *format = settings[(id)kCVPixelBufferPixelFormatTypeKey];
    return format ? format.unsignedIntValue : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

static void BetterSimFeed(AVCaptureVideoDataOutput *output, CGImageRef frame, BetterSimCaptureDevice *device) {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = output.sampleBufferDelegate;
    dispatch_queue_t queue = output.sampleBufferCallbackQueue;
    if (!delegate || !queue || ![delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) return;
    @synchronized (output) {
        if ([objc_getAssociatedObject(output, BetterSimBusyKey) boolValue] && output.alwaysDiscardsLateVideoFrames) return;
        objc_setAssociatedObject(output, BetterSimBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BetterSimConnection *connection = BetterSimConnectionFor(output, NO);
    long angle = lround(connection.rotation) % 360;
    CGImageRef shaped = BetterSimCopyShaped(frame, device.videoZoomFactor, angle == 90 || angle == 270);
    CVPixelBufferRef buffer = BetterSimCopyPixelBuffer(shaped, BetterSimPixelFormat(output.videoSettings), connection.isVideoMirrored);
    CGImageRelease(shaped);
    CMSampleBufferRef sample = buffer ? BetterSimCopySampleBuffer(buffer) : NULL;
    if (buffer) CVPixelBufferRelease(buffer);
    if (!sample) {
        @synchronized (output) { objc_setAssociatedObject(output, BetterSimBusyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        return;
    }
    dispatch_async(queue, ^{
        [delegate captureOutput:output didOutputSampleBuffer:sample fromConnection:connection];
        CFRelease(sample);
        @synchronized (output) { objc_setAssociatedObject(output, BetterSimBusyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    });
}

static CALayerContentsGravity BetterSimGravity(AVLayerVideoGravity gravity) {
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) return kCAGravityResizeAspectFill;
    if ([gravity isEqualToString:AVLayerVideoGravityResize]) return kCAGravityResize;
    return kCAGravityResizeAspect;
}

static void BetterSimShow(CGImageRef frame, AVCaptureVideoPreviewLayer *layer, BetterSimCaptureDevice *device) {
    CALayer *content = objc_getAssociatedObject(layer, BetterSimContentKey);
    if (!content) {
        content = [CALayer layer];
        content.name = @"BetterSimCamera";
        content.masksToBounds = YES;
        [layer insertSublayer:content atIndex:0];
        objc_setAssociatedObject(layer, BetterSimContentKey, content, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BetterSimConnection *connection = BetterSimConnectionFor(layer, YES);
    BOOL mirrored = connection.automaticallyAdjustsVideoMirroring ? device.position == AVCaptureDevicePositionFront : connection.isVideoMirrored;
    CGImageRef shaped = BetterSimCopyShaped(frame, device.videoZoomFactor, NO);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    content.frame = layer.bounds;
    content.contentsGravity = BetterSimGravity(layer.videoGravity);
    content.contents = (__bridge id)shaped;
    content.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity;
    [CATransaction commit];
    CGImageRelease(shaped);
}

static void BetterSimDeliver(CGImageRef frame) {
    static atomic_bool previewPending;
    for (AVCaptureSession *session in BetterSimSessions()) {
        BetterSimCaptureDevice *device = BetterSimDeviceOf(session);
        if (!device) continue;
        for (AVCaptureOutput *output in session.outputs) {
            if ([output isKindOfClass:AVCaptureVideoDataOutput.class]) BetterSimFeed((AVCaptureVideoDataOutput *)output, frame, device);
        }
    }
    // Previews are drawn on the main thread, and skip a frame rather than queue up behind a busy one.
    if (atomic_exchange(&previewPending, true)) return;
    CGImageRetain(frame);
    dispatch_async(dispatch_get_main_queue(), ^{
        for (AVCaptureSession *session in BetterSimSessions()) {
            BetterSimCaptureDevice *device = BetterSimDeviceOf(session);
            if (!device) continue;
            for (AVCaptureVideoPreviewLayer *layer in BetterSimLayers(session)) BetterSimShow(frame, layer, device);
        }
        CGImageRelease(frame);
        atomic_store(&previewPending, false);
    });
}

#pragma mark - Stream

static BOOL BetterSimReadFully(int socket, void *buffer, size_t length) {
    size_t done = 0;
    while (done < length) {
        ssize_t count = recv(socket, (uint8_t *)buffer + done, length - done, 0);
        if (count > 0) { done += (size_t)count; continue; }
        if (count < 0 && errno == EINTR) continue;
        // A timeout lets the loop notice when every session has stopped, so the Mac camera can turn off.
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && BetterSimSessions().count > 0) continue;
        return NO;
    }
    return YES;
}

static int BetterSimConnect(void) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)BetterSimCameraPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    struct timeval timeout = {0, 500000};
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    int on = 1;
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    if (connect(sock, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(sock);
        return -1;
    }
    return sock;
}

/// Connects while any session runs, and reads one frame after another. It hangs up when the last session stops.
static void BetterSimStream(void) {
    while (YES) {
        @autoreleasepool {
            [BetterSimWake lock];
            while (BetterSimSessions().count == 0) [BetterSimWake wait];
            [BetterSimWake unlock];
            int sock = BetterSimConnect();
            if (sock < 0) {
                [NSThread sleepForTimeInterval:0.5];
                continue;
            }
            while (BetterSimSessions().count > 0) {
                @autoreleasepool {
                    uint32_t header = 0;
                    if (!BetterSimReadFully(sock, &header, sizeof(header))) break;
                    uint32_t length = ntohl(header);
                    if (length == 0 || length > 32 * 1024 * 1024) break;
                    NSMutableData *jpeg = [NSMutableData dataWithLength:length];
                    if (!BetterSimReadFully(sock, jpeg.mutableBytes, length)) break;
                    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
                    if (!source) continue;
                    CGImageRef frame = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCacheImmediately: @YES});
                    CFRelease(source);
                    if (!frame) continue;
                    BetterSimStore(frame);
                    BetterSimDeliver(frame);
                    CGImageRelease(frame);
                }
            }
            close(sock);
        }
    }
}

#pragma mark - Photos

static NSData *BetterSimEncode(CGImageRef image, AVCapturePhotoSettings *settings) {
    NSString *codec = settings.format[AVVideoCodecKey];
    BOOL heic = [codec isEqualToString:AVVideoCodecTypeHEVC] || [settings.processedFileType isEqualToString:AVFileTypeHEIC];
    NSNumber *quality = settings.format[AVVideoCompressionPropertiesKey][AVVideoQualityKey] ?: @0.9;
    for (UTType *type in heic ? @[UTTypeHEIC, UTTypeJPEG] : @[UTTypeJPEG]) {
        NSMutableData *data = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, (__bridge CFStringRef)type.identifier, 1, NULL);
        if (!destination) continue;
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: quality, (id)kCGImagePropertyOrientation: @1});
        BOOL written = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        if (written) return data;
    }
    return nil;
}

static void BetterSimCapturePhoto(AVCapturePhotoOutput *output, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> delegate) {
    AVCaptureSession *session = BetterSimSessionOf(output);
    BetterSimCaptureDevice *device = BetterSimDeviceOf(session);
    CGImageRef latest = BetterSimCopyLatest();
    CGImageRef image = latest ? BetterSimCopyShaped(latest, device.videoZoomFactor, NO) : NULL;
    if (latest) CGImageRelease(latest);
    BetterSimResolvedSettings *resolved = BetterSimMake(BetterSimResolvedSettings.class);
    resolved.identifier = settings.uniqueID;
    resolved.dimensions = image ? (CMVideoDimensions){(int32_t)CGImageGetWidth(image), (int32_t)CGImageGetHeight(image)} : (CMVideoDimensions){0, 0};
    BetterSimPhoto *photo = BetterSimMake(BetterSimPhoto.class);
    photo.settings = resolved;
    photo.time = CMClockGetTime(CMClockGetHostTimeClock());
    NSError *error = nil;
    if (image) {
        photo.image = image;
        if (settings.format[(id)kCVPixelBufferPixelFormatTypeKey]) {
            CVPixelBufferRef buffer = BetterSimCopyPixelBuffer(image, [settings.format[(id)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue], NO);
            photo.buffer = buffer;
            if (buffer) CVPixelBufferRelease(buffer);
        } else {
            photo.data = BetterSimEncode(image, settings);
        }
        CGImageRelease(image);
    } else {
        error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorUnknown userInfo:@{NSLocalizedDescriptionKey: @"BetterSim hasn't received a camera frame yet."}];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([delegate respondsToSelector:@selector(captureOutput:willBeginCaptureForResolvedSettings:)]) [delegate captureOutput:output willBeginCaptureForResolvedSettings:resolved];
        if ([delegate respondsToSelector:@selector(captureOutput:willCapturePhotoForResolvedSettings:)]) [delegate captureOutput:output willCapturePhotoForResolvedSettings:resolved];
        if ([delegate respondsToSelector:@selector(captureOutput:didCapturePhotoForResolvedSettings:)]) [delegate captureOutput:output didCapturePhotoForResolvedSettings:resolved];
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) [delegate captureOutput:output didFinishProcessingPhoto:photo error:error];
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]) [delegate captureOutput:output didFinishCaptureForResolvedSettings:resolved error:error];
    });
}

#pragma mark - Swizzling

/// AVFoundation calls some of the same methods inside itself, and would trip over the fakes' missing private state.
/// So only calls from the app itself see the pretend camera, and AVFoundation sees the Simulator as it is.
static BOOL BetterSimInternal(const void *caller) {
    static const char *const frameworks[] = {
        "/AVFCapture.framework/", "/AVFCore.framework/", "/AVFoundation.framework/AVFoundation", "/CoreMedia.framework/",
        "/MediaToolbox.framework/", "/Celestial.framework/", NULL,
    };
    return BetterSimCalledFrom(caller, frameworks);
}

#define BETTERSIM_INTERNAL BetterSimInternal(__builtin_return_address(0))

static BOOL BetterSimIsCameraType(AVCaptureDeviceType type) {
    return ![type containsString:@"Microphone"] && ![type containsString:@"External"];
}

static NSArray<AVCaptureDevice *> *BetterSimCameras(AVCaptureDevicePosition position) {
    if (position == AVCaptureDevicePositionBack) return @[BetterSimCamera(AVCaptureDevicePositionBack)];
    if (position == AVCaptureDevicePositionFront) return @[BetterSimCamera(AVCaptureDevicePositionFront)];
    return @[BetterSimCamera(AVCaptureDevicePositionBack), BetterSimCamera(AVCaptureDevicePositionFront)];
}

static const void *BetterSimDiscoveryKey = &BetterSimDiscoveryKey;

typedef id __attribute__((ns_returns_retained)) (*BetterSimInputInitIMP)(__unsafe_unretained id, SEL, AVCaptureDevice *, NSError * __autoreleasing *);
static BetterSimInputInitIMP BetterSimOriginalInputInit;

/// For the pretend camera, `self` is an allocation AVFoundation never set up, so it's left alone, not released.
static id BetterSimInputInit(__unsafe_unretained id self, SEL _cmd, AVCaptureDevice *device, NSError * __autoreleasing *error) __attribute__((ns_returns_retained)) {
    if ([device isKindOfClass:BetterSimCaptureDevice.class]) return BetterSimMakeInput(device);
    return BetterSimOriginalInputInit(self, _cmd, device, error);
}

static void BetterSimInstallDevices(void) {
    __block IMP authorization = BetterSimReplaceClassMethod(AVCaptureDevice.class, @selector(authorizationStatusForMediaType:), ^AVAuthorizationStatus(id cls, AVMediaType type) {
        if (!BETTERSIM_INTERNAL && [type isEqualToString:AVMediaTypeVideo]) return AVAuthorizationStatusAuthorized;
        return ((AVAuthorizationStatus (*)(id, SEL, AVMediaType))authorization)(cls, @selector(authorizationStatusForMediaType:), type);
    });
    __block IMP request = BetterSimReplaceClassMethod(AVCaptureDevice.class, @selector(requestAccessForMediaType:completionHandler:), ^(id cls, AVMediaType type, void (^handler)(BOOL)) {
        if (![type isEqualToString:AVMediaTypeVideo]) return ((void (*)(id, SEL, AVMediaType, id))request)(cls, @selector(requestAccessForMediaType:completionHandler:), type, handler);
        if (handler) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ handler(YES); });
    });
    __block IMP defaultForType = BetterSimReplaceClassMethod(AVCaptureDevice.class, @selector(defaultDeviceWithMediaType:), ^AVCaptureDevice *(id cls, AVMediaType type) {
        if (!BETTERSIM_INTERNAL && [type isEqualToString:AVMediaTypeVideo]) return BetterSimCamera(AVCaptureDevicePositionBack);
        return ((AVCaptureDevice *(*)(id, SEL, AVMediaType))defaultForType)(cls, @selector(defaultDeviceWithMediaType:), type);
    });
    __block IMP defaultForPosition = BetterSimReplaceClassMethod(AVCaptureDevice.class, @selector(defaultDeviceWithDeviceType:mediaType:position:), ^AVCaptureDevice *(id cls, AVCaptureDeviceType deviceType, AVMediaType type, AVCaptureDevicePosition position) {
        if (!BETTERSIM_INTERNAL && (!type || [type isEqualToString:AVMediaTypeVideo]) && BetterSimIsCameraType(deviceType)) {
            return BetterSimCamera(position == AVCaptureDevicePositionFront ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack);
        }
        return ((AVCaptureDevice *(*)(id, SEL, AVCaptureDeviceType, AVMediaType, AVCaptureDevicePosition))defaultForPosition)(cls, @selector(defaultDeviceWithDeviceType:mediaType:position:), deviceType, type, position);
    });
    __block IMP devicesForType = BetterSimReplaceClassMethod(AVCaptureDevice.class, @selector(devicesWithMediaType:), ^NSArray *(id cls, AVMediaType type) {
        if (!BETTERSIM_INTERNAL && [type isEqualToString:AVMediaTypeVideo]) return BetterSimCameras(AVCaptureDevicePositionUnspecified);
        return ((NSArray *(*)(id, SEL, AVMediaType))devicesForType)(cls, @selector(devicesWithMediaType:), type);
    });
    __block IMP allDevices = BetterSimReplaceClassMethod(AVCaptureDevice.class, @selector(devices), ^NSArray *(id cls) {
        NSArray *devices = ((NSArray *(*)(id, SEL))allDevices)(cls, @selector(devices)) ?: @[];
        if (BETTERSIM_INTERNAL) return devices;
        return [devices arrayByAddingObjectsFromArray:BetterSimCameras(AVCaptureDevicePositionUnspecified)];
    });
    __block IMP systemPreferred = BetterSimReplaceClassMethod(AVCaptureDevice.class, @selector(systemPreferredCamera), ^AVCaptureDevice *(id cls) {
        if (BETTERSIM_INTERNAL) return ((id (*)(id, SEL))systemPreferred)(cls, @selector(systemPreferredCamera));
        return BetterSimCamera(AVCaptureDevicePositionBack);
    });
    __block IMP userPreferred = BetterSimReplaceClassMethod(AVCaptureDevice.class, @selector(userPreferredCamera), ^AVCaptureDevice *(id cls) {
        if (BETTERSIM_INTERNAL) return ((id (*)(id, SEL))userPreferred)(cls, @selector(userPreferredCamera));
        return BetterSimCamera(AVCaptureDevicePositionBack);
    });

    __block IMP discovery = BetterSimReplaceClassMethod(AVCaptureDeviceDiscoverySession.class, @selector(discoverySessionWithDeviceTypes:mediaType:position:), ^AVCaptureDeviceDiscoverySession *(id cls, NSArray *types, AVMediaType type, AVCaptureDevicePosition position) {
        AVCaptureDeviceDiscoverySession *session = ((id (*)(id, SEL, NSArray *, AVMediaType, AVCaptureDevicePosition))discovery)(cls, @selector(discoverySessionWithDeviceTypes:mediaType:position:), types, type, position);
        BOOL wantsCamera = (!type || [type isEqualToString:AVMediaTypeVideo]) && [types indexOfObjectPassingTest:^BOOL(AVCaptureDeviceType deviceType, NSUInteger index, BOOL *stop) { return BetterSimIsCameraType(deviceType); }] != NSNotFound;
        if (session && wantsCamera) objc_setAssociatedObject(session, BetterSimDiscoveryKey, @(position), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return session;
    });
    __block IMP discovered = BetterSimReplace(AVCaptureDeviceDiscoverySession.class, @selector(devices), ^NSArray *(AVCaptureDeviceDiscoverySession *session) {
        NSNumber *position = objc_getAssociatedObject(session, BetterSimDiscoveryKey);
        NSArray *devices = ((NSArray *(*)(id, SEL))discovered)(session, @selector(devices)) ?: @[];
        if (!position || BETTERSIM_INTERNAL) return devices;
        return [devices arrayByAddingObjectsFromArray:BetterSimCameras((AVCaptureDevicePosition)position.integerValue)];
    });
    BetterSimReplace(AVCaptureDeviceDiscoverySession.class, @selector(supportedMultiCamDeviceSets), ^NSArray *(id session) { return @[]; });

    Method init = class_getInstanceMethod(AVCaptureDeviceInput.class, @selector(initWithDevice:error:));
    BetterSimOriginalInputInit = (BetterSimInputInitIMP)method_getImplementation(init);
    method_setImplementation(init, (IMP)BetterSimInputInit);
    __block IMP factory = BetterSimReplaceClassMethod(AVCaptureDeviceInput.class, @selector(deviceInputWithDevice:error:), ^id(id cls, AVCaptureDevice *device, NSError * __autoreleasing *error) {
        if ([device isKindOfClass:BetterSimCaptureDevice.class]) return BetterSimMakeInput(device);
        return ((id (*)(id, SEL, AVCaptureDevice *, NSError **))factory)(cls, @selector(deviceInputWithDevice:error:), device, error);
    });
}

static void BetterSimInstallSession(void) {
    Class session = AVCaptureSession.class;
    __block IMP canAddInput = BetterSimReplace(session, @selector(canAddInput:), ^BOOL(AVCaptureSession *self, AVCaptureInput *input) {
        if ([input isKindOfClass:BetterSimDeviceInput.class]) return ![BetterSimInputs(self) containsObject:input];
        return ((BOOL (*)(id, SEL, id))canAddInput)(self, @selector(canAddInput:), input);
    });
    __block IMP addInput = BetterSimReplace(session, @selector(addInput:), ^(AVCaptureSession *self, AVCaptureInput *input) {
        if ([input isKindOfClass:BetterSimDeviceInput.class]) {
            @synchronized (self) { if (![BetterSimInputs(self) containsObject:input]) [BetterSimInputs(self) addObject:input]; }
            return;
        }
        ((void (*)(id, SEL, id))addInput)(self, @selector(addInput:), input);
    });
    __block IMP addInputWithNoConnections = BetterSimReplace(session, @selector(addInputWithNoConnections:), ^(AVCaptureSession *self, AVCaptureInput *input) {
        if ([input isKindOfClass:BetterSimDeviceInput.class]) {
            @synchronized (self) { if (![BetterSimInputs(self) containsObject:input]) [BetterSimInputs(self) addObject:input]; }
            return;
        }
        ((void (*)(id, SEL, id))addInputWithNoConnections)(self, @selector(addInputWithNoConnections:), input);
    });
    __block IMP removeInput = BetterSimReplace(session, @selector(removeInput:), ^(AVCaptureSession *self, AVCaptureInput *input) {
        if ([input isKindOfClass:BetterSimDeviceInput.class]) {
            @synchronized (self) { [BetterSimInputs(self) removeObject:input]; }
            return;
        }
        ((void (*)(id, SEL, id))removeInput)(self, @selector(removeInput:), input);
    });
    __block IMP inputs = BetterSimReplace(session, @selector(inputs), ^NSArray *(AVCaptureSession *self) {
        NSArray *real = ((NSArray *(*)(id, SEL))inputs)(self, @selector(inputs)) ?: @[];
        if (BETTERSIM_INTERNAL) return real;
        @synchronized (self) {
            NSArray *fake = objc_getAssociatedObject(self, BetterSimInputsKey);
            return fake.count ? [real arrayByAddingObjectsFromArray:fake] : real;
        }
    });
    __block IMP addOutput = BetterSimReplace(session, @selector(addOutput:), ^(AVCaptureSession *self, AVCaptureOutput *output) {
        BetterSimSetWeak(output, BetterSimSessionKey, self);
        ((void (*)(id, SEL, id))addOutput)(self, @selector(addOutput:), output);
    });
    __block IMP addOutputWithNoConnections = BetterSimReplace(session, @selector(addOutputWithNoConnections:), ^(AVCaptureSession *self, AVCaptureOutput *output) {
        BetterSimSetWeak(output, BetterSimSessionKey, self);
        ((void (*)(id, SEL, id))addOutputWithNoConnections)(self, @selector(addOutputWithNoConnections:), output);
    });
    __block IMP canAddOutput = BetterSimReplace(session, @selector(canAddOutput:), ^BOOL(AVCaptureSession *self, AVCaptureOutput *output) {
        if (BetterSimUsesCamera(self) && ![self.outputs containsObject:output]) return YES;
        return ((BOOL (*)(id, SEL, id))canAddOutput)(self, @selector(canAddOutput:), output);
    });
    __block IMP start = BetterSimReplace(session, @selector(startRunning), ^(AVCaptureSession *self) {
        if (BetterSimUsesCamera(self)) return BetterSimSetRunning(self, YES);
        ((void (*)(id, SEL))start)(self, @selector(startRunning));
    });
    __block IMP stop = BetterSimReplace(session, @selector(stopRunning), ^(AVCaptureSession *self) {
        if (BetterSimUsesCamera(self)) return BetterSimSetRunning(self, NO);
        ((void (*)(id, SEL))stop)(self, @selector(stopRunning));
    });
    __block IMP running = BetterSimReplace(session, @selector(isRunning), ^BOOL(AVCaptureSession *self) {
        if (BetterSimUsesCamera(self) && !BETTERSIM_INTERNAL) return [objc_getAssociatedObject(self, BetterSimRunningKey) boolValue];
        return ((BOOL (*)(id, SEL))running)(self, @selector(isRunning));
    });
    __block IMP interrupted = BetterSimReplace(session, @selector(isInterrupted), ^BOOL(AVCaptureSession *self) {
        if (BetterSimUsesCamera(self)) return NO;
        return ((BOOL (*)(id, SEL))interrupted)(self, @selector(isInterrupted));
    });
    __block IMP canSetPreset = BetterSimReplace(session, @selector(canSetSessionPreset:), ^BOOL(AVCaptureSession *self, AVCaptureSessionPreset preset) {
        if (BetterSimUsesCamera(self)) return YES;
        return ((BOOL (*)(id, SEL, id))canSetPreset)(self, @selector(canSetSessionPreset:), preset);
    });
    __block IMP setPreset = BetterSimReplace(session, @selector(setSessionPreset:), ^(AVCaptureSession *self, AVCaptureSessionPreset preset) {
        objc_setAssociatedObject(self, BetterSimPresetKey, preset, OBJC_ASSOCIATION_COPY_NONATOMIC);
        @try { ((void (*)(id, SEL, id))setPreset)(self, @selector(setSessionPreset:), preset); } @catch (NSException *exception) {}
    });
    __block IMP preset = BetterSimReplace(session, @selector(sessionPreset), ^AVCaptureSessionPreset(AVCaptureSession *self) {
        if (BetterSimUsesCamera(self)) return objc_getAssociatedObject(self, BetterSimPresetKey) ?: AVCaptureSessionPresetHigh;
        return ((id (*)(id, SEL))preset)(self, @selector(sessionPreset));
    });
}

static void BetterSimInstallOutputs(void) {
    __block IMP connection = BetterSimReplace(AVCaptureOutput.class, @selector(connectionWithMediaType:), ^AVCaptureConnection *(AVCaptureOutput *self, AVMediaType type) {
        if (!BETTERSIM_INTERNAL && BetterSimUsesCamera(BetterSimSessionOf(self)) && [type isEqualToString:AVMediaTypeVideo]) return BetterSimConnectionFor(self, NO);
        return ((id (*)(id, SEL, id))connection)(self, @selector(connectionWithMediaType:), type);
    });
    __block IMP connections = BetterSimReplace(AVCaptureOutput.class, @selector(connections), ^NSArray *(AVCaptureOutput *self) {
        if (!BETTERSIM_INTERNAL && BetterSimUsesCamera(BetterSimSessionOf(self))) return @[BetterSimConnectionFor(self, NO)];
        return ((NSArray *(*)(id, SEL))connections)(self, @selector(connections));
    });

    Class video = AVCaptureVideoDataOutput.class;
    __block IMP setSettings = BetterSimReplace(video, @selector(setVideoSettings:), ^(AVCaptureVideoDataOutput *self, NSDictionary *settings) {
        objc_setAssociatedObject(self, BetterSimSettingsKey, settings, OBJC_ASSOCIATION_COPY_NONATOMIC);
        @try { ((void (*)(id, SEL, id))setSettings)(self, @selector(setVideoSettings:), settings); } @catch (NSException *exception) {}
    });
    __block IMP settings = BetterSimReplace(video, @selector(videoSettings), ^NSDictionary *(AVCaptureVideoDataOutput *self) {
        return objc_getAssociatedObject(self, BetterSimSettingsKey) ?: ((id (*)(id, SEL))settings)(self, @selector(videoSettings));
    });
    __block IMP formats = BetterSimReplace(video, @selector(availableVideoCVPixelFormatTypes), ^NSArray *(AVCaptureVideoDataOutput *self) {
        NSArray *real = ((NSArray *(*)(id, SEL))formats)(self, @selector(availableVideoCVPixelFormatTypes));
        return real.count ? real : @[@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), @(kCVPixelFormatType_32BGRA)];
    });
    __block IMP recommended = BetterSimReplace(video, @selector(recommendedVideoSettingsForAssetWriterWithOutputFileType:), ^NSDictionary *(AVCaptureVideoDataOutput *self, AVFileType type) {
        NSDictionary *real = ((NSDictionary *(*)(id, SEL, id))recommended)(self, @selector(recommendedVideoSettingsForAssetWriterWithOutputFileType:), type);
        return real ?: @{AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(BetterSimWidth), AVVideoHeightKey: @(BetterSimHeight)};
    });

    Class photo = AVCapturePhotoOutput.class;
    __block IMP capture = BetterSimReplace(photo, @selector(capturePhotoWithSettings:delegate:), ^(AVCapturePhotoOutput *self, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> delegate) {
        if (BetterSimUsesCamera(BetterSimSessionOf(self))) return BetterSimCapturePhoto(self, settings, delegate);
        ((void (*)(id, SEL, id, id))capture)(self, @selector(capturePhotoWithSettings:delegate:), settings, delegate);
    });
    __block IMP codecs = BetterSimReplace(photo, @selector(availablePhotoCodecTypes), ^NSArray *(AVCapturePhotoOutput *self) {
        NSArray *real = ((NSArray *(*)(id, SEL))codecs)(self, @selector(availablePhotoCodecTypes));
        return real.count ? real : @[AVVideoCodecTypeHEVC, AVVideoCodecTypeJPEG];
    });
    __block IMP pixelFormats = BetterSimReplace(photo, @selector(availablePhotoPixelFormatTypes), ^NSArray *(AVCapturePhotoOutput *self) {
        NSArray *real = ((NSArray *(*)(id, SEL))pixelFormats)(self, @selector(availablePhotoPixelFormatTypes));
        return real.count ? real : @[@(kCVPixelFormatType_32BGRA), @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)];
    });
    __block IMP fileTypes = BetterSimReplace(photo, @selector(availablePhotoFileTypes), ^NSArray *(AVCapturePhotoOutput *self) {
        NSArray *real = ((NSArray *(*)(id, SEL))fileTypes)(self, @selector(availablePhotoFileTypes));
        return real.count ? real : @[AVFileTypeHEIC, AVFileTypeJPEG];
    });
    __block IMP flashModes = BetterSimReplace(photo, @selector(supportedFlashModes), ^NSArray *(AVCapturePhotoOutput *self) {
        NSArray *real = ((NSArray *(*)(id, SEL))flashModes)(self, @selector(supportedFlashModes));
        return real.count ? real : @[@(AVCaptureFlashModeOff)];
    });
    // Asking for features the Simulator lacks would throw. The pretend camera has none of them either, so the
    // request is quietly dropped, as if it took.
    for (NSString *name in @[@"setHighResolutionCaptureEnabled:", @"setLivePhotoCaptureEnabled:", @"setDepthDataDeliveryEnabled:",
                             @"setPortraitEffectsMatteDeliveryEnabled:", @"setContentAwareDistortionCorrectionEnabled:",
                             @"setZeroShutterLagEnabled:", @"setResponsiveCaptureEnabled:", @"setFastCapturePrioritizationEnabled:"]) {
        SEL selector = NSSelectorFromString(name);
        __block IMP original = BetterSimReplace(photo, selector, ^(AVCapturePhotoOutput *self, BOOL enabled) {
            @try { ((void (*)(id, SEL, BOOL))original)(self, selector, enabled); } @catch (NSException *exception) {}
        });
    }
    __block IMP setQuality = BetterSimReplace(photo, @selector(setMaxPhotoQualityPrioritization:), ^(AVCapturePhotoOutput *self, AVCapturePhotoQualityPrioritization quality) {
        @try { ((void (*)(id, SEL, AVCapturePhotoQualityPrioritization))setQuality)(self, @selector(setMaxPhotoQualityPrioritization:), quality); } @catch (NSException *exception) {}
    });
    __block IMP setDimensions = BetterSimReplace(photo, @selector(setMaxPhotoDimensions:), ^(AVCapturePhotoOutput *self, CMVideoDimensions dimensions) {
        @try { ((void (*)(id, SEL, CMVideoDimensions))setDimensions)(self, @selector(setMaxPhotoDimensions:), dimensions); } @catch (NSException *exception) {}
    });
    __block IMP previewFormats = BetterSimReplace(AVCapturePhotoSettings.class, @selector(availablePreviewPhotoPixelFormatTypes), ^NSArray *(AVCapturePhotoSettings *self) {
        NSArray *real = ((NSArray *(*)(id, SEL))previewFormats)(self, @selector(availablePreviewPhotoPixelFormatTypes));
        return real.count ? real : @[@(kCVPixelFormatType_32BGRA)];
    });
}

static void BetterSimInstallPreview(void) {
    Class preview = AVCaptureVideoPreviewLayer.class;
    __block IMP initWithSession = BetterSimReplace(preview, @selector(initWithSession:), ^id(AVCaptureVideoPreviewLayer *self, AVCaptureSession *session) {
        AVCaptureVideoPreviewLayer *layer = ((id (*)(id, SEL, id))initWithSession)(self, @selector(initWithSession:), session);
        if (layer) BetterSimRegisterLayer(layer, session);
        return layer;
    });
    __block IMP initWithNoConnection = BetterSimReplace(preview, @selector(initWithSessionWithNoConnection:), ^id(AVCaptureVideoPreviewLayer *self, AVCaptureSession *session) {
        AVCaptureVideoPreviewLayer *layer = ((id (*)(id, SEL, id))initWithNoConnection)(self, @selector(initWithSessionWithNoConnection:), session);
        if (layer) BetterSimRegisterLayer(layer, session);
        return layer;
    });
    __block IMP setSession = BetterSimReplace(preview, @selector(setSession:), ^(AVCaptureVideoPreviewLayer *self, AVCaptureSession *session) {
        ((void (*)(id, SEL, id))setSession)(self, @selector(setSession:), session);
        BetterSimRegisterLayer(self, session);
    });
    __block IMP setSessionWithNoConnection = BetterSimReplace(preview, @selector(setSessionWithNoConnection:), ^(AVCaptureVideoPreviewLayer *self, AVCaptureSession *session) {
        ((void (*)(id, SEL, id))setSessionWithNoConnection)(self, @selector(setSessionWithNoConnection:), session);
        BetterSimRegisterLayer(self, session);
    });
    __block IMP layerConnection = BetterSimReplace(preview, @selector(connection), ^AVCaptureConnection *(AVCaptureVideoPreviewLayer *self) {
        if (!BETTERSIM_INTERNAL && BetterSimUsesCamera(BetterSimSessionOf(self))) return BetterSimConnectionFor(self, YES);
        return ((id (*)(id, SEL))layerConnection)(self, @selector(connection));
    });
    __block IMP toDevice = BetterSimReplace(preview, @selector(captureDevicePointOfInterestForPoint:), ^CGPoint(AVCaptureVideoPreviewLayer *self, CGPoint point) {
        if (!BetterSimUsesCamera(BetterSimSessionOf(self))) return ((CGPoint (*)(id, SEL, CGPoint))toDevice)(self, @selector(captureDevicePointOfInterestForPoint:), point);
        CGRect bounds = self.bounds;
        return CGPointMake(bounds.size.width > 0 ? point.x / bounds.size.width : 0.5, bounds.size.height > 0 ? point.y / bounds.size.height : 0.5);
    });
    __block IMP toLayer = BetterSimReplace(preview, @selector(pointForCaptureDevicePointOfInterest:), ^CGPoint(AVCaptureVideoPreviewLayer *self, CGPoint point) {
        if (!BetterSimUsesCamera(BetterSimSessionOf(self))) return ((CGPoint (*)(id, SEL, CGPoint))toLayer)(self, @selector(pointForCaptureDevicePointOfInterest:), point);
        return CGPointMake(point.x * self.bounds.size.width, point.y * self.bounds.size.height);
    });
    __block IMP toRect = BetterSimReplace(preview, @selector(metadataOutputRectOfInterestForRect:), ^CGRect(AVCaptureVideoPreviewLayer *self, CGRect rect) {
        if (!BetterSimUsesCamera(BetterSimSessionOf(self))) return ((CGRect (*)(id, SEL, CGRect))toRect)(self, @selector(metadataOutputRectOfInterestForRect:), rect);
        CGSize size = self.bounds.size;
        if (size.width <= 0 || size.height <= 0) return CGRectMake(0, 0, 1, 1);
        return CGRectMake(rect.origin.x / size.width, rect.origin.y / size.height, rect.size.width / size.width, rect.size.height / size.height);
    });
    __block IMP fromRect = BetterSimReplace(preview, @selector(rectForMetadataOutputRectOfInterest:), ^CGRect(AVCaptureVideoPreviewLayer *self, CGRect rect) {
        if (!BetterSimUsesCamera(BetterSimSessionOf(self))) return ((CGRect (*)(id, SEL, CGRect))fromRect)(self, @selector(rectForMetadataOutputRectOfInterest:), rect);
        CGSize size = self.bounds.size;
        return CGRectMake(rect.origin.x * size.width, rect.origin.y * size.height, rect.size.width * size.width, rect.size.height * size.height);
    });
}

__attribute__((constructor))
static void BetterSimCameraLoad(void) {
    const char *port = getenv("BETTERSIM_CAMERA_PORT");
    long number = port ? strtol(port, NULL, 10) : 0;
    if (number <= 0 || number > 65535) return;
    @autoreleasepool {
        BetterSimCameraPort = number;
        BetterSimLock = [NSLock new];
        BetterSimWake = [NSCondition new];
        BetterSimRunningSessions = [NSHashTable weakObjectsHashTable];
        BetterSimInstallDevices();
        BetterSimInstallSession();
        BetterSimInstallOutputs();
        BetterSimInstallPreview();
        NSThread *thread = [[NSThread alloc] initWithBlock:^{ BetterSimStream(); }];
        thread.name = @"local.bettersim.camera";
        thread.qualityOfService = NSQualityOfServiceUserInitiated;
        [thread start];
    }
}
