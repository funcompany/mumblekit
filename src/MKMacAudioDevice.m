// Copyright 2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <MumbleKit/MKAudio.h>
#import "MKAudioDevice.h"

#import "MKMacAudioDevice.h"

#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AUComponent.h>
#import <AudioToolbox/AudioToolbox.h>

@interface MKMacAudioDevice () {
@public
    MKAudioSettings              _settings;

    AudioUnit                    _playbackAudioUnit;
    AudioBufferList              _buflist;
    int                          _playbackFrequency;
    int                          _playbackChannels;
    int                          _playbackSampleSize;

    AudioUnit                    _recordAudioUnit;
    AudioBufferList              _recordBufList;
    int                          _recordFrequency;
    int                          _recordSampleSize;
    int                          _recordMicChannels;

    MKAudioDeviceOutputFunc      _outputFunc;
    MKAudioDeviceInputFunc       _inputFunc;
}
@end

#pragma mark - helps
static void logMessage(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSMutableString *formattedString = [[NSMutableString alloc] initWithFormat:format
                                                                     arguments:args];
    va_end(args);

    if (![formattedString hasSuffix:@"\n"]) {
        [formattedString appendString:@"\n"];
    }

    NSData *formattedData = [formattedString dataUsingEncoding:NSUTF8StringEncoding];
    [NSFileHandle.fileHandleWithStandardOutput writeData:formattedData];
}

/*
 * Format a 32-bit code (for instance OSStatus) into a string.
 */
static char *codeToString(UInt32 code)
{
    static char str[5] = { '\0' };
    UInt32 swapped = CFSwapInt32HostToBig(code);
    memcpy(str, &swapped, sizeof(swapped));
    return str;
}

static NSString *formatStatusError(OSStatus status)
{
    if (status == noErr) {
        return [NSString stringWithFormat:@"No error (%d)", status];
    }

    return [NSString stringWithFormat:@"Error \"%s\" (%d)",
            codeToString(status),
            status];
}

static void assertStatusSuccess(OSStatus status)
{
    if (status != noErr)
    {
        logMessage(@"Got error %u: '%s'\n", status, codeToString(status));
        abort();
    }

}

static inline AudioObjectPropertyAddress makeGlobalPropertyAddress(AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster,

    };
    return address;
}

static NSString *getStringProperty(AudioDeviceID deviceID,
                                   AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress address = makeGlobalPropertyAddress(selector);
    CFStringRef prop;
    UInt32 propSize = sizeof(prop);
    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &propSize,
                                                 &prop);
    if (status != noErr) {
        return formatStatusError(status);
    }
    return (NSString *)prop;
}

static NSString *getURLProperty(AudioDeviceID deviceID,
                                AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress address = makeGlobalPropertyAddress(selector);
    CFURLRef prop;
    UInt32 propSize = sizeof(prop);
    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &propSize,
                                                 &prop);
    if (status != noErr) {
        return formatStatusError(status);
    }

    NSURL *url = (NSURL *)prop;
    return url.absoluteString;
}

static NSString *getCodeProperty(AudioDeviceID deviceID,
                                 AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress address = makeGlobalPropertyAddress(selector);
    UInt32 prop;
    UInt32 propSize = sizeof(prop);
    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &propSize,
                                                 &prop);
    if (status != noErr) {
        return formatStatusError(status);
    }

    return [NSString stringWithFormat:@"%s (%d)",
            codeToString(prop),
            prop];
}


static NSUInteger getChannelCount(AudioDeviceID deviceID,
                                  AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        scope,
        kAudioObjectPropertyElementMaster,
    };

    AudioBufferList streamConfiguration;
    UInt32 propSize = sizeof(streamConfiguration);
    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &propSize,
                                                 &streamConfiguration);
    assertStatusSuccess(status);

    NSUInteger channelCount = 0;
    for (NSUInteger i = 0; i < streamConfiguration.mNumberBuffers; i++)
    {
        channelCount += streamConfiguration.mBuffers[i].mNumberChannels;
    }

    return channelCount;
}

static NSString *getSourceName(AudioDeviceID deviceID,
                               AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyDataSource,
        scope,
        kAudioObjectPropertyElementMaster,
    };

    UInt32 sourceCode;
    UInt32 propSize = sizeof(sourceCode);

    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &propSize,
                                                 &sourceCode);
    if (status != noErr) {
        return formatStatusError(status);
    }

    return [NSString stringWithFormat:@"%s (%d)",
            codeToString(sourceCode),
            sourceCode];
}
#pragma mark -

static OSStatus inputCallback(void *udata, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                              UInt32 busnum, UInt32 nframes, AudioBufferList *buflist) {
    MKMacAudioDevice *dev = (MKMacAudioDevice *)udata;
    OSStatus err;
        
    if (! dev->_recordBufList.mBuffers->mData) {
        NSLog(@"MKMacAudioDevice: No buffer allocated.");
        dev->_recordBufList.mNumberBuffers = 1;
        AudioBuffer *b = dev->_recordBufList.mBuffers;
        b->mNumberChannels = dev->_recordMicChannels;
        b->mDataByteSize = dev->_recordSampleSize * nframes;
        b->mData = calloc(1, b->mDataByteSize);
    }
    
    if (dev->_recordBufList.mBuffers->mDataByteSize < (dev->_recordSampleSize * nframes)) {
        NSLog(@"MKMacAudioDevice: Buffer too small. Allocating more space.");
        AudioBuffer *b = dev->_recordBufList.mBuffers;
        free(b->mData);
        b->mDataByteSize = dev->_recordSampleSize * nframes;
        b->mData = calloc(1, b->mDataByteSize);
    }
    
    /*
     AudioUnitRender modifies the mDataByteSize members with the
     actual read bytes count. We need to write it back otherwise
     we'll reallocate the buffer even if not needed.
     */
    UInt32 dataByteSize = dev->_buflist.mBuffers->mDataByteSize;
    err = AudioUnitRender(dev->_recordAudioUnit, flags, ts, busnum, nframes, &dev->_recordBufList);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: AudioUnitRender failed. err = %ld", (unsigned long)err);
        return err;
    }
    dev->_buflist.mBuffers->mDataByteSize = dataByteSize;
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    short *buf = (short *) dev->_recordBufList.mBuffers->mData;
    MKAudioDeviceInputFunc inputFunc = dev->_inputFunc;
    if (inputFunc) {
        inputFunc(buf, nframes);
    }
    [pool release];
    
    return noErr;
}

static OSStatus outputCallback(void *udata, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                               UInt32 busnum, UInt32 nframes, AudioBufferList *buflist) {
    
    MKMacAudioDevice *dev = (MKMacAudioDevice *) udata;
    AudioBuffer *buf = buflist->mBuffers;
    MKAudioDeviceOutputFunc outputFunc = dev->_outputFunc;
    BOOL done;
    
    if (outputFunc == NULL) {
        // No frames available yet.
        buf->mDataByteSize = 0;
        return -1;
    }
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    done = outputFunc(buf->mData, nframes);
    if (! done) {
        // No frames available yet.
        buf->mDataByteSize = 0;
        [pool release];
        return -1;
    }
    
    [pool release];
    return noErr;
}

@implementation MKMacAudioDevice

- (id) initWithSettings:(MKAudioSettings *)settings {
    if ((self = [super init])) {
        memcpy(&_settings, settings, sizeof(MKAudioSettings));
    }
    return self;
}

- (void) dealloc {
    [_inputFunc release];
    [_outputFunc release];
    [super dealloc];
}

- (BOOL) setupRecording {
    UInt32 len;
    UInt32 val;
    OSStatus err;
    AudioComponent comp;
    AudioComponentDescription desc;
    AudioStreamBasicDescription fmt;
    AudioDeviceID devId;
    
    // Get default device
    // Check the number of devices.
    AudioObjectPropertyAddress address = makeGlobalPropertyAddress(kAudioHardwarePropertyDefaultInputDevice);
    UInt32 devicesDataSize;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                                     &address,
                                                     0,
                                                     NULL,
                                                     &devicesDataSize);
    assertStatusSuccess(status);
    // Get the devices.
    int count = devicesDataSize / sizeof(AudioDeviceID);
    AudioDeviceID deviceIDs[count];
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                        &address,
                                        0,
                                        NULL,
                                        &devicesDataSize,
                                        deviceIDs);
    assertStatusSuccess(status);
    if (count > 0) {
        devId = deviceIDs[0];
    } else {
        NSLog(@"MKMacAudioDevice: Unable to query for default device.");
        return NO;
    }
    
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_HALOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    
    comp = AudioComponentFindNext(NULL, &desc);
    if (! comp) {
        NSLog(@"MKMacAudioDevice: Unable to find AudioUnit.");
        return NO;
    }
    
    err = AudioComponentInstanceNew(comp, (AudioComponentInstance *) &_recordAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to instantiate new AudioUnit.");
        return NO;
    }
    
    err = AudioUnitInitialize(_recordAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to initialize AudioUnit.");
        return NO;
    }
    
    val = 1;
    err = AudioUnitSetProperty(_recordAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &val, sizeof(UInt32));
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to configure input scope on AudioUnit.");
        return NO;
    }
    
    val = 0;
    err = AudioUnitSetProperty(_recordAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &val, sizeof(UInt32));
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to configure output scope on AudioUnit.");
        return NO;
    }
    
    // Set default device
    len = sizeof(AudioDeviceID);
    err = AudioUnitSetProperty(_recordAudioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devId, len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to set default device.");
        return NO;
    }
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitGetProperty(_recordAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &fmt, &len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to query device for stream info.");
        return NO;
    }
    
    if (fmt.mChannelsPerFrame > 1) {
        NSLog(@"MKMacAudioDevice: Input device with more than one channel detected. Defaulting to 1.");
    }
    
    _recordFrequency = (int) fmt.mSampleRate;
    _recordMicChannels = 1;
    _recordSampleSize = _recordMicChannels * sizeof(short);
    
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel = sizeof(short) * 8;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mSampleRate = _recordFrequency;
    fmt.mChannelsPerFrame = _recordMicChannels;
    fmt.mBytesPerFrame = _recordSampleSize;
    fmt.mBytesPerPacket = _recordSampleSize;
    fmt.mFramesPerPacket = 1;
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitSetProperty(_recordAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to set stream format for output device. (output scope)");
        return NO;
    }
    
    AURenderCallbackStruct cb;
    cb.inputProc = inputCallback;
    cb.inputProcRefCon = self;
    len = sizeof(AURenderCallbackStruct);
    err = AudioUnitSetProperty(_recordAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to setup callback.");
        return NO;
    }
    
    err = AudioOutputUnitStart(_recordAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to start AudioUnit.");
        return NO;
    }
    
    return YES;
}

- (BOOL) teardownRecording {
    OSStatus err;
    
    err = AudioOutputUnitStop(_recordAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: unable to stop AudioUnit.");
        return NO;
    }
    
    err = AudioComponentInstanceDispose(_recordAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: unable to dispose of AudioUnit.");
        return NO;
    }
    
    AudioBuffer *b = _recordBufList.mBuffers;
    if (b && b->mData)
        free(b->mData);
    
    NSLog(@"MKMacAudioDevice: teardown finished.");
    return YES;
}

- (BOOL) setupPlayback {
    UInt32 len;
    OSStatus err;
    AudioComponent comp;
    AudioComponentDescription desc;
    AudioStreamBasicDescription fmt;
    
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_HALOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    
    comp = AudioComponentFindNext(NULL, &desc);
    if (! comp) {
        NSLog(@"MKMacAudioDevice: Unable to find AudioUnit.");
        return NO;
    }
    
    err = AudioComponentInstanceNew(comp, (AudioComponentInstance *) &_playbackAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to instantiate new AudioUnit.");
        return NO;
    }
    
    err = AudioUnitInitialize(_playbackAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to initialize AudioUnit.");
        return NO;
    }
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitGetProperty(_playbackAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, &len);
    if (err != noErr) {
        NSLog(@"MKAudioOuptut: Unable to get output stream format from AudioUnit.");
        return NO;
    }

    NSLog(@"MKAudioOuptut fmt.mSampleRate: %f", fmt.mSampleRate);
    _playbackFrequency = (int) 16000;
    _playbackChannels = (int) fmt.mChannelsPerFrame;
    _playbackSampleSize = _playbackChannels * sizeof(short);
    
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel = sizeof(short) * 8;
    
    NSLog(@"MKMacAudioDevice: Output device currently configured as %iHz sample rate, %i channels, %i sample size", _playbackFrequency, _playbackChannels, _playbackSampleSize);
    
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mSampleRate = (float) _playbackFrequency;
    fmt.mBytesPerFrame = _playbackSampleSize;
    fmt.mBytesPerPacket = _playbackSampleSize;
    fmt.mFramesPerPacket = 1;
    
    len = sizeof(AudioStreamBasicDescription);
    err = AudioUnitSetProperty(_playbackAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to set stream format for output device.");
        return NO;
    }
    
    AURenderCallbackStruct cb;
    cb.inputProc = outputCallback;
    cb.inputProcRefCon = self;
    len = sizeof(AURenderCallbackStruct);
    err = AudioUnitSetProperty(_playbackAudioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &cb, len);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Could not set render callback.");
        return NO;
    }
    
    // On desktop we call AudioDeviceSetProperty() with kAudioDevicePropertyBufferFrameSize
    // to setup our frame size.
    
    err = AudioOutputUnitStart(_playbackAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: Unable to start AudioUnit");
        return NO;
    }
    
    return YES;
}

- (BOOL) teardownPlayback {
    OSStatus err = AudioOutputUnitStop(_playbackAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: unable to stop AudioUnit.");
        return NO;
    }
    
    err = AudioComponentInstanceDispose(_playbackAudioUnit);
    if (err != noErr) {
        NSLog(@"MKMacAudioDevice: unable to dispose of AudioUnit.");
        return NO;
    }
    
    NSLog(@"MKMacAudioDevice: teardown finished.");
    return YES;
}

- (BOOL) setupDevice {
    BOOL ok = YES;
    if (ok)
        ok = [self setupRecording];
    if (ok)
        ok = [self setupPlayback];
    return ok;
}

- (BOOL) teardownDevice {
    BOOL ok = YES;
    if (ok)
        ok = [self teardownRecording];
    if (ok)
        ok = [self teardownPlayback];
    return ok;
}

- (void) setupOutput:(MKAudioDeviceOutputFunc)outf {
    _outputFunc = [outf copy];
}

- (void) setupInput:(MKAudioDeviceInputFunc)inf {
    _inputFunc = [inf copy];
}

- (int) inputSampleRate {
    return _recordFrequency;
}

- (int) outputSampleRate {
    return _playbackFrequency;
}

- (int) numberOfInputChannels {
    return _recordMicChannels;
}

- (int) numberOfOutputChannels {
    return _playbackChannels;
}

@end
