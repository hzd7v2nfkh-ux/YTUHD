#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <HBLog.h>
#import <substrate.h>
#import "Header.h"

typedef struct {
    const unsigned int *data;
    uint64_t length;
} Span;

extern "C" {
    BOOL UseVP9AV1();
    BOOL AllVP9();
    BOOL ApplyGrain();
    BOOL DisableServerABR();
    int DecodeThreads();
    BOOL SkipLoopFilter();
    BOOL LoopFilterOptimization();
    BOOL RowThreading();
}

@interface HAMVideoDecoder : NSObject
@property (nonatomic, readwrite, weak) id<HAMVideoDecoderDelegate> delegate;
- (void)terminate;
@end

static HAMVideoDecoder *prepareDecoder(MLVideoDecoderFactory *self, id delegate, id delegateQueue, HAMFormatDescription *formatDescription, NSDictionary *pixelBufferAttributes) {
    HAMVideoDecoder *preparedDecoder = [self valueForKey:@"_preparedDecoder"];
    if (preparedDecoder) {
        if ([self valueForKey:@"_delegateQueue"] == delegateQueue) {
            HAMFormatDescription *preparedFormat = [self valueForKey:@"_preparedFormatDescription"];
            CMFormatDescriptionRef preparedFormatDescription = [preparedFormat formatDescription];
            if (CMFormatDescriptionEqual([formatDescription formatDescription], preparedFormatDescription)) {
                if ([pixelBufferAttributes isEqualToDictionary:[self valueForKey:@"_preparedPixelBufferAttributes"]]) {
                    [self clearPreparedDecoder];
                    preparedDecoder.delegate = delegate;
                    return preparedDecoder;
                }
            }    
        }
        [preparedDecoder terminate];
        [self clearPreparedDecoder];
    }
    return nil;
}

@interface YTUHDVPXVideoDecoder : NSObject
- (instancetype)initWithDelegate:(id)delegate
                   delegateQueue:(id)delegateQueue
                     decodeQueue:(id)decodeQueue
           pixelBufferAttributes:(id)pixelBufferAttributes
                          config:(HAMVPXDecoderConfig)config;
@end

@interface YTUHDDav1dVideoDecoder : NSObject
- (instancetype)initWithDelegate:(id)delegate
                   delegateQueue:(id)delegateQueue
                     decodeQueue:(id)decodeQueue
           pixelBufferAttributes:(id)pixelBufferAttributes
                          config:(HAMDav1dDecoderConfig)config;
@end

BOOL vtSupportsVP9;
BOOL vtSupportsAV1;

static HAMVPXDecoderConfig YTUHDMakeConfig(void) {
    return (HAMVPXDecoderConfig){
        .threads                = MAX(1, DecodeThreads()),
        .skipLoopFilter         = SkipLoopFilter(),
        .loopFilterOptimization = LoopFilterOptimization(),
        .rowThreading           = RowThreading(),
        ._reserved              = NO,
    };
}

static id YTUHDCreateVPXDecoder(MLVideoDecoderFactory *self, id delegate, id delegateQueue, HAMFormatDescription *formatDescription, id pixelBufferAttributes) {
    id preparedDecoder = self ? prepareDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes) : nil;
    if (preparedDecoder) return preparedDecoder;
    dispatch_queue_t decodeQueue =
        dispatch_queue_create("com.ytuhd.vpx.decode", DISPATCH_QUEUE_SERIAL);
    return [[YTUHDVPXVideoDecoder alloc]
        initWithDelegate:delegate
           delegateQueue:delegateQueue
             decodeQueue:decodeQueue
   pixelBufferAttributes:pixelBufferAttributes
                  config:YTUHDMakeConfig()];
}

static id YTUHDCreateDav1dDecoder(MLVideoDecoderFactory *self, id delegate, id delegateQueue, HAMFormatDescription *formatDescription, id pixelBufferAttributes) {
    id preparedDecoder = self ? prepareDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes) : nil;
    if (preparedDecoder) return preparedDecoder;
    dispatch_queue_t decodeQueue =
        dispatch_queue_create("com.ytuhd.dav1d.decode", DISPATCH_QUEUE_SERIAL);
    return [[YTUHDDav1dVideoDecoder alloc]
        initWithDelegate:delegate
           delegateQueue:delegateQueue
             decodeQueue:decodeQueue
   pixelBufferAttributes:pixelBufferAttributes
                  config:(HAMDav1dDecoderConfig){
                      .threads    = MAX(1, DecodeThreads()),
                      .applyGrain = ApplyGrain(),
                  }];
}

NSArray <MLFormat *> *filteredFormats(NSArray <MLFormat *> *formats) {
    if (AllVP9()) return formats;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(MLFormat *format, NSDictionary *bindings) {
        if (![format isKindOfClass:%c(MLFormat)]) return YES;
        BOOL isVP9 = [[format MIMEType] videoCodec] == 'vp09';
        NSString *qualityLabel = [format qualityLabel];
        BOOL isHighRes = [qualityLabel hasPrefix:@"2160p"] || [qualityLabel hasPrefix:@"1440p"];
        BOOL isVP9orAV1 = isVP9 || [[format MIMEType] videoCodec] == 'av01';
        return (isHighRes && isVP9orAV1) || !isVP9orAV1;
    }];
    return [formats filteredArrayUsingPredicate:predicate];
}

static void hookFormatsBase(YTIHamplayerConfig *config) {
    if ([config.videoAbrConfig respondsToSelector:@selector(setPreferSoftwareHdrOverHardwareSdr:)])
        config.videoAbrConfig.preferSoftwareHdrOverHardwareSdr = YES;
    if ([config respondsToSelector:@selector(setDisableResolveOverlappingQualitiesByCodec:)])
        config.disableResolveOverlappingQualitiesByCodec = NO;
    YTIHamplayerStreamFilter *filter = config.streamFilter;
    filter.enableVideoCodecSplicing = YES;
    filter.av1.maxArea = MAX_PIXELS;
    filter.av1.maxFps = MAX_FPS;
    filter.vp9.maxArea = MAX_PIXELS;
    filter.vp9.maxFps = MAX_FPS;
}

static void hookFormats(MLABRPolicy *self) {
    hookFormatsBase([self valueForKey:@"_hamplayerConfig"]);
}

%hook MLHAMPlayerItem

- (void)load {
    hookFormatsBase([self valueForKey:@"_hamplayerConfig"]);
    %orig;
}

- (void)loadWithInitialSeekRequired:(BOOL)initialSeekRequired initialSeekTime:(double)initialSeekTime {
    hookFormatsBase([self valueForKey:@"_hamplayerConfig"]);
    %orig;
}

%end

%hook YTIHamplayerHotConfig

%new(i@:)
- (int)libvpxDecodeThreads { return DecodeThreads(); }

%new(B@:)
- (BOOL)libvpxRowThreading { return RowThreading(); }

%new(B@:)
- (BOOL)libvpxSkipLoopFilter { return SkipLoopFilter(); }

%new(B@:)
- (BOOL)libvpxLoopFilterOptimization { return LoopFilterOptimization(); }

%new(i@:)
- (int)libdav1dDecodeThreads { return DecodeThreads(); }

%new(B@:)
- (BOOL)libdav1dApplyGrain { return ApplyGrain(); }

%end

%hook YTColdConfig

- (BOOL)iosPlayerClientSharedConfigPopulateSwAv1MediaCapabilities { return YES; }
- (BOOL)iosPlayerClientSharedConfigPopulateAc3MediaCapabilities { return YES; }
- (BOOL)iosPlayerClientSharedConfigPopulateEac3MediaCapabilities { return YES; }
- (BOOL)iosPlayerClientSharedConfigDisableLibvpxDecoder { return NO; }

%end

%group ServerABR

%hook YTIHamplayerServerABRConfig

%new(B@:)
- (BOOL)skipFilterPreferredVideoFormats { return NO; }

%end

%hook MLABRPolicy

- (void)setFormats:(NSArray *)formats {
    hookFormats(self);
    %orig(filteredFormats(formats));
}

%end

%hook MLABRPolicyOld

- (void)setFormats:(NSArray *)formats {
    hookFormats(self);
    %orig(filteredFormats(formats));
}

%end

%hook MLABRPolicyNew

- (void)setFormats:(NSArray *)formats {
    hookFormats(self);
    %orig(filteredFormats(formats));
}

%end

%hook YTHotConfig

- (BOOL)iosClientGlobalConfigEnableNewMlabrpolicy { return NO; }
- (BOOL)iosPlayerClientSharedConfigDisableServerDrivenAbr { return YES; }
- (BOOL)iosPlayerClientSharedConfigPostponeCabrPreferredFormatFiltering { return YES; }

%end

%end

%hook YTHotConfig

- (BOOL)iosPlayerClientSharedConfigHamplayerPrepareVideoDecoderForAvsbdl { return YES; }
- (BOOL)iosPlayerClientSharedConfigHamplayerAlwaysEnqueueDecodedSampleBuffersToAvsbdl { return YES; }
- (BOOL)iosPlayerClientSharedConfigUseMediaCapabilitiesForClientFiltering { return NO; }
- (BOOL)iosPlayerClientSharedConfigPopulateMoreMediaCapabilities { return YES; }

%end

%hook HAMDefaultABRPolicy

- (id)getSelectableFormatDataAndReturnError:(NSError **)error {
    [self setValue:@(NO) forKey:@"_postponePreferredFormatFiltering"];
    return filteredFormats(%orig);
}

- (void)setFormats:(NSArray *)formats {
    [self setValue:@(YES) forKey:@"_postponePreferredFormatFiltering"];
    %orig(filteredFormats(formats));
}

%end

%hook MLHLSStreamSelector

- (void)didLoadHLSMasterPlaylist:(id)arg1 {
    %orig;
    MLHLSMasterPlaylist *playlist = [self valueForKey:@"_completeMasterPlaylist"];
    NSArray *remotePlaylists = [playlist remotePlaylists];
    [[self delegate] streamSelectorHasSelectableVideoFormats:remotePlaylists];
}

%end

%hook MLHAMSBDLSampleBufferRenderingView

- (NSArray *)supportedCodecs {
    NSArray *orig = %orig;
    BOOL suppressVP9 = !vtSupportsVP9;
    BOOL suppressAV1 = !vtSupportsAV1;
    NSNumber *vp9 = @(kCMVideoCodecType_VP9);
    NSNumber *av1 = @(kCMVideoCodecType_AV1);
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSNumber *codec in orig) {
        if ((suppressVP9 && [codec isEqualToNumber:vp9]) ||
            (suppressAV1 && [codec isEqualToNumber:av1])) {
            continue;
        }
        [filtered addObject:codec];
    }
    return filtered;
}

%end

// بديل SupportsCodec بدون libundirect
// نستخدم %hook مباشرة على MLVideoDecoderFactory
// لتجاوز فحص الكودك بدلاً من البحث عن الدالة في الذاكرة
BOOL overrideSupportsCodec = NO;

%hook MLVideoDecoderFactory

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(NSDictionary *)pixelBufferAttributes preferredOutputFormats:(Span)preferredOutputFormats error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    return %orig;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes setPixelBufferTypeOnlyIfEmpty:(BOOL)setPixelBufferTypeOnlyIfEmpty error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    return %orig;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    return %orig;
}

- (void)prepareDecoderForFormatDescription:(HAMFormatDescription *)formatDescription delegateQueue:(id)delegateQueue {
    %orig;
}

- (void)prepareDecoderForFormatDescription:(HAMFormatDescription *)formatDescription setPixelBufferTypeOnlyIfEmpty:(BOOL)setPixelBufferTypeOnlyIfEmpty delegateQueue:(id)delegateQueue {
    %orig;
}

%end

%hook HAMDefaultVideoDecoderFactory

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes preferredOutputFormats:(Span)preferredOutputFormats error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    return %orig;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes setPixelBufferTypeOnlyIfEmpty:(BOOL)setPixelBufferTypeOnlyIfEmpty error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    return %orig;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    return %orig;
}

%end

%hook YTIIosOnesieHotConfig

%new(B@:)
- (BOOL)prepareVideoDecoder { return YES; }

%end

%ctor {
    vtSupportsVP9 = VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9);
    vtSupportsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DecodeThreadsKey: @2,
        ApplyGrainKey:    @YES,
    }];
    if (UseVP9AV1()) {
        %init;
    }
    if (DisableServerABR()) {
        %init(ServerABR);
    }
}
