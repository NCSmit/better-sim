// Lets apps use UIImagePickerController's camera in the Simulator, which has none. When an app picks the camera
// source, the picker stays on its default source, and BetterSim's own camera screen is shown in its place. That screen
// uses the pretend camera from BetterSimCamera.m the way any app would, and hands the photo to the picker's delegate
// as UIKit's camera does. Like the rest of the camera, this only happens when BETTERSIM_CAMERA_PORT is set.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "BetterSimSwizzle.h"

static const void *BetterSimUsesCameraKey = &BetterSimUsesCameraKey;
static const void *BetterSimCameraDeviceKey = &BetterSimCameraDeviceKey;
static const void *BetterSimCaptureModeKey = &BetterSimCaptureModeKey;
static const void *BetterSimFlashModeKey = &BetterSimFlashModeKey;
static const void *BetterSimShowsControlsKey = &BetterSimShowsControlsKey;
static const void *BetterSimOverlayKey = &BetterSimOverlayKey;
static const void *BetterSimTransformKey = &BetterSimTransformKey;
static const void *BetterSimScreenKey = &BetterSimScreenKey;

static BOOL BetterSimPickerUsesCamera(UIImagePickerController *picker) {
    return [objc_getAssociatedObject(picker, BetterSimUsesCameraKey) boolValue];
}

/// UIKit asks some of the same questions inside itself, and keeps getting the Simulator's real answers.
static BOOL BetterSimFromUIKit(const void *caller) {
    static const char *const frameworks[] = {"/UIKitCore.framework/", "/UIKit.framework/", "/PhotosUI.framework/", "/PhotoLibrary", NULL};
    return BetterSimCalledFrom(caller, frameworks);
}

@interface BetterSimCameraScreen : UIViewController <AVCapturePhotoCaptureDelegate>
/// Held strongly, because a picker presented on its own isn't kept by anything else once the screen takes its place.
/// Let go of when the screen closes.
@property (nonatomic, strong) UIImagePickerController *picker;
- (instancetype)initWithPicker:(UIImagePickerController *)picker;
- (void)shoot;
@end

@implementation BetterSimCameraScreen {
    AVCaptureSession *_session;
    AVCapturePhotoOutput *_output;
    AVCaptureDeviceInput *_input;
    AVCaptureVideoPreviewLayer *_previewLayer;
    dispatch_queue_t _queue;
    UIView *_preview;
    UIImageView *_review;
    UIButton *_shutter;
    UIButton *_cancel;
    UIButton *_flip;
    UIButton *_retake;
    UIButton *_use;
    UIImage *_photo;
    UIImagePickerControllerCameraDevice _device;
}

- (instancetype)initWithPicker:(UIImagePickerController *)picker {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _picker = picker;
        _device = [objc_getAssociatedObject(picker, BetterSimCameraDeviceKey) integerValue];
        _session = [AVCaptureSession new];
        _output = [AVCapturePhotoOutput new];
        _queue = dispatch_queue_create("local.bettersim.camera.picker", DISPATCH_QUEUE_SERIAL);
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _preview = [UIView new];
    _preview.clipsToBounds = YES;
    _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:_session];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [_preview.layer addSublayer:_previewLayer];
    [self.view addSubview:_preview];
    _review = [UIImageView new];
    _review.contentMode = UIViewContentModeScaleAspectFill;
    _review.clipsToBounds = YES;
    _review.hidden = YES;
    [self.view addSubview:_review];

    _shutter = [UIButton buttonWithType:UIButtonTypeCustom];
    _shutter.accessibilityLabel = @"Take Picture";
    CALayer *ring = [CALayer layer];
    ring.frame = CGRectMake(0, 0, 74, 74);
    ring.cornerRadius = 37;
    ring.borderWidth = 4;
    ring.borderColor = UIColor.whiteColor.CGColor;
    CALayer *dot = [CALayer layer];
    dot.frame = CGRectMake(8, 8, 58, 58);
    dot.cornerRadius = 29;
    dot.backgroundColor = UIColor.whiteColor.CGColor;
    [_shutter.layer addSublayer:ring];
    [_shutter.layer addSublayer:dot];
    [_shutter addTarget:self action:@selector(shoot) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_shutter];

    _cancel = [self button:@"Cancel" action:@selector(cancel)];
    _retake = [self button:@"Retake" action:@selector(retake)];
    _use = [self button:@"Use Photo" action:@selector(usePhoto)];
    _flip = [UIButton buttonWithType:UIButtonTypeSystem];
    [_flip setImage:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath.camera"] forState:UIControlStateNormal];
    _flip.tintColor = UIColor.whiteColor;
    _flip.accessibilityLabel = @"Switch Camera";
    [_flip addTarget:self action:@selector(flip) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_flip];
    [self showReview:NO];
    [self configure];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat width = bounds.size.width;
    CGFloat top = safe.top + 44;
    CGFloat height = MIN(width * 4 / 3, bounds.size.height - top - safe.bottom - 120);
    _preview.frame = CGRectMake(0, top, width, height);
    _previewLayer.frame = _preview.bounds;
    _review.frame = _preview.frame;
    CGFloat bar = top + height;
    CGFloat middle = bar + (bounds.size.height - safe.bottom - bar) / 2;
    _shutter.frame = CGRectMake(width / 2 - 37, middle - 37, 74, 74);
    _cancel.frame = CGRectMake(16, middle - 22, 90, 44);
    _retake.frame = CGRectMake(16, middle - 22, 90, 44);
    _use.frame = CGRectMake(width - 116, middle - 22, 100, 44);
    _flip.frame = CGRectMake(width - 66, middle - 22, 44, 44);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    AVCaptureSession *session = _session;
    dispatch_async(_queue, ^{ [session stopRunning]; });
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (!self.isBeingDismissed && self.presentingViewController) return;
    UIImagePickerController *picker = self.picker;
    if (picker && objc_getAssociatedObject(picker, BetterSimScreenKey) == self) {
        objc_setAssociatedObject(picker, BetterSimScreenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    self.picker = nil;
}

- (void)configure {
    AVCaptureDevicePosition position = _device == UIImagePickerControllerCameraDeviceFront ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
    dispatch_async(_queue, ^{
        AVCaptureDevice *camera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:position];
        AVCaptureDeviceInput *input = camera ? [AVCaptureDeviceInput deviceInputWithDevice:camera error:nil] : nil;
        [self->_session beginConfiguration];
        if (self->_input) [self->_session removeInput:self->_input];
        if (input && [self->_session canAddInput:input]) {
            [self->_session addInput:input];
            self->_input = input;
        }
        if (![self->_session.outputs containsObject:self->_output] && [self->_session canAddOutput:self->_output]) [self->_session addOutput:self->_output];
        [self->_session commitConfiguration];
        if (!self->_session.isRunning) [self->_session startRunning];
    });
}

- (void)showReview:(BOOL)review {
    _review.hidden = !review;
    _shutter.hidden = review;
    _cancel.hidden = review;
    _flip.hidden = review;
    _retake.hidden = !review;
    _use.hidden = !review;
}

- (void)shoot {
    _shutter.enabled = NO;
    [_output capturePhotoWithSettings:[AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey: AVVideoCodecTypeJPEG}] delegate:self];
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    NSData *data = photo.fileDataRepresentation;
    UIImage *image = data ? [UIImage imageWithData:data] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_shutter.enabled = YES;
        if (!image) return;
        self->_photo = [self portrait:image];
        self->_review.image = self->_photo;
        [self showReview:YES];
    });
}

/// The middle of the frame in the 3:4 shape of a phone photo, which is also what the preview shows.
- (UIImage *)portrait:(UIImage *)image {
    CGImageRef full = image.CGImage;
    CGFloat width = CGImageGetWidth(full), height = CGImageGetHeight(full);
    CGFloat cropWidth = MIN(width, height * 3 / 4);
    CGImageRef cropped = CGImageCreateWithImageInRect(full, CGRectIntegral(CGRectMake((width - cropWidth) / 2, 0, cropWidth, height)));
    UIImage *result = [UIImage imageWithCGImage:cropped scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cropped);
    return result;
}

- (void)retake {
    _photo = nil;
    [self showReview:NO];
}

- (void)flip {
    _device = _device == UIImagePickerControllerCameraDeviceFront ? UIImagePickerControllerCameraDeviceRear : UIImagePickerControllerCameraDeviceFront;
    UIImagePickerController *picker = self.picker;
    if (picker) objc_setAssociatedObject(picker, BetterSimCameraDeviceKey, @(_device), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self configure];
}

- (void)usePhoto {
    UIImagePickerController *picker = self.picker;
    UIImage *photo = _photo;
    if (!picker || !photo) return [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    NSMutableDictionary *info = [@{
        UIImagePickerControllerMediaType: UTTypeImage.identifier,
        UIImagePickerControllerOriginalImage: photo,
        UIImagePickerControllerMediaMetadata: @{
            (NSString *)kCGImagePropertyOrientation: @1,
            (NSString *)kCGImagePropertyPixelWidth: @(photo.size.width),
            (NSString *)kCGImagePropertyPixelHeight: @(photo.size.height),
        },
    } mutableCopy];
    // UIKit lets people crop to a square first. The middle square stands in for that step.
    if (picker.allowsEditing) {
        CGFloat side = MIN(photo.size.width, photo.size.height);
        CGRect crop = CGRectMake((photo.size.width - side) / 2, (photo.size.height - side) / 2, side, side);
        CGImageRef square = CGImageCreateWithImageInRect(photo.CGImage, crop);
        info[UIImagePickerControllerEditedImage] = [UIImage imageWithCGImage:square];
        info[UIImagePickerControllerCropRect] = [NSValue valueWithCGRect:crop];
        CGImageRelease(square);
    }
    id<UINavigationControllerDelegate, UIImagePickerControllerDelegate> delegate = picker.delegate;
    if ([delegate respondsToSelector:@selector(imagePickerController:didFinishPickingMediaWithInfo:)]) {
        [delegate imagePickerController:picker didFinishPickingMediaWithInfo:info];
    } else {
        [picker dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)cancel {
    UIImagePickerController *picker = self.picker;
    id<UINavigationControllerDelegate, UIImagePickerControllerDelegate> delegate = picker.delegate;
    if (picker && [delegate respondsToSelector:@selector(imagePickerControllerDidCancel:)]) {
        [delegate imagePickerControllerDidCancel:picker];
    } else if (picker) {
        [picker dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    }
}

@end

static BetterSimCameraScreen *BetterSimScreenFor(UIImagePickerController *picker) {
    BetterSimCameraScreen *screen = [[BetterSimCameraScreen alloc] initWithPicker:picker];
    objc_setAssociatedObject(picker, BetterSimScreenKey, screen, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return screen;
}

static void BetterSimInstallPicker(void) {
    Class picker = UIImagePickerController.class;
    __block IMP available = BetterSimReplaceClassMethod(picker, @selector(isSourceTypeAvailable:), ^BOOL(id cls, UIImagePickerControllerSourceType type) {
        if (type == UIImagePickerControllerSourceTypeCamera && !BetterSimFromUIKit(__builtin_return_address(0))) return YES;
        return ((BOOL (*)(id, SEL, UIImagePickerControllerSourceType))available)(cls, @selector(isSourceTypeAvailable:), type);
    });
    __block IMP mediaTypes = BetterSimReplaceClassMethod(picker, @selector(availableMediaTypesForSourceType:), ^NSArray *(id cls, UIImagePickerControllerSourceType type) {
        if (type == UIImagePickerControllerSourceTypeCamera && !BetterSimFromUIKit(__builtin_return_address(0))) return @[UTTypeImage.identifier];
        return ((NSArray *(*)(id, SEL, UIImagePickerControllerSourceType))mediaTypes)(cls, @selector(availableMediaTypesForSourceType:), type);
    });
    BetterSimReplaceClassMethod(picker, @selector(isCameraDeviceAvailable:), ^BOOL(id cls, UIImagePickerControllerCameraDevice device) { return YES; });
    BetterSimReplaceClassMethod(picker, @selector(isFlashAvailableForCameraDevice:), ^BOOL(id cls, UIImagePickerControllerCameraDevice device) { return NO; });
    BetterSimReplaceClassMethod(picker, @selector(availableCaptureModesForCameraDevice:), ^NSArray *(id cls, UIImagePickerControllerCameraDevice device) {
        return @[@(UIImagePickerControllerCameraCaptureModePhoto)];
    });

    // UIKit throws when the camera source is set in the Simulator, so the picker keeps its source and remembers instead.
    __block IMP setSource = BetterSimReplace(picker, @selector(setSourceType:), ^(UIImagePickerController *self, UIImagePickerControllerSourceType type) {
        BOOL camera = type == UIImagePickerControllerSourceTypeCamera;
        objc_setAssociatedObject(self, BetterSimUsesCameraKey, @(camera), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!camera) ((void (*)(id, SEL, UIImagePickerControllerSourceType))setSource)(self, @selector(setSourceType:), type);
    });
    __block IMP source = BetterSimReplace(picker, @selector(sourceType), ^UIImagePickerControllerSourceType(UIImagePickerController *self) {
        if (BetterSimPickerUsesCamera(self) && !BetterSimFromUIKit(__builtin_return_address(0))) return UIImagePickerControllerSourceTypeCamera;
        return ((UIImagePickerControllerSourceType (*)(id, SEL))source)(self, @selector(sourceType));
    });

    // The camera's own settings only exist with the camera source, so they're kept here for the camera screen.
    __block IMP setDevice = BetterSimReplace(picker, @selector(setCameraDevice:), ^(UIImagePickerController *self, UIImagePickerControllerCameraDevice device) {
        if (BetterSimPickerUsesCamera(self)) return objc_setAssociatedObject(self, BetterSimCameraDeviceKey, @(device), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, UIImagePickerControllerCameraDevice))setDevice)(self, @selector(setCameraDevice:), device);
    });
    __block IMP device = BetterSimReplace(picker, @selector(cameraDevice), ^UIImagePickerControllerCameraDevice(UIImagePickerController *self) {
        if (BetterSimPickerUsesCamera(self)) return [objc_getAssociatedObject(self, BetterSimCameraDeviceKey) integerValue];
        return ((UIImagePickerControllerCameraDevice (*)(id, SEL))device)(self, @selector(cameraDevice));
    });
    __block IMP setCaptureMode = BetterSimReplace(picker, @selector(setCameraCaptureMode:), ^(UIImagePickerController *self, UIImagePickerControllerCameraCaptureMode mode) {
        if (BetterSimPickerUsesCamera(self)) return objc_setAssociatedObject(self, BetterSimCaptureModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, UIImagePickerControllerCameraCaptureMode))setCaptureMode)(self, @selector(setCameraCaptureMode:), mode);
    });
    __block IMP captureMode = BetterSimReplace(picker, @selector(cameraCaptureMode), ^UIImagePickerControllerCameraCaptureMode(UIImagePickerController *self) {
        if (BetterSimPickerUsesCamera(self)) return [objc_getAssociatedObject(self, BetterSimCaptureModeKey) integerValue];
        return ((UIImagePickerControllerCameraCaptureMode (*)(id, SEL))captureMode)(self, @selector(cameraCaptureMode));
    });
    __block IMP setFlashMode = BetterSimReplace(picker, @selector(setCameraFlashMode:), ^(UIImagePickerController *self, UIImagePickerControllerCameraFlashMode mode) {
        if (BetterSimPickerUsesCamera(self)) return objc_setAssociatedObject(self, BetterSimFlashModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, UIImagePickerControllerCameraFlashMode))setFlashMode)(self, @selector(setCameraFlashMode:), mode);
    });
    __block IMP flashMode = BetterSimReplace(picker, @selector(cameraFlashMode), ^UIImagePickerControllerCameraFlashMode(UIImagePickerController *self) {
        if (BetterSimPickerUsesCamera(self)) return [objc_getAssociatedObject(self, BetterSimFlashModeKey) integerValue];
        return ((UIImagePickerControllerCameraFlashMode (*)(id, SEL))flashMode)(self, @selector(cameraFlashMode));
    });
    __block IMP setShowsControls = BetterSimReplace(picker, @selector(setShowsCameraControls:), ^(UIImagePickerController *self, BOOL shows) {
        if (BetterSimPickerUsesCamera(self)) return objc_setAssociatedObject(self, BetterSimShowsControlsKey, @(shows), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, BOOL))setShowsControls)(self, @selector(setShowsCameraControls:), shows);
    });
    __block IMP showsControls = BetterSimReplace(picker, @selector(showsCameraControls), ^BOOL(UIImagePickerController *self) {
        if (BetterSimPickerUsesCamera(self)) return [objc_getAssociatedObject(self, BetterSimShowsControlsKey) ?: @YES boolValue];
        return ((BOOL (*)(id, SEL))showsControls)(self, @selector(showsCameraControls));
    });
    __block IMP setOverlay = BetterSimReplace(picker, @selector(setCameraOverlayView:), ^(UIImagePickerController *self, UIView *overlay) {
        if (BetterSimPickerUsesCamera(self)) return objc_setAssociatedObject(self, BetterSimOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, id))setOverlay)(self, @selector(setCameraOverlayView:), overlay);
    });
    __block IMP overlay = BetterSimReplace(picker, @selector(cameraOverlayView), ^UIView *(UIImagePickerController *self) {
        if (BetterSimPickerUsesCamera(self)) return objc_getAssociatedObject(self, BetterSimOverlayKey);
        return ((id (*)(id, SEL))overlay)(self, @selector(cameraOverlayView));
    });
    __block IMP setTransform = BetterSimReplace(picker, @selector(setCameraViewTransform:), ^(UIImagePickerController *self, CGAffineTransform transform) {
        if (BetterSimPickerUsesCamera(self)) return objc_setAssociatedObject(self, BetterSimTransformKey, [NSValue valueWithCGAffineTransform:transform], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, CGAffineTransform))setTransform)(self, @selector(setCameraViewTransform:), transform);
    });
    __block IMP transform = BetterSimReplace(picker, @selector(cameraViewTransform), ^CGAffineTransform(UIImagePickerController *self) {
        if (BetterSimPickerUsesCamera(self)) {
            NSValue *value = objc_getAssociatedObject(self, BetterSimTransformKey);
            return value ? value.CGAffineTransformValue : CGAffineTransformIdentity;
        }
        return ((CGAffineTransform (*)(id, SEL))transform)(self, @selector(cameraViewTransform));
    });
    __block IMP takePicture = BetterSimReplace(picker, @selector(takePicture), ^(UIImagePickerController *self) {
        if (BetterSimPickerUsesCamera(self)) return [(BetterSimCameraScreen *)objc_getAssociatedObject(self, BetterSimScreenKey) shoot];
        ((void (*)(id, SEL))takePicture)(self, @selector(takePicture));
    });
    __block IMP startVideo = BetterSimReplace(picker, @selector(startVideoCapture), ^BOOL(UIImagePickerController *self) {
        if (BetterSimPickerUsesCamera(self)) return NO;
        return ((BOOL (*)(id, SEL))startVideo)(self, @selector(startVideoCapture));
    });

    // A picker presented on its own is swapped for the camera screen, and stays out of sight.
    __block IMP present = BetterSimReplace(UIViewController.class, @selector(presentViewController:animated:completion:), ^(UIViewController *self, UIViewController *presented, BOOL animated, void (^completion)(void)) {
        if ([presented isKindOfClass:UIImagePickerController.class] && BetterSimPickerUsesCamera((UIImagePickerController *)presented)) {
            presented = BetterSimScreenFor((UIImagePickerController *)presented);
        }
        ((void (*)(id, SEL, id, BOOL, id))present)(self, @selector(presentViewController:animated:completion:), presented, animated, completion);
    });
    // A picker shown inside something else, as SwiftUI does, gets the camera screen on top of it once it appears.
    __block IMP appear = BetterSimReplace(picker, @selector(viewDidAppear:), ^(UIImagePickerController *self, BOOL animated) {
        ((void (*)(id, SEL, BOOL))appear)(self, @selector(viewDidAppear:), animated);
        if (BetterSimPickerUsesCamera(self) && !objc_getAssociatedObject(self, BetterSimScreenKey)) {
            [self presentViewController:BetterSimScreenFor(self) animated:NO completion:nil];
        }
    });
    // Dismissing the picker dismisses the camera screen, and then the picker too when the screen sat on top of it.
    __block IMP dismiss = BetterSimReplace(picker, @selector(dismissViewControllerAnimated:completion:), ^(UIImagePickerController *self, BOOL animated, void (^completion)(void)) {
        void (^original)(BOOL, void (^)(void)) = ^(BOOL animate, void (^done)(void)) {
            ((void (*)(id, SEL, BOOL, id))dismiss)(self, @selector(dismissViewControllerAnimated:completion:), animate, done);
        };
        BetterSimCameraScreen *screen = objc_getAssociatedObject(self, BetterSimScreenKey);
        UIViewController *presenter = screen.presentingViewController;
        if (!screen || !presenter) return original(animated, completion);
        objc_setAssociatedObject(self, BetterSimScreenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (presenter == self) {
            original(NO, ^{ original(animated, completion); });
        } else {
            [presenter dismissViewControllerAnimated:animated completion:completion];
        }
    });
}

__attribute__((constructor))
static void BetterSimCameraPickerLoad(void) {
    const char *port = getenv("BETTERSIM_CAMERA_PORT");
    if (!port || strtol(port, NULL, 10) <= 0) return;
    @autoreleasepool {
        BetterSimInstallPicker();
    }
}
