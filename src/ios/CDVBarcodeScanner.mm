/*
 * PhoneGap is available under *either* the terms of the modified BSD license *or* the
 * MIT License (2008). See http://opensource.org/licenses/alphabetical for full text.
 *
 * Copyright 2011 Matt Kane. All rights reserved.
 * Copyright (c) 2011, IBM Corporation
 */

#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <Cordova/CDVPlugin.h>


//------------------------------------------------------------------------------
// Delegate to handle orientation functions
//------------------------------------------------------------------------------
@protocol CDVBarcodeScannerOrientationDelegate <NSObject>

- (NSUInteger)supportedInterfaceOrientations;
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation;
- (BOOL)shouldAutorotate;

@end

//------------------------------------------------------------------------------
// Adds a shutter button to the UI, and changes the scan from continuous to
// only performing a scan when you click the shutter button.  For testing.
//------------------------------------------------------------------------------
#define USE_SHUTTER 0

//------------------------------------------------------------------------------
@class CDVbcsProcessor;
@class CDVbcsViewController;

//------------------------------------------------------------------------------
// plugin class
//------------------------------------------------------------------------------
@interface CDVBarcodeScanner : CDVPlugin {}
- (NSString*)isScanNotPossible;
- (void)scan:(CDVInvokedUrlCommand*)command;
- (void)encode:(CDVInvokedUrlCommand*)command;
- (void)returnImage:(NSString*)filePath format:(NSString*)format callback:(NSString*)callback;
- (void)returnSuccess:(NSString*)scannedText format:(NSString*)format cancelled:(BOOL)cancelled flipped:(BOOL)flipped callback:(NSString*)callback;
- (void)returnError:(NSString*)message callback:(NSString*)callback;
@end

//------------------------------------------------------------------------------
// class that does the grunt work
//------------------------------------------------------------------------------
@interface CDVbcsProcessor : NSObject <AVCaptureMetadataOutputObjectsDelegate> {}
@property (nonatomic, retain) CDVBarcodeScanner*           plugin;
@property (nonatomic, retain) NSString*                   callback;
@property (nonatomic, retain) UIViewController*           parentViewController;
@property (nonatomic, retain) CDVbcsViewController*        viewController;
@property (nonatomic, retain) AVCaptureSession*           captureSession;
@property (nonatomic, retain) AVCaptureVideoPreviewLayer* previewLayer;
@property (nonatomic, retain) NSString*                   alternateXib;
@property (nonatomic, retain) NSMutableArray*             results;
@property (nonatomic, retain) NSString*                   formats;
@property (nonatomic)         BOOL                        is1D;
@property (nonatomic)         BOOL                        is2D;
@property (nonatomic)         BOOL                        capturing;
@property (nonatomic)         BOOL                        isFrontCamera;
@property (nonatomic)         BOOL                        isShowFlipCameraButton;
@property (nonatomic)         BOOL                        isShowTorchButton;
@property (nonatomic)         BOOL                        isFlipped;
@property (nonatomic)         BOOL                        isTransitionAnimated;
@property (nonatomic)         BOOL                        isSuccessBeepEnabled;


- (id)initWithPlugin:(CDVBarcodeScanner*)plugin callback:(NSString*)callback parentViewController:(UIViewController*)parentViewController alterateOverlayXib:(NSString *)alternateXib;
- (void)scanBarcode;
- (void)barcodeScanSucceeded:(NSString*)text format:(NSString*)format;
- (void)showBarcodeScanErrorInScanner:(NSString*)message;
- (void)barcodeScanFailed:(NSString*)message;
- (void)barcodeScanCancelled;
- (void)openDialog;
- (NSString*)setUpCaptureSession;
- (void)captureOutput:(AVCaptureOutput*)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection*)connection;
@end

//------------------------------------------------------------------------------
// Qr encoder processor
//------------------------------------------------------------------------------
@interface CDVqrProcessor: NSObject
@property (nonatomic, retain) CDVBarcodeScanner*          plugin;
@property (nonatomic, retain) NSString*                   callback;
@property (nonatomic, retain) NSString*                   stringToEncode;
@property                     NSInteger                   size;

- (id)initWithPlugin:(CDVBarcodeScanner*)plugin callback:(NSString*)callback stringToEncode:(NSString*)stringToEncode;
- (void)generateImage;
@end

//------------------------------------------------------------------------------
// view controller for the ui
//------------------------------------------------------------------------------
@interface CDVbcsViewController : UIViewController <CDVBarcodeScannerOrientationDelegate> {}
@property (nonatomic, retain) CDVbcsProcessor*  processor;
@property (nonatomic, retain) NSString*        alternateXib;
@property (nonatomic)         BOOL             shutterPressed;
@property (nonatomic, retain) IBOutlet UIView* overlayView;
@property (nonatomic, retain) UIVisualEffectView* blurEffectView;
@property (nonatomic, retain) UILabel* errorText;
@property (nonatomic, retain) UILabel* errorTextHeadline;
@property (nonatomic, retain) UIToolbar * toolbar;
@property (nonatomic, retain) UIView * reticleView;
// unsafe_unretained is equivalent to assign - used to prevent retain cycles in the property below
@property (nonatomic, unsafe_unretained) id orientationDelegate;

- (id)initWithProcessor:(CDVbcsProcessor*)processor alternateOverlay:(NSString *)alternateXib;
- (void)startCapturing;
- (UIView*)buildOverlayView;
- (UIImage*)buildReticleImage;
- (void)shutterButtonPressed;
- (IBAction)cancelButtonPressed:(id)sender;
- (IBAction)flipCameraButtonPressed:(id)sender;
- (IBAction)torchButtonPressed:(id)sender;

@end

//------------------------------------------------------------------------------
// plugin class
//------------------------------------------------------------------------------
@implementation CDVBarcodeScanner

//--------------------------------------------------------------------------
- (NSString*)isScanNotPossible {
    NSString* result = nil;

    Class aClass = NSClassFromString(@"AVCaptureSession");
    if (aClass == nil) {
        return @"AVFoundation Framework not available";
    }

    return result;
}

-(BOOL)notHasPermission
{
    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    return (authStatus == AVAuthorizationStatusDenied ||
            authStatus == AVAuthorizationStatusRestricted);
}

-(BOOL)isUsageDescriptionSet
{
  NSDictionary * plist = [[NSBundle mainBundle] infoDictionary];
  if ([plist objectForKey:@"NSCameraUsageDescription" ]) {
    return YES;
  }
  return NO;
}



//--------------------------------------------------------------------------
- (void)scan:(CDVInvokedUrlCommand*)command {
    CDVbcsProcessor* processor;
    NSString*       callback;
    NSString*       capabilityError;

    callback = command.callbackId;

    NSDictionary* options;
    if (command.arguments.count == 0) {
      options = [NSDictionary dictionary];
    } else {
      options = command.arguments[0];
    }

    BOOL preferFrontCamera = [options[@"preferFrontCamera"] boolValue];
    BOOL showFlipCameraButton = [options[@"showFlipCameraButton"] boolValue];
    BOOL showTorchButton = [options[@"showTorchButton"] boolValue];
    BOOL disableAnimations = [options[@"disableAnimations"] boolValue];
    BOOL disableSuccessBeep = [options[@"disableSuccessBeep"] boolValue];

    // We allow the user to define an alternate xib file for loading the overlay.
    NSString *overlayXib = options[@"overlayXib"];

    capabilityError = [self isScanNotPossible];
    if (capabilityError) {
        [self returnError:capabilityError callback:callback];
        return;
    } else if ([self notHasPermission]) {
        NSString * error = NSLocalizedString(@"Access to the camera has been prohibited; please enable it in the Settings app to continue.",nil);
        [self returnError:error callback:callback];
        return;
    } else if (![self isUsageDescriptionSet]) {
      NSString * error = NSLocalizedString(@"NSCameraUsageDescription is not set in the info.plist", nil);
      [self returnError:error callback:callback];
      return;
    }

    processor = [[CDVbcsProcessor alloc]
                initWithPlugin:self
                      callback:callback
          parentViewController:self.viewController
            alterateOverlayXib:overlayXib
            ];
    // queue [processor scanBarcode] to run on the event loop

    if (preferFrontCamera) {
      processor.isFrontCamera = true;
    }

    if (showFlipCameraButton) {
      processor.isShowFlipCameraButton = true;
    }

    if (showTorchButton) {
      processor.isShowTorchButton = true;
    }

    processor.isSuccessBeepEnabled = !disableSuccessBeep;

    processor.isTransitionAnimated = !disableAnimations;

    processor.formats = options[@"formats"];

    [processor performSelector:@selector(scanBarcode) withObject:nil afterDelay:0];
}

//--------------------------------------------------------------------------
- (void)encode:(CDVInvokedUrlCommand*)command {
    if([command.arguments count] < 1)
        [self returnError:@"Too few arguments!" callback:command.callbackId];

    CDVqrProcessor* processor;
    NSString*       callback;
    callback = command.callbackId;

    processor = [[CDVqrProcessor alloc]
                 initWithPlugin:self
                 callback:callback
                 stringToEncode: command.arguments[0][@"data"]
                 ];
    // queue [processor generateImage] to run on the event loop
    [processor performSelector:@selector(generateImage) withObject:nil afterDelay:0];
}

- (void)returnImage:(NSString*)filePath format:(NSString*)format callback:(NSString*)callback{
    NSMutableDictionary* resultDict = [[NSMutableDictionary alloc] init];
    resultDict[@"format"] = format;
    resultDict[@"file"] = filePath;

    CDVPluginResult* result = [CDVPluginResult
                               resultWithStatus: CDVCommandStatus_OK
                               messageAsDictionary:resultDict
                               ];

    [[self commandDelegate] sendPluginResult:result callbackId:callback];
}

//--------------------------------------------------------------------------
- (void)returnSuccess:(NSString*)scannedText format:(NSString*)format cancelled:(BOOL)cancelled flipped:(BOOL)flipped callback:(NSString*)callback{
    NSNumber* cancelledNumber = @(cancelled ? 1 : 0);

    NSMutableDictionary* resultDict = [NSMutableDictionary new];
    resultDict[@"text"] = scannedText;
    resultDict[@"format"] = format;
    resultDict[@"cancelled"] = cancelledNumber;

    CDVPluginResult* result = [CDVPluginResult
                               resultWithStatus: CDVCommandStatus_OK
                               messageAsDictionary: resultDict
                               ];
    [self.commandDelegate sendPluginResult:result callbackId:callback];
}

//--------------------------------------------------------------------------
- (void)returnError:(NSString*)message callback:(NSString*)callback {
    CDVPluginResult* result = [CDVPluginResult
                               resultWithStatus: CDVCommandStatus_ERROR
                               messageAsString: message
                               ];

    [self.commandDelegate sendPluginResult:result callbackId:callback];
}

@end

//------------------------------------------------------------------------------
// class that does the grunt work
//------------------------------------------------------------------------------
@implementation CDVbcsProcessor

@synthesize plugin               = _plugin;
@synthesize callback             = _callback;
@synthesize parentViewController = _parentViewController;
@synthesize viewController       = _viewController;
@synthesize captureSession       = _captureSession;
@synthesize previewLayer         = _previewLayer;
@synthesize alternateXib         = _alternateXib;
@synthesize is1D                 = _is1D;
@synthesize is2D                 = _is2D;
@synthesize capturing            = _capturing;
@synthesize results              = _results;

SystemSoundID _soundFileObject;

//--------------------------------------------------------------------------
- (id)initWithPlugin:(CDVBarcodeScanner*)plugin
            callback:(NSString*)callback
parentViewController:(UIViewController*)parentViewController
  alterateOverlayXib:(NSString *)alternateXib {
    self = [super init];
    if (!self) return self;

    self.plugin               = plugin;
    self.callback             = callback;
    self.parentViewController = parentViewController;
    self.alternateXib         = alternateXib;

    self.is1D      = YES;
    self.is2D      = YES;
    self.capturing = NO;
    self.results = [NSMutableArray new];

    CFURLRef soundFileURLRef  = CFBundleCopyResourceURL(CFBundleGetMainBundle(), CFSTR("CDVBarcodeScanner.bundle/beep"), CFSTR ("caf"), NULL);
    AudioServicesCreateSystemSoundID(soundFileURLRef, &_soundFileObject);

    return self;
}

//--------------------------------------------------------------------------
- (void)dealloc {
    self.plugin = nil;
    self.callback = nil;
    self.parentViewController = nil;
    self.viewController = nil;
    self.captureSession = nil;
    self.previewLayer = nil;
    self.alternateXib = nil;
    self.results = nil;

    self.capturing = NO;

    AudioServicesRemoveSystemSoundCompletion(_soundFileObject);
    AudioServicesDisposeSystemSoundID(_soundFileObject);
}

//--------------------------------------------------------------------------
- (void)scanBarcode {

//    self.captureSession = nil;
//    self.previewLayer = nil;
    NSString* errorMessage = [self setUpCaptureSession];
    if (errorMessage) {
        [self barcodeScanFailed:errorMessage];
        return;
    }

    self.viewController = [[CDVbcsViewController alloc] initWithProcessor: self alternateOverlay:self.alternateXib];
    // here we set the orientation delegate to the MainViewController of the app (orientation controlled in the Project Settings)
    self.viewController.orientationDelegate = self.plugin.viewController;

    // delayed [self openDialog];
    [self performSelector:@selector(openDialog) withObject:nil afterDelay:1];
}

//--------------------------------------------------------------------------
- (void)openDialog {
    [self.parentViewController
     presentViewController:self.viewController
     animated:self.isTransitionAnimated completion:nil
     ];
}

//--------------------------------------------------------------------------
- (void)barcodeScanDone:(void (^)(void))callbackBlock {
    self.capturing = NO;
    [self.captureSession stopRunning];
    [self.parentViewController dismissViewControllerAnimated:self.isTransitionAnimated completion:callbackBlock];

    // viewcontroller holding onto a reference to us, release them so they
    // will release us
    self.viewController = nil;
}

//--------------------------------------------------------------------------
- (BOOL)checkResult:(NSString *)result {
    [self.results addObject:result];

    NSInteger treshold = 7;

    if (self.results.count > treshold) {
        [self.results removeObjectAtIndex:0];
    }

    if (self.results.count < treshold)
    {
        return NO;
    }

    BOOL allEqual = YES;
    NSString *compareString = self.results[0];

    for (NSString *aResult in self.results)
    {
        if (![compareString isEqualToString:aResult])
        {
            allEqual = NO;
            //NSLog(@"Did not fit: %@",self.results);
            break;
        }
    }

    return allEqual;
}

//--------------------------------------------------------------------------
- (void)barcodeScanSucceeded:(NSString*)text format:(NSString*)format {
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (self.isSuccessBeepEnabled) {
            AudioServicesPlaySystemSound(_soundFileObject);
        }
        if(NSClassFromString(@"NSJSONSerialization"))
        {
            NSError *error = nil;
            NSData* jsonData = [text dataUsingEncoding:NSUTF8StringEncoding];

            id object = [NSJSONSerialization
                         JSONObjectWithData:jsonData
                         options:0
                         error:&error];

            if(error) { /* JSON was malformed, act appropriately here */
                [self showBarcodeScanErrorInScanner:@"JSON malformed"];
            }

            // the originating poster wants to deal with dictionaries;
            // assuming you do too then something like this is the first
            // validation step:
            if([object isKindOfClass:[NSDictionary class]])
            {
                NSDictionary *results = object;
                if( [results objectForKey:@"sessionToken"] == nil ){
                    [self showBarcodeScanErrorInScanner:@"JSON malformed, session Token Missing"];
                } else if ([results objectForKey:@"workflowId"] == nil ){
                    [self showBarcodeScanErrorInScanner:@"JSON malformed, owrkflowid missing"];
                }
                else{
                    [self barcodeScanDone:^{
                        [self.plugin returnSuccess:text format:format cancelled:FALSE flipped:FALSE callback:self.callback];
                    }];
                }

                /* proceed with results as you like; the assignment to
                 an explicit NSDictionary * is artificial step to get
                 compile-time checking from here on down (and better autocompletion
                 when editing). You could have just made object an NSDictionary *
                 in the first place but stylistically you might prefer to keep
                 the question of type open until it's confirmed */
            }
            else
            {
//                [self barcodeScanFailed:@"JSON malformed"];
                [self showBarcodeScanErrorInScanner:@"JSON malformed"];

                /* there's no guarantee that the outermost object in a JSON
                 packet will be a dictionary; if we get here then it wasn't,
                 so 'object' shouldn't be treated as an NSDictionary; probably
                 you need to report a suitable error condition */
            }
        }
        else
        {
            // iOS4 or less, not supported
            [self showBarcodeScanErrorInScanner:@"iOS Version not supported"];

        }

    });
}

- (void)showBarcodeScanErrorInScanner:(NSString*)message {
    self.viewController.blurEffectView.alpha = 0.3;
    self.viewController.blurEffectView.backgroundColor = [UIColor redColor];
    self.viewController.errorText.alpha = 1.0;
    self.viewController.errorTextHeadline.alpha = 1.0;
    [self.viewController.view setNeedsDisplay];

    dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 4);
    dispatch_after(delay, dispatch_get_main_queue(), ^(void){
        self.viewController.blurEffectView.alpha = 0.7;
        self.viewController.errorText.alpha = 0.0;
        self.viewController.errorTextHeadline.alpha = 0.0;
        self.viewController.blurEffectView.backgroundColor = [UIColor clearColor];
        [self.viewController.view setNeedsDisplay];
    });
}

//--------------------------------------------------------------------------
- (void)barcodeScanFailed:(NSString*)message {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self barcodeScanDone:^{
            [self.plugin returnError:message callback:self.callback];
        }];
    });
}

//--------------------------------------------------------------------------
- (void)barcodeScanCancelled {
    [self barcodeScanDone:^{
        [self.plugin returnSuccess:@"" format:@"" cancelled:TRUE flipped:self.isFlipped callback:self.callback];
    }];
    if (self.isFlipped) {
        self.isFlipped = NO;
    }
}

- (void)flipCamera {
    self.isFlipped = YES;
    self.isFrontCamera = !self.isFrontCamera;
    [self barcodeScanDone:^{
        if (self.isFlipped) {
            self.isFlipped = NO;
        }
    [self performSelector:@selector(scanBarcode) withObject:nil afterDelay:0.1];
    }];
}

- (void)toggleTorch {
  AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  [device lockForConfiguration:nil];
  if (device.flashActive) {
    [device setTorchMode:AVCaptureTorchModeOff];
    [device setFlashMode:AVCaptureFlashModeOff];
  } else {
    [device setTorchModeOnWithLevel:AVCaptureMaxAvailableTorchLevel error:nil];
    [device setFlashMode:AVCaptureFlashModeOn];
  }
  [device unlockForConfiguration];
}

//--------------------------------------------------------------------------
- (NSString*)setUpCaptureSession {
    NSError* error = nil;

    AVCaptureSession* captureSession = [[AVCaptureSession alloc] init];
    self.captureSession = captureSession;

       AVCaptureDevice* __block device = nil;
    if (self.isFrontCamera) {

        NSArray* devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
        [devices enumerateObjectsUsingBlock:^(AVCaptureDevice *obj, NSUInteger idx, BOOL *stop) {
            if (obj.position == AVCaptureDevicePositionFront) {
                device = obj;
            }
        }];
    } else {
        device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (!device) return @"unable to obtain video capture device";

    }

    // set focus params if available to improve focusing
    [device lockForConfiguration:&error];
    if (error == nil) {
        if([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
        }
        if([device isAutoFocusRangeRestrictionSupported]) {
            [device setAutoFocusRangeRestriction:AVCaptureAutoFocusRangeRestrictionNear];
        }
    }
    [device unlockForConfiguration];

    AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) return @"unable to obtain video capture device input";

    AVCaptureMetadataOutput* output = [[AVCaptureMetadataOutput alloc] init];
    if (!output) return @"unable to obtain video capture output";

    [output setMetadataObjectsDelegate:self queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0)];

    if ([captureSession canSetSessionPreset:AVCaptureSessionPresetHigh]) {
      captureSession.sessionPreset = AVCaptureSessionPresetHigh;
    } else if ([captureSession canSetSessionPreset:AVCaptureSessionPresetMedium]) {
      captureSession.sessionPreset = AVCaptureSessionPresetMedium;
    } else {
      return @"unable to preset high nor medium quality video capture";
    }

    if ([captureSession canAddInput:input]) {
        [captureSession addInput:input];
    }
    else {
        return @"unable to add video capture device input to session";
    }

    if ([captureSession canAddOutput:output]) {
        [captureSession addOutput:output];
    }
    else {
        return @"unable to add video capture output to session";
    }

    [output setMetadataObjectTypes:[self formatObjectTypes]];

    // setup capture preview layer
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:captureSession];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

    // run on next event loop pass [captureSession startRunning]
    [captureSession performSelector:@selector(startRunning) withObject:nil afterDelay:0];

    return nil;
}

//--------------------------------------------------------------------------
// this method gets sent the captured frames
//--------------------------------------------------------------------------
- (void)captureOutput:(AVCaptureOutput*)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects fromConnection:(AVCaptureConnection*)connection {

    if (!self.capturing) return;

#if USE_SHUTTER
    if (!self.viewController.shutterPressed) return;
    self.viewController.shutterPressed = NO;

    UIView* flashView = [[UIView alloc] initWithFrame:self.viewController.view.frame];
    [flashView setBackgroundColor:[UIColor whiteColor]];
    [self.viewController.view.window addSubview:flashView];

    [UIView
     animateWithDuration:.4f
     animations:^{
         [flashView setAlpha:0.f];
     }
     completion:^(BOOL finished){
         [flashView removeFromSuperview];
     }
     ];
#endif


    try {
        // This will bring in multiple entities if there are multiple 2D codes in frame.
        for (AVMetadataObject *metaData in metadataObjects) {
            AVMetadataMachineReadableCodeObject* code = (AVMetadataMachineReadableCodeObject*)[self.previewLayer transformedMetadataObjectForMetadataObject:(AVMetadataMachineReadableCodeObject*)metaData];

            if ([self checkResult:code.stringValue]) {
                [self barcodeScanSucceeded:code.stringValue format:[self formatStringFromMetadata:code]];
            }
        }
    }
    catch (...) {
        //            NSLog(@"decoding: unknown exception");
        //            [self barcodeScanFailed:@"unknown exception decoding barcode"];
    }

    //        NSTimeInterval timeElapsed  = [NSDate timeIntervalSinceReferenceDate] - timeStart;
    //        NSLog(@"decoding completed in %dms", (int) (timeElapsed * 1000));

}

//--------------------------------------------------------------------------
// convert metadata object information to barcode format string
//--------------------------------------------------------------------------
- (NSString*)formatStringFromMetadata:(AVMetadataMachineReadableCodeObject*)format {
    if (format.type == AVMetadataObjectTypeQRCode)          return @"QR_CODE";
    if (format.type == AVMetadataObjectTypeAztecCode)       return @"AZTEC";
    if (format.type == AVMetadataObjectTypeDataMatrixCode)  return @"DATA_MATRIX";
    if (format.type == AVMetadataObjectTypeUPCECode)        return @"UPC_E";
    // According to Apple documentation, UPC_A is EAN13 with a leading 0.
    if (format.type == AVMetadataObjectTypeEAN13Code && [format.stringValue characterAtIndex:0] == '0') return @"UPC_A";
    if (format.type == AVMetadataObjectTypeEAN8Code)        return @"EAN_8";
    if (format.type == AVMetadataObjectTypeEAN13Code)       return @"EAN_13";
    if (format.type == AVMetadataObjectTypeCode128Code)     return @"CODE_128";
    if (format.type == AVMetadataObjectTypeCode93Code)      return @"CODE_93";
    if (format.type == AVMetadataObjectTypeCode39Code)      return @"CODE_39";
    if (format.type == AVMetadataObjectTypeInterleaved2of5Code) return @"ITF";
    if (format.type == AVMetadataObjectTypeITF14Code)          return @"ITF_14";

    if (format.type == AVMetadataObjectTypePDF417Code)      return @"PDF_417";
    return @"???";
}

//--------------------------------------------------------------------------
// convert string formats to metadata objects
//--------------------------------------------------------------------------
- (NSArray*) formatObjectTypes {
    NSArray *supportedFormats = nil;
    if (self.formats != nil) {
        supportedFormats = [self.formats componentsSeparatedByString:@","];
    }

    NSMutableArray * formatObjectTypes = [NSMutableArray array];

    if (self.formats == nil || [supportedFormats containsObject:@"QR_CODE"]) [formatObjectTypes addObject:AVMetadataObjectTypeQRCode];
    if (self.formats == nil || [supportedFormats containsObject:@"AZTEC"]) [formatObjectTypes addObject:AVMetadataObjectTypeAztecCode];
    if (self.formats == nil || [supportedFormats containsObject:@"DATA_MATRIX"]) [formatObjectTypes addObject:AVMetadataObjectTypeDataMatrixCode];
    if (self.formats == nil || [supportedFormats containsObject:@"UPC_E"]) [formatObjectTypes addObject:AVMetadataObjectTypeUPCECode];
    if (self.formats == nil || [supportedFormats containsObject:@"EAN_8"]) [formatObjectTypes addObject:AVMetadataObjectTypeEAN8Code];
    if (self.formats == nil || [supportedFormats containsObject:@"EAN_13"]) [formatObjectTypes addObject:AVMetadataObjectTypeEAN13Code];
    if (self.formats == nil || [supportedFormats containsObject:@"CODE_128"]) [formatObjectTypes addObject:AVMetadataObjectTypeCode128Code];
    if (self.formats == nil || [supportedFormats containsObject:@"CODE_93"]) [formatObjectTypes addObject:AVMetadataObjectTypeCode93Code];
    if (self.formats == nil || [supportedFormats containsObject:@"CODE_39"]) [formatObjectTypes addObject:AVMetadataObjectTypeCode39Code];
    if (self.formats == nil || [supportedFormats containsObject:@"ITF"]) [formatObjectTypes addObject:AVMetadataObjectTypeInterleaved2of5Code];
    if (self.formats == nil || [supportedFormats containsObject:@"ITF_14"]) [formatObjectTypes addObject:AVMetadataObjectTypeITF14Code];
    if (self.formats == nil || [supportedFormats containsObject:@"PDF_417"]) [formatObjectTypes addObject:AVMetadataObjectTypePDF417Code];

    return formatObjectTypes;
}

@end

//------------------------------------------------------------------------------
// qr encoder processor
//------------------------------------------------------------------------------
@implementation CDVqrProcessor
@synthesize plugin               = _plugin;
@synthesize callback             = _callback;
@synthesize stringToEncode       = _stringToEncode;
@synthesize size                 = _size;

- (id)initWithPlugin:(CDVBarcodeScanner*)plugin callback:(NSString*)callback stringToEncode:(NSString*)stringToEncode{
    self = [super init];
    if (!self) return self;

    self.plugin          = plugin;
    self.callback        = callback;
    self.stringToEncode  = stringToEncode;
    self.size            = 300;

    return self;
}

//--------------------------------------------------------------------------
- (void)dealloc {
    self.plugin = nil;
    self.callback = nil;
    self.stringToEncode = nil;
}
//--------------------------------------------------------------------------
- (void)generateImage{
    /* setup qr filter */
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setDefaults];

    /* set filter's input message
     * the encoding string has to be convert to a UTF-8 encoded NSData object */
    [filter setValue:[self.stringToEncode dataUsingEncoding:NSUTF8StringEncoding]
              forKey:@"inputMessage"];

    /* on ios >= 7.0  set low image error correction level */
    if (floor(NSFoundationVersionNumber) >= NSFoundationVersionNumber_iOS_7_0)
        [filter setValue:@"L" forKey:@"inputCorrectionLevel"];

    /* prepare cgImage */
    CIImage *outputImage = [filter outputImage];
    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [context createCGImage:outputImage
                                       fromRect:[outputImage extent]];

    /* returned qr code image */
    UIImage *qrImage = [UIImage imageWithCGImage:cgImage
                                           scale:1.
                                     orientation:UIImageOrientationUp];
    /* resize generated image */
    CGFloat width = _size;
    CGFloat height = _size;

    UIGraphicsBeginImageContext(CGSizeMake(width, height));

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    [qrImage drawInRect:CGRectMake(0, 0, width, height)];
    qrImage = UIGraphicsGetImageFromCurrentImageContext();

    /* clean up */
    UIGraphicsEndImageContext();
    CGImageRelease(cgImage);

    /* save image to file */
    NSString* fileName = [[[NSProcessInfo processInfo] globallyUniqueString] stringByAppendingString:@".jpg"];
    NSString* filePath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    [UIImageJPEGRepresentation(qrImage, 1.0) writeToFile:filePath atomically:YES];

    /* return file path back to cordova */
    [self.plugin returnImage:filePath format:@"QR_CODE" callback: self.callback];
}
@end

//------------------------------------------------------------------------------
// view controller for the ui
//------------------------------------------------------------------------------
@implementation CDVbcsViewController
@synthesize processor      = _processor;
@synthesize shutterPressed = _shutterPressed;
@synthesize alternateXib   = _alternateXib;
@synthesize overlayView    = _overlayView;

//--------------------------------------------------------------------------
- (id)initWithProcessor:(CDVbcsProcessor*)processor alternateOverlay:(NSString *)alternateXib {
    self = [super init];
    if (!self) return self;

    self.processor = processor;
    self.shutterPressed = NO;
    self.alternateXib = alternateXib;
    self.overlayView = nil;
    return self;
}

//--------------------------------------------------------------------------
- (void)dealloc {
    self.view = nil;
    self.processor = nil;
    self.shutterPressed = NO;
    self.alternateXib = nil;
    self.overlayView = nil;
}

//--------------------------------------------------------------------------
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame: self.processor.parentViewController.view.frame];
}

//--------------------------------------------------------------------------
- (void)viewWillAppear:(BOOL)animated {

    // set video orientation to what the camera sees
    self.processor.previewLayer.connection.videoOrientation = (AVCaptureVideoOrientation) [[UIApplication sharedApplication] statusBarOrientation];

    // this fixes the bug when the statusbar is landscape, and the preview layer
    // starts up in portrait (not filling the whole view)
    self.processor.previewLayer.frame = self.view.bounds;
}

//--------------------------------------------------------------------------
- (void)viewDidAppear:(BOOL)animated {
    // setup capture preview layer
    AVCaptureVideoPreviewLayer* previewLayer = self.processor.previewLayer;
    previewLayer.frame = self.view.bounds;
    previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

    if ([previewLayer.connection isVideoOrientationSupported]) {
        [previewLayer.connection setVideoOrientation:[[UIApplication sharedApplication] statusBarOrientation]];
    }

    [self.view.layer insertSublayer:previewLayer below:[[self.view.layer sublayers] objectAtIndex:0]];

    [self.view addSubview:[self buildOverlayView]];
    [self startCapturing];

    [super viewDidAppear:animated];
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}

//--------------------------------------------------------------------------
- (void)startCapturing {
    self.processor.capturing = YES;
}

//--------------------------------------------------------------------------
- (IBAction)shutterButtonPressed {
    self.shutterPressed = YES;
}

//--------------------------------------------------------------------------
- (IBAction)cancelButtonPressed:(id)sender {
    [self.processor performSelector:@selector(barcodeScanCancelled) withObject:nil afterDelay:0];
}

- (IBAction)flipCameraButtonPressed:(id)sender
{
    [self.processor performSelector:@selector(flipCamera) withObject:nil afterDelay:0];
}

- (IBAction)torchButtonPressed:(id)sender
{
  [self.processor performSelector:@selector(toggleTorch) withObject:nil afterDelay:0];
}

//--------------------------------------------------------------------------
- (UIView *)buildOverlayViewFromXib
{
    [[NSBundle mainBundle] loadNibNamed:self.alternateXib owner:self options:NULL];

    if ( self.overlayView == nil )
    {
        NSLog(@"%@", @"An error occurred loading the overlay xib.  It appears that the overlayView outlet is not set.");
        return nil;
    }

	self.overlayView.autoresizesSubviews = YES;
    self.overlayView.autoresizingMask    = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.overlayView.opaque              = NO;

	CGRect bounds = self.view.bounds;
    bounds = CGRectMake(0, 0, bounds.size.width, bounds.size.height);

	[self.overlayView setFrame:bounds];

    return self.overlayView;
}

//--------------------------------------------------------------------------
- (UIView*)buildOverlayView {

    if ( nil != self.alternateXib )
    {
        return [self buildOverlayViewFromXib];
    }
    CGRect bounds = self.view.bounds;
    bounds = CGRectMake(0, 0, bounds.size.width, bounds.size.height);

    UIView* overlayView = [[UIView alloc] initWithFrame:bounds];
    overlayView.autoresizesSubviews = YES;
    overlayView.autoresizingMask    = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlayView.opaque              = NO;

//    self.view.backgroundColor = [UIColor clearColor];


    // Create Blur Effect
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.blurEffectView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.blurEffectView.frame = self.view.bounds;
    self.blurEffectView.alpha = 0.7;
    self.blurEffectView.backgroundColor = [UIColor clearColor];


    self.blurEffectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.blurEffectView.contentMode      = UIViewContentModeScaleAspectFit;
    //    reticleView.autoresizingMask = (UIViewAutoresizing) (0
    //        | UIViewAutoresizingFlexibleLeftMargin
    //        | UIViewAutoresizingFlexibleRightMargin
    //        | UIViewAutoresizingFlexibleTopMargin
    //        | UIViewAutoresizingFlexibleBottomMargin)

    //Create Mask
    CGPoint superCenter = CGPointMake(CGRectGetMidX(self.blurEffectView.bounds), CGRectGetMidY(self.blurEffectView.bounds)*0.78);
    int size = floor(self.blurEffectView.bounds.size.width * 0.65);
    CGRect maskRect = CGRectMake(superCenter.x - size/2, superCenter.y - size/2, size, size);
    UIBezierPath *maskPath = [UIBezierPath bezierPathWithRect:maskRect];
    //invert path
    [maskPath appendPath:[UIBezierPath bezierPathWithRect:self.blurEffectView.bounds]];
    CAShapeLayer *fillLayer = [[CAShapeLayer alloc] init];
    fillLayer.fillRule = kCAFillRuleEvenOdd;
    fillLayer.fillColor = [UIColor greenColor].CGColor;
    fillLayer.path = maskPath.CGPath;

    // Add Blur Effect with Mask to view
    self.blurEffectView.layer.mask = fillLayer;
    [self.view addSubview:self.blurEffectView]; //if you have more UIViews, use an insertSubview API to place it where needed

    //Create default Font
    UIFont *font = [UIFont systemFontOfSize: 12.0f];

    // Create Lables
    // bottom
    int margin = 20;
    UILabel *bottomLabel = [[UILabel alloc] init];
    [bottomLabel setTextColor:[UIColor whiteColor]];
    [bottomLabel setBackgroundColor:[UIColor clearColor]];
    [bottomLabel setFont:font];
    [bottomLabel setText:@"Scan Keyp QR Code"];
    [bottomLabel sizeToFit];
    [bottomLabel setCenter:CGPointMake(superCenter.x, superCenter.y + size/2 + margin)];
    [self.view addSubview:bottomLabel];

    //right
    UILabel *rightLabel = [[UILabel alloc] init];
    [rightLabel setTextColor:[UIColor whiteColor]];
    [rightLabel setBackgroundColor:[UIColor clearColor]];
    [rightLabel setFont:font];
    [rightLabel setText:@"Scan Keyp QR Code"];
    [rightLabel sizeToFit];
    [rightLabel setTransform:CGAffineTransformMakeRotation(M_PI / 2)];
    [rightLabel setCenter:CGPointMake(superCenter.x + size / 2 + margin , superCenter.y)];
    [self.view addSubview:rightLabel];

    //left
    UILabel *leftLabel = [[UILabel alloc] init];
    [leftLabel setTextColor:[UIColor whiteColor]];
    [leftLabel setBackgroundColor:[UIColor clearColor]];
    [leftLabel setFont:font];
    [leftLabel setText:@"Scan Keyp QR Code"];
    [leftLabel sizeToFit];
    [leftLabel setTransform:CGAffineTransformMakeRotation(-M_PI / 2)];
    [leftLabel setCenter:CGPointMake(superCenter.x - size / 2 - margin , superCenter.y)];
    [self.view addSubview:leftLabel];

    //Draw corners
    double cornerMargin = margin * 1.5;
    double cornerLength = 30.0;
    UIBezierPath *path = [UIBezierPath bezierPath];

    CGPoint topleft = CGPointMake(superCenter.x - size / 2 - cornerMargin , superCenter.y - size / 2 - cornerMargin);
    [path moveToPoint:CGPointMake(topleft.x + cornerLength, topleft.y)];
    [path addLineToPoint:topleft];
    [path addLineToPoint:CGPointMake(topleft.x, topleft.y + cornerLength)];

    CGPoint topRight = CGPointMake(superCenter.x + size / 2 + cornerMargin , superCenter.y - size / 2 - cornerMargin);
    [path moveToPoint:CGPointMake(topRight.x - cornerLength, topRight.y)];
    [path addLineToPoint:topRight];
    [path addLineToPoint:CGPointMake(topRight.x, topRight.y + cornerLength)];

    CGPoint bottomRight = CGPointMake(superCenter.x + size / 2 + cornerMargin , superCenter.y + size / 2 + cornerMargin);
    [path moveToPoint:CGPointMake(bottomRight.x - cornerLength, bottomRight.y)];
    [path addLineToPoint:bottomRight];
    [path addLineToPoint:CGPointMake(bottomRight.x, bottomRight.y - cornerLength)];

    CGPoint bottomLeft = CGPointMake(superCenter.x - size / 2 - cornerMargin , superCenter.y + size / 2 + cornerMargin);
    [path moveToPoint:CGPointMake(bottomLeft.x + cornerLength, bottomLeft.y)];
    [path addLineToPoint:bottomLeft];
    [path addLineToPoint:CGPointMake(bottomLeft.x, bottomLeft.y - cornerLength)];

    CAShapeLayer *shapeLayer = [CAShapeLayer layer];
    shapeLayer.path = [path CGPath];
    shapeLayer.strokeColor = [[UIColor whiteColor] CGColor];
    shapeLayer.lineWidth = 1.4;
    shapeLayer.fillColor = [[UIColor clearColor] CGColor];
    [self.view.layer addSublayer:shapeLayer];


    //Add Back Button

    CGFloat topPadding = 20.0;
    CGFloat bottomPadding = 0.0;
    if (@available(iOS 11.0, *)) {
        UIWindow *window = UIApplication.sharedApplication.keyWindow;
        topPadding = window.safeAreaInsets.top;
        bottomPadding = window.safeAreaInsets.bottom;
    }
    if(topPadding < 20) topPadding = 20.0;
    UINavigationBar* navbar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, topPadding, self.view.frame.size.width, 1)];
    UINavigationItem* navItem = [[UINavigationItem alloc] initWithTitle:@"Scan Keyp QR"];

    [[UINavigationBar appearance] setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    [[UINavigationBar appearance] setShadowImage:[UIImage new]];
    [[UINavigationBar appearance] setTranslucent:YES];
    [[UINavigationBar appearance] setTintColor:[UIColor whiteColor]]; // for titles, buttons, etc.
    [[UINavigationBar appearance] setTitleTextAttributes:@{NSForegroundColorAttributeName : [UIColor whiteColor]}];

    // UIBarButtonItem *backButton = [[UIBarButtonItem alloc] initWithTitle:@"Cancel" style:UIBarButtonItemStylePlain target:self action:@selector(cancelButtonPressed:)];
    // navItem.leftBarButtonItem = backButton;

//    UIButton * backButton = [UIButton buttonWithType:UIButtonTypeCustom];
//    [backButton addTarget:self action:@selector(cancelButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
////    [backButton setFrame:FRAME_DEFINE
//     [backButton setContentHorizontalAlignment:UIControlContentHorizontalAlignmentLeft];
//     [backButton setExclusiveTouch:YES];
////    CFURLRef soundFileURLRef  = CFBundleCopyResourceURL(CFBundleGetMainBundle(), CFSTR("CDVBarcodeScanner.bundle/beep"), CFSTR ("caf"), NULL);
//    UIImage *image = [UIImage imageNamed:@"CDVBarcodeScanner.bundle/back.png"];
//    [backButton setImage:[image _imageScaledToSize:CGSizeMake(69, 32) interpolationQuality:1] forState:UIControlStateNormal];
//
//     [backButton setTitle:@"Back" forState:UIControlStateNormal];
//     [backButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
//     UIBarButtonItem *backMenuBarButton = [[UIBarButtonItem alloc] initWithCustomView:backButton];
//    navItem.leftBarButtonItem = backMenuBarButton;


    [navbar setItems:@[navItem]];
    navbar.barStyle = UIBarStyleBlack;

    [overlayView addSubview:navbar];

    // Set Crosshair
    UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectMake(superCenter.x, superCenter.y, size*0.15, size*0.15)];
    [imageView setCenter:CGPointMake(superCenter.x, superCenter.y)];
    imageView.image =  [UIImage imageNamed:@"CDVBarcodeScanner.bundle/crosshair.png"];
    [self.view addSubview:imageView];


    // Draw error Text
    self.errorTextHeadline = [[UILabel alloc] init];
    [self.errorTextHeadline setTextColor:[UIColor whiteColor]];
    [self.errorTextHeadline setBackgroundColor:[UIColor clearColor]];
    [self.errorTextHeadline setFont:[UIFont systemFontOfSize:20.0]];
    [self.errorTextHeadline setText:@"Woopsie."];
    [self.errorTextHeadline sizeToFit];
    [self.errorTextHeadline setCenter:CGPointMake(superCenter.x, superCenter.y + size * 0.75 + margin)];
    [self.errorTextHeadline setAlpha:0.0];
    [self.view addSubview:self.errorTextHeadline];

    self.errorText = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, self.view.bounds.size.width*0.7, 300)];
    [self.errorText setTextColor:[UIColor whiteColor]];
    [self.errorText setBackgroundColor:[UIColor clearColor]];
    [self.errorText setFont:[UIFont systemFontOfSize:16.0]];
    [self.errorText setText:@"The code you've just scanned doesn't seem to be a valid Keyp QR code.\n\n Please try again or use a different one."];
    self.errorText.lineBreakMode = NSLineBreakByWordWrapping;
    self.errorText.numberOfLines = 0;
    self.errorText.adjustsFontSizeToFitWidth = NO;
    [self.errorText sizeToFit];
    self.errorText.textAlignment = NSTextAlignmentCenter;
    [self.errorText setCenter:CGPointMake(superCenter.x, self.errorTextHeadline.frame.origin.y + self.errorTextHeadline.frame.size.height + self.errorText.frame.size.height/2 + margin)];
    [self.errorText setAlpha:0.0];
    [self.view addSubview:self.errorText];

//    UIToolbar* toolbar = [[UIToolbar alloc] init];
//    toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
//
//    id cancelButton = [[[UIBarButtonItem alloc]
//                       initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
//                       target:(id)self
//                       action:@selector(cancelButtonPressed:)
//                       ] autorelease];
//
//
//    id flexSpace = [[[UIBarButtonItem alloc]
//                    initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
//                    target:nil
//                    action:nil
//                    ] autorelease];
//
//    id flipCamera = [[[UIBarButtonItem alloc]
//                       initWithBarButtonSystemItem:UIBarButtonSystemItemCamera
//                       target:(id)self
//                       action:@selector(flipCameraButtonPressed:)
//                       ] autorelease];
//
//    NSMutableArray *items;
//
//#if USE_SHUTTER
//    id shutterButton = [[[UIBarButtonItem alloc]
//                        initWithBarButtonSystemItem:UIBarButtonSystemItemCamera
//                        target:(id)self
//                        action:@selector(shutterButtonPressed)
//                        ] autorelease];
//
//    if (_processor.isShowFlipCameraButton) {
//      items = [NSMutableArray arrayWithObjects:flexSpace, cancelButton, flexSpace, flipCamera, shutterButton, nil];
//    } else {
//      items = [NSMutableArray arrayWithObjects:flexSpace, cancelButton, flexSpace, shutterButton, nil];
//    }
//#else
//    if (_processor.isShowFlipCameraButton) {
//      items = [@[flexSpace, cancelButton, flexSpace, flipCamera] mutableCopy];
//    } else {
//      items = [@[flexSpace, cancelButton, flexSpace] mutableCopy];
//    }
//#endif
//
//    if (_processor.isShowTorchButton && !_processor.isFrontCamera) {
//      AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
//      if ([device hasTorch] && [device hasFlash]) {
//        NSURL *bundleURL = [[NSBundle mainBundle] URLForResource:@"CDVBarcodeScanner" withExtension:@"bundle"];
//        NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
//        NSString *imagePath = [bundle pathForResource:@"torch" ofType:@"png"];
//        UIImage *image = [UIImage imageWithContentsOfFile:imagePath];
//
//        id torchButton = [[[UIBarButtonItem alloc]
//                           initWithImage:image
//                                   style:UIBarButtonItemStylePlain
//                                  target:(id)self
//                                  action:@selector(torchButtonPressed:)
//                           ] autorelease];
//
//      [items insertObject:torchButton atIndex:0];
//    }
//  }
//
//    toolbar.items = items;
//
//    bounds = overlayView.bounds;
//
//    [toolbar sizeToFit];
//    CGFloat toolbarHeight  = [toolbar frame].size.height;
//    CGFloat rootViewHeight = CGRectGetHeight(bounds);
//    CGFloat rootViewWidth  = CGRectGetWidth(bounds);
//    CGRect  rectArea       = CGRectMake(0, rootViewHeight - toolbarHeight - bottomPadding, rootViewWidth, toolbarHeight);
//    [toolbar setFrame:rectArea];
//
//    [overlayView addSubview: toolbar];

//    UIImage* reticleImage = [self buildReticleImage];
//    UIView* reticleView = [[[UIImageView alloc] initWithImage:reticleImage] autorelease];
//    CGFloat minAxis = MIN(rootViewHeight, rootViewWidth);
//
//    rectArea = CGRectMake(
//        (CGFloat) (0.5 * (rootViewWidth  - minAxis)),
//        (CGFloat) (0.5 * (rootViewHeight - minAxis)),
//        minAxis,
//        minAxis
//    );
//
//    [reticleView setFrame:rectArea];
//
//    reticleView.opaque           = NO;
//    reticleView.contentMode      = UIViewContentModeScaleAspectFit;
//    reticleView.autoresizingMask = (UIViewAutoresizing) (0
//        | UIViewAutoresizingFlexibleLeftMargin
//        | UIViewAutoresizingFlexibleRightMargin
//        | UIViewAutoresizingFlexibleTopMargin
//        | UIViewAutoresizingFlexibleBottomMargin)
//    ;
//
//    [overlayView addSubview: reticleView];

    // [self resizeElements];
    return overlayView;
}

//--------------------------------------------------------------------------

#define RETICLE_SIZE    500.0f
#define RETICLE_WIDTH    10.0f
#define RETICLE_OFFSET   60.0f
#define RETICLE_ALPHA     0.4f

//-------------------------------------------------------------------------
// builds the green box and red line
//-------------------------------------------------------------------------
- (UIImage*)buildReticleImage {
    UIImage* result;
    UIGraphicsBeginImageContext(CGSizeMake(RETICLE_SIZE, RETICLE_SIZE));
    CGContextRef context = UIGraphicsGetCurrentContext();

    if (self.processor.is1D) {
        UIColor* color = [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:RETICLE_ALPHA];
        CGContextSetStrokeColorWithColor(context, color.CGColor);
        CGContextSetLineWidth(context, RETICLE_WIDTH);
        CGContextBeginPath(context);
        CGFloat lineOffset = (CGFloat) (RETICLE_OFFSET+(0.5*RETICLE_WIDTH));
        CGContextMoveToPoint(context, lineOffset, RETICLE_SIZE/2);
        CGContextAddLineToPoint(context, RETICLE_SIZE-lineOffset, (CGFloat) (0.5*RETICLE_SIZE));
        CGContextStrokePath(context);
    }

    if (self.processor.is2D) {
        UIColor* color = [UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:RETICLE_ALPHA];
        CGContextSetStrokeColorWithColor(context, color.CGColor);
        CGContextSetLineWidth(context, RETICLE_WIDTH);
        CGContextStrokeRect(context,
                            CGRectMake(
                                       RETICLE_OFFSET,
                                       RETICLE_OFFSET,
                                       RETICLE_SIZE-2*RETICLE_OFFSET,
                                       RETICLE_SIZE-2*RETICLE_OFFSET
                                       )
                            );
    }

    result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

#pragma mark CDVBarcodeScannerOrientationDelegate

- (BOOL)shouldAutorotate
{
    return YES;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation
{
    return [[UIApplication sharedApplication] statusBarOrientation];
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAll;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(shouldAutorotateToInterfaceOrientation:)]) {
        return [self.orientationDelegate shouldAutorotateToInterfaceOrientation:interfaceOrientation];
    }

    return YES;
}

- (void) willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration
{
    [UIView setAnimationsEnabled:NO];
    AVCaptureVideoPreviewLayer* previewLayer = self.processor.previewLayer;
    previewLayer.frame = self.view.bounds;

    if (orientation == UIInterfaceOrientationLandscapeLeft) {
        [previewLayer setOrientation:AVCaptureVideoOrientationLandscapeLeft];
    } else if (orientation == UIInterfaceOrientationLandscapeRight) {
        [previewLayer setOrientation:AVCaptureVideoOrientationLandscapeRight];
    } else if (orientation == UIInterfaceOrientationPortrait) {
        [previewLayer setOrientation:AVCaptureVideoOrientationPortrait];
    } else if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
        [previewLayer setOrientation:AVCaptureVideoOrientationPortraitUpsideDown];
    }

    previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

    [self resizeElements];
    [UIView setAnimationsEnabled:YES];
}

-(void) resizeElements {
    CGRect bounds = self.view.bounds;
    if (@available(iOS 11.0, *)) {
        bounds = CGRectMake(bounds.origin.x, bounds.origin.y, bounds.size.width, self.view.safeAreaLayoutGuide.layoutFrame.size.height+self.view.safeAreaLayoutGuide.layoutFrame.origin.y);
    }

    [self.toolbar sizeToFit];
    CGFloat toolbarHeight  = [self.toolbar frame].size.height;
    CGFloat rootViewHeight = CGRectGetHeight(bounds);
    CGFloat rootViewWidth  = CGRectGetWidth(bounds);
    CGRect  rectArea       = CGRectMake(0, rootViewHeight - toolbarHeight, rootViewWidth, toolbarHeight);
    [self.toolbar setFrame:rectArea];

    CGFloat minAxis = MIN(rootViewHeight, rootViewWidth);

    rectArea = CGRectMake(
                          (CGFloat) (0.5 * (rootViewWidth  - minAxis)),
                          (CGFloat) (0.5 * (rootViewHeight - minAxis)),
                          minAxis,
                          minAxis
                          );

    [self.reticleView setFrame:rectArea];
    self.reticleView.center = CGPointMake(self.view.center.x, self.view.center.y-self.toolbar.frame.size.height/2);
}

@end
