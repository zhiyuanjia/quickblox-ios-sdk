//
//  MainViewController.m
//  SimpleSample-videochat-ios
//
//  Created by QuickBlox team on 1/02/13.
//  Copyright (c) 2013 QuickBlox. All rights reserved.
//

#import "MainViewController.h"
#import "AppDelegate.h"

#import "TPCircularBuffer.h"

#define kBufferLength 32768
#define qbAudioDataSizeForSecods(second) 512*(32*second)

@interface MainViewController ()
@end

@implementation MainViewController{
    TPCircularBuffer circularBuffer;
}

@synthesize opponentID;

- (void)dealloc{
    
    // Release buffer resources
    TPCircularBufferCleanup(&circularBuffer);
    
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    opponentVideoView.layer.borderWidth = 1;
    opponentVideoView.layer.borderColor = [[UIColor grayColor] CGColor];
    opponentVideoView.layer.cornerRadius = 5;
    
    AppDelegate *appDelegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
    navBar.topItem.title = appDelegate.currentUser == 1 ? @"User 1" : @"User 2";
    [callButton setTitle:appDelegate.currentUser == 1 ? @"Call User2" : @"Call User1" forState:UIControlStateNormal];
    
    if(!QB_SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"7.0")){
        audioOutput.transform = CGAffineTransformScale(CGAffineTransformIdentity, 0.8, 0.8);
        audioOutput.frame = CGRectMake(audioOutput.frame.origin.x-15, audioOutput.frame.origin.y, audioOutput.frame.size.width+50, audioOutput.frame.size.height);
        videoOutput.transform = CGAffineTransformScale(CGAffineTransformIdentity, 0.8, 0.8);
    }
    
    
    // Setup Video & Audio capture
    //
    [self setupVideoCapture];
	[self setupAudioCapture];
}

- (void)viewDidAppear:(BOOL)animated{
    [super viewDidAppear:animated];
    
    // Start sending chat presence
    //
    [QBChat instance].delegate = self;
    [NSTimer scheduledTimerWithTimeInterval:30 target:[QBChat instance] selector:@selector(sendPresence) userInfo:nil repeats:YES];
}


#pragma mark -
#pragma mark Video and audio setup

-(void) setupVideoCapture{
	self.captureSession = [[AVCaptureSession alloc] init];
    
    __block NSError *error = nil;
    
    // set preset
    [self.captureSession setSessionPreset:AVCaptureSessionPresetLow];
    
    
    // Setup the Video input
    AVCaptureDevice *videoDevice = [self frontFacingCamera];
    //
    AVCaptureDeviceInput *captureVideoInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
    if(error){
        QBDLogEx(@"deviceInputWithDevice Video error: %@", error);
    }else{
        if ([self.captureSession  canAddInput:captureVideoInput]){
            [self.captureSession addInput:captureVideoInput];
        }else{
            QBDLogEx(@"cantAddInput Video");
        }
    }
    
    // Setup Video output
    AVCaptureVideoDataOutput *videoCaptureOutput = [[AVCaptureVideoDataOutput alloc] init];
    videoCaptureOutput.alwaysDiscardsLateVideoFrames = YES;
    //
    // Set the video output to store frame in BGRA (It is supposed to be faster)
    NSString* key = (NSString*)kCVPixelBufferPixelFormatTypeKey;
    NSNumber* value = [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA];
    NSDictionary* videoSettings = [NSDictionary dictionaryWithObject:value forKey:key];
    [videoCaptureOutput setVideoSettings:videoSettings];
    /*And we create a capture session*/
    if([self.captureSession canAddOutput:videoCaptureOutput]){
        [self.captureSession addOutput:videoCaptureOutput];
    }else{
        QBDLogEx(@"cantAddOutput");
    }
    
	
    // set FPS
    int framesPerSecond = 3;
    AVCaptureConnection *conn = [videoCaptureOutput connectionWithMediaType:AVMediaTypeVideo];
    if (conn.isVideoMinFrameDurationSupported){
        conn.videoMinFrameDuration = CMTimeMake(1, framesPerSecond);
    }
    if (conn.isVideoMaxFrameDurationSupported){
        conn.videoMaxFrameDuration = CMTimeMake(1, framesPerSecond);
    }
    
    // set portrait orientation
    [conn setVideoOrientation:AVCaptureVideoOrientationPortrait];
    
    /*We create a serial queue to handle the processing of our frames*/
    dispatch_queue_t callbackQueue= dispatch_queue_create("cameraQueue", NULL);
    [videoCaptureOutput setSampleBufferDelegate:self queue:callbackQueue];
    
    // Add preview layer
    AVCaptureVideoPreviewLayer *prewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.captureSession];
	[prewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
    CGRect layerRect = [[myVideoView layer] bounds];
	[prewLayer setBounds:layerRect];
	[prewLayer setPosition:CGPointMake(CGRectGetMidX(layerRect),CGRectGetMidY(layerRect))];
    myVideoView.hidden = NO;
    [myVideoView.layer addSublayer:prewLayer];
	
	
    /*We start the capture*/
    [self.captureSession startRunning];
}

-(void) setupAudioCapture{
    // start audio IO
    //
    [[QBAudioIOService shared] start];
    
    // Route audio to speaker
    //
    [[QBAudioIOService shared] routeToSpeaker];
	
    // Create ring buffer
    //
    TPCircularBufferInit(&circularBuffer, kBufferLength);
    
    // Start processing
    //
	[[QBAudioIOService shared] setInputBlock:^(AudioBuffer buffer){
        [self.videoChat processVideoChatCaptureAudioBuffer:buffer];
    }];
    //
    [[QBAudioIOService shared] start];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
	[self.videoChat processVideoChatCaptureVideoSample:sampleBuffer];
}

- (AVCaptureDevice *) cameraWithPosition:(AVCaptureDevicePosition) position{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices) {
        if ([device position] == position) {
            return device;
        }
    }
    return nil;
}

- (AVCaptureDevice *) backFacingCamera{
    return [self cameraWithPosition:AVCaptureDevicePositionBack];
}

- (AVCaptureDevice *) frontFacingCamera{
    return [self cameraWithPosition:AVCaptureDevicePositionFront];
}

- (void)didReceiveAudioBuffer:(AudioBuffer)buffer{
	
    // Put audio into circular buffer
    //
    TPCircularBufferProduceBytes(&circularBuffer, buffer.mData, buffer.mDataByteSize);
    
    // Get number of bytes in circular buffer
    //
    int32_t availableBytes;
    TPCircularBufferTail(&circularBuffer, &availableBytes);

    // If output block is NIL and we have audio data for 0.5 second
    //
	if([[QBAudioIOService shared] outputBlock] == nil && availableBytes > qbAudioDataSizeForSecods(0.5)){
        
        QBDLogEx(@"Set output block");
        [[QBAudioIOService shared] setOutputBlock:^(AudioBuffer buffer) {
            
            int32_t availableBytesInBuffer;
            void *cbuffer = TPCircularBufferTail(&circularBuffer, &availableBytesInBuffer);
            
            // Read audio data if exist
            if(availableBytesInBuffer > 0){
                int min = MIN(buffer.mDataByteSize, availableBytesInBuffer);
                memcpy(buffer.mData, cbuffer, min);
                TPCircularBufferConsume(&circularBuffer, min);
            }else{
                // No data to play -> mute output
                QBDLogEx(@"No data to play -> mute output");
                [[QBAudioIOService shared] setOutputBlock:nil];
            }
            
            // If there is to much audio data to play -> clear buffer & mute output
            //
            if(availableBytes > qbAudioDataSizeForSecods(3)) {
                QBDLogEx(@"There is to much audio data to play -> clear buffer & mute output");
                TPCircularBufferClear(&circularBuffer);
                
                [[QBAudioIOService shared] setOutputBlock:nil];
            }
        }];
	}
}


#pragma mark -
#pragma mark Actions

- (IBAction)audioOutputDidChange:(UISegmentedControl *)sender{
    if(sender.selectedSegmentIndex == 0){
        [[QBAudioIOService shared] routeToSpeaker];
    }else{
        [[QBAudioIOService shared] routeToHeadphone];
    }
}

- (IBAction)videoOutputDidChange:(UISegmentedControl *)sender{
    [self.captureSession beginConfiguration];
    
    // remove old input
    [self.captureSession removeInput:[self.captureSession inputs][0]];
    
    // choose proper input
    AVCaptureDevice *__videoDevice;
    if(sender.selectedSegmentIndex == 0){
        __videoDevice = [self frontFacingCamera];
    }else{
        __videoDevice = [self backFacingCamera];
    }
    
    // add new one
    NSError *error = nil;
    AVCaptureDeviceInput *captureVideoInput = [AVCaptureDeviceInput deviceInputWithDevice:__videoDevice error:&error];
    if(error){
        QBDLogEx(@"deviceInputWithDevice error: %@", error);
    }else{
        if ([self.captureSession  canAddInput:captureVideoInput]){
            [self.captureSession addInput:captureVideoInput];
        }else{
            QBDLogEx(@"cantAddInput");
        }
    }
    
    // set portrait orientation
    AVCaptureConnection *conn = [self.captureSession.outputs[0] connectionWithMediaType:AVMediaTypeVideo];
    [conn setVideoOrientation:AVCaptureVideoOrientationPortrait];
    
    [self.captureSession commitConfiguration];
}

- (IBAction)call:(id)sender{
    // Call
    if(callButton.tag == 101){
        callButton.tag = 102;
        
        // Setup video chat
        //
        if(self.videoChat == nil){
            self.videoChat = [[QBChat instance] createAndRegisterVideoChatInstance];
            self.videoChat.viewToRenderOpponentVideoStream = opponentVideoView;
            self.videoChat.viewToRenderOwnVideoStream = myVideoView;
        }
        
		// setup custom captures
        //
		self.videoChat.isUseCustomAudioChatSession = YES;
		self.videoChat.isUseCustomVideoChatCaptureSession = YES;
    
        // Call user by ID
        //
        [self.videoChat callUser:[opponentID integerValue] conferenceType:QBVideoChatConferenceTypeAudioAndVideo];

        callButton.hidden = YES;
        ringigngLabel.hidden = NO;
        ringigngLabel.text = @"Calling...";
        ringigngLabel.frame = CGRectMake(128, 375, 90, 37);
        callingActivityIndicator.hidden = NO;

    // Finish
    }else{
        callButton.tag = 101;
        
        // Finish call
        //
        [self.videoChat finishCall];
        
        myVideoView.hidden = YES;
        opponentVideoView.layer.contents = (id)[[UIImage imageNamed:@"person.png"] CGImage];
        opponentVideoView.image = [UIImage imageNamed:@"person.png"];
        AppDelegate *appDelegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
        [callButton setTitle:appDelegate.currentUser == 1 ? @"Call User2" : @"Call User1" forState:UIControlStateNormal];
        
        opponentVideoView.layer.borderWidth = 1;
        
        [startingCallActivityIndicator stopAnimating];
        
        
        // release video chat
        //
        [[QBChat instance] unregisterVideoChatInstance:self.videoChat];
        self.videoChat = nil;
    }
}

- (void)reject{
    // Reject call
    //
    if(self.videoChat == nil){
        self.videoChat = [[QBChat instance] createAndRegisterVideoChatInstanceWithSessionID:sessionID];
    }
    [self.videoChat rejectCallWithOpponentID:videoChatOpponentID];
    //
    //
    [[QBChat instance] unregisterVideoChatInstance:self.videoChat];
    self.videoChat = nil;

    // update UI
    callButton.hidden = NO;
    ringigngLabel.hidden = YES;
    
    // release player
    ringingPlayer = nil;
}

- (void)accept{
    NSLog(@"accept");
    
    // Setup video chat
    //
    if(self.videoChat == nil){
        self.videoChat = [[QBChat instance] createAndRegisterVideoChatInstanceWithSessionID:sessionID];
        self.videoChat.viewToRenderOpponentVideoStream = opponentVideoView;
        self.videoChat.viewToRenderOwnVideoStream = myVideoView;
    }
    
	// setup custom capture
    //
	self.videoChat.isUseCustomAudioChatSession = YES;
	self.videoChat.isUseCustomVideoChatCaptureSession = YES;
    
    // Accept call
    //
    [self.videoChat acceptCallWithOpponentID:videoChatOpponentID conferenceType:videoChatConferenceType];

    ringigngLabel.hidden = YES;
    callButton.hidden = NO;
    [callButton setTitle:@"Hang up" forState:UIControlStateNormal];
    callButton.tag = 102;
    
    opponentVideoView.layer.borderWidth = 0;
    
    [startingCallActivityIndicator startAnimating];
    
     myVideoView.hidden = NO;
    
    ringingPlayer = nil;
}

- (void)hideCallAlert{
    [self.callAlert dismissWithClickedButtonIndex:-1 animated:YES];
    self.callAlert = nil;
    
    callButton.hidden = NO;
}

#pragma mark -
#pragma mark AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag{
    ringingPlayer = nil;
}


#pragma mark -
#pragma mark QBChatDelegate 
//
// VideoChat delegate

-(void) chatDidReceiveCallRequestFromUser:(NSUInteger)userID withSessionID:(NSString *)_sessionID conferenceType:(enum QBVideoChatConferenceType)conferenceType{
    NSLog(@"chatDidReceiveCallRequestFromUser %lu", (unsigned long)userID);
    
    // save  opponent data
    videoChatOpponentID = userID;
    videoChatConferenceType = conferenceType;
    sessionID = _sessionID;
    
    
    callButton.hidden = YES;
    
    // show call alert
    //
    if (self.callAlert == nil) {
        AppDelegate *appDelegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
        NSString *message = [NSString stringWithFormat:@"%@ is calling. Would you like to answer?", appDelegate.currentUser == 1 ? @"User 2" : @"User 1"];
        self.callAlert = [[UIAlertView alloc] initWithTitle:@"Call" message:message delegate:self cancelButtonTitle:@"Decline" otherButtonTitles:@"Accept", nil];
        [self.callAlert show];
    }
    
    // hide call alert if opponent has canceled call
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideCallAlert) object:nil];
    [self performSelector:@selector(hideCallAlert) withObject:nil afterDelay:4];
    
    // play call music
    //
    if(ringingPlayer == nil){
        NSString *path =[[NSBundle mainBundle] pathForResource:@"ringing" ofType:@"wav"];
        NSURL *url = [NSURL fileURLWithPath:path];
        ringingPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:NULL];
        ringingPlayer.delegate = self;
        [ringingPlayer setVolume:1.0];
        [ringingPlayer play];
    }
}

-(void) chatCallUserDidNotAnswer:(NSUInteger)userID{
    NSLog(@"chatCallUserDidNotAnswer %lu", (unsigned long)userID);
    
    callButton.hidden = NO;
    ringigngLabel.hidden = YES;
    callingActivityIndicator.hidden = YES;
    callButton.tag = 101;
    
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"QuickBlox VideoChat" message:@"User isn't answering. Please try again." delegate:nil cancelButtonTitle:@"Ok" otherButtonTitles:nil];
    [alert show];
}

-(void) chatCallDidRejectByUser:(NSUInteger)userID{
     NSLog(@"chatCallDidRejectByUser %lu", (unsigned long)userID);
    
    callButton.hidden = NO;
    ringigngLabel.hidden = YES;
    callingActivityIndicator.hidden = YES;
    
    callButton.tag = 101;
    
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"QuickBlox VideoChat" message:@"User has rejected your call." delegate:nil cancelButtonTitle:@"Ok" otherButtonTitles:nil];
    [alert show];
}

-(void) chatCallDidAcceptByUser:(NSUInteger)userID{
    NSLog(@"chatCallDidAcceptByUser %lu", (unsigned long)userID);
    
    ringigngLabel.hidden = YES;
    callingActivityIndicator.hidden = YES;
    
    opponentVideoView.layer.borderWidth = 0;
    
    callButton.hidden = NO;
    [callButton setTitle:@"Hang up" forState:UIControlStateNormal];
    callButton.tag = 102;
    
     myVideoView.hidden = NO;
    
    [startingCallActivityIndicator startAnimating];
}

-(void) chatCallDidStopByUser:(NSUInteger)userID status:(NSString *)status{
    NSLog(@"chatCallDidStopByUser %lu purpose %@", (unsigned long)userID, status);
    
    if([status isEqualToString:kStopVideoChatCallStatus_OpponentDidNotAnswer]){
        
        self.callAlert.delegate = nil;
        [self.callAlert dismissWithClickedButtonIndex:0 animated:YES];
        self.callAlert = nil;
     
        ringigngLabel.hidden = YES;
        
        ringingPlayer = nil;
    
    }else{
        myVideoView.hidden = YES;
        opponentVideoView.layer.contents = (id)[[UIImage imageNamed:@"person.png"] CGImage];
        opponentVideoView.layer.borderWidth = 1;
        AppDelegate *appDelegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
        [callButton setTitle:appDelegate.currentUser == 1 ? @"Call User2" : @"Call User1" forState:UIControlStateNormal];
        callButton.tag = 101;
    }
    
    callButton.hidden = NO;
    
    // release video chat
    //
    [[QBChat instance] unregisterVideoChatInstance:self.videoChat];
    self.videoChat = nil;
}

- (void)chatCallDidStartWithUser:(NSUInteger)userID sessionID:(NSString *)sessionID{
    [startingCallActivityIndicator stopAnimating];
}

- (void)didStartUseTURNForVideoChat{
//    NSLog(@"_____TURN_____TURN_____");
}


#pragma mark -
#pragma mark UIAlertView

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex{
    switch (buttonIndex) {
        // Reject
        case 0:
            [self reject];
            break;
        // Accept
        case 1:
            [self accept];
            break;
            
        default:
            break;
    }
    
    self.callAlert = nil;
}

@end
