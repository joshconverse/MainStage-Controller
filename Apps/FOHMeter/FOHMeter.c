// FOH Meter: a pass-through Audio Unit (v2 effect) that measures its channel strip and sends the level to FOH Bridge
// on this Mac, so strips with no hardware meter source (FX returns) get real meters on the iPad.
//
// While MainStage renders an instance, it sends ~25 UDP datagrams a second to 127.0.0.1:9009, each one OSC message:
//
//   /foh/meter/plugin ,sibb  <context name> <instance id> <peak: float32[] BE> <mean square: float32[] BE>
//
// The context name is the host's name for the strip (kAudioUnitProperty_ContextName). Nothing is sent while the
// instance isn't rendering or is bypassed, so the bridge drops the meter within half a second. Audio passes through
// untouched. Plain C against the AudioComponent plug-in interface: no SDK, no UI (hosts show an empty generic view).
#include <Accelerate/Accelerate.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <os/lock.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum {
    kSubtype = 'FMtr',
    kManufacturer = 'FOHr',
    kMaxChannels = 16,
    kMaxListeners = 64,
    kMaxRenderNotify = 8,
    kDefaultMaxFrames = 1156,       // kAUDefaultMaxFramesPerSlice
    kBridgePort = 9009,             // FOHProtocol.pluginMeterPort
    kSendIntervalMS = 40,
};

typedef struct {
    AudioUnitPropertyID property;
    AudioUnitPropertyListenerProc proc;
    void *userData;
} Listener;

typedef struct {
    AURenderCallback proc;
    void *refCon;
} RenderNotify;

typedef struct {
    AudioComponentPlugInInterface plugIn;   // first: the host calls through it
    AudioComponentInstance component;

    AudioStreamBasicDescription inFormat, outFormat;
    UInt32 maxFrames;
    bool initialized;
    UInt32 bypass, inPlace, offline;
    UInt32 shouldAllocate[2];               // input, output
    AURenderCallbackStruct inputCallback;
    AudioUnitConnection connection;
    bool hasConnection;
    AUPreset preset;                        // presetName retained
    CFStringRef contextName;                // retained

    float *storage;                         // maxFrames × channels, allocated by Initialize
    AudioBufferList *pull;

    os_unfair_lock listenerLock;
    Listener listeners[kMaxListeners];
    int listenerCount;
    RenderNotify notifies[kMaxRenderNotify];
    _Atomic int notifyCount;

    // Written on the audio thread, read and reset by the sender. Held for microseconds on both sides.
    os_unfair_lock levelLock;
    float peak[kMaxChannels];
    double sumSquares[kMaxChannels];
    UInt32 frames, channels, renders;

    // Sender (send queue only, apart from the name, which the host may set from any thread).
    os_unfair_lock nameLock;
    char name[256];
    UInt32 instanceID, lastRenders;
    dispatch_source_t timer;
} FOHMeter;

// MARK: Sending

static dispatch_queue_t SendQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("io.itstudios.foh.meter.send",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static int SendSocket(void) {
    static int fd = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) return;
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    });
    return fd;
}

static size_t PutString(uint8_t *buf, size_t n, const char *s) {
    size_t len = strlen(s) + 1;
    memcpy(buf + n, s, len);
    n += len;
    while (n % 4) buf[n++] = 0;
    return n;
}

static size_t PutInt(uint8_t *buf, size_t n, uint32_t v) {
    v = htonl(v);
    memcpy(buf + n, &v, 4);
    return n + 4;
}

static size_t PutFloats(uint8_t *buf, size_t n, const float *values, UInt32 count) {
    n = PutInt(buf, n, count * 4);
    for (UInt32 i = 0; i < count; i++) {
        uint32_t bits;
        memcpy(&bits, &values[i], 4);
        n = PutInt(buf, n, bits);
    }
    return n;
}

static void SendLevels(FOHMeter *m) {
    float peak[kMaxChannels], meanSquare[kMaxChannels];
    UInt32 channels, frames, renders;
    os_unfair_lock_lock(&m->levelLock);
    channels = m->channels;
    frames = m->frames;
    renders = m->renders;
    for (UInt32 c = 0; c < channels; c++) {
        peak[c] = m->peak[c];
        meanSquare[c] = frames > 0 ? (float)(m->sumSquares[c] / frames) : 0;
        m->peak[c] = 0;
        m->sumSquares[c] = 0;
    }
    m->frames = 0;
    os_unfair_lock_unlock(&m->levelLock);
    if (renders == m->lastRenders || channels == 0 || frames == 0) return;   // not rendering, or bypassed
    m->lastRenders = renders;

    char name[256];
    os_unfair_lock_lock(&m->nameLock);
    memcpy(name, m->name, sizeof name);
    os_unfair_lock_unlock(&m->nameLock);

    uint8_t buf[1024];
    size_t n = 0;
    n = PutString(buf, n, "/foh/meter/plugin");
    n = PutString(buf, n, ",sibb");
    n = PutString(buf, n, name);
    n = PutInt(buf, n, m->instanceID);
    n = PutFloats(buf, n, peak, channels);
    n = PutFloats(buf, n, meanSquare, channels);

    int fd = SendSocket();
    if (fd < 0) return;
    struct sockaddr_in to = { .sin_len = sizeof to, .sin_family = AF_INET, .sin_port = htons(kBridgePort),
                              .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    sendto(fd, buf, n, 0, (const struct sockaddr *)&to, sizeof to);   // nobody listening: dropped
}

// MARK: Helpers

static void Notify(FOHMeter *m, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element) {
    Listener copy[kMaxListeners];
    os_unfair_lock_lock(&m->listenerLock);
    int count = m->listenerCount;
    memcpy(copy, m->listeners, sizeof(Listener) * count);
    os_unfair_lock_unlock(&m->listenerLock);
    for (int i = 0; i < count; i++) {
        if (copy[i].property == property) copy[i].proc(copy[i].userData, m->component, property, scope, element);
    }
}

static AudioStreamBasicDescription CanonicalFormat(Float64 sampleRate, UInt32 channels) {
    return (AudioStreamBasicDescription){
        .mSampleRate = sampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4,
        .mChannelsPerFrame = channels, .mBitsPerChannel = 32,
    };
}

static bool ValidFormat(const AudioStreamBasicDescription *f) {
    return f->mFormatID == kAudioFormatLinearPCM && f->mSampleRate > 0
        && (f->mFormatFlags & kAudioFormatFlagIsFloat) && (f->mFormatFlags & kAudioFormatFlagIsNonInterleaved)
        && !(f->mFormatFlags & kAudioFormatFlagIsBigEndian)
        && f->mBitsPerChannel == 32 && f->mBytesPerFrame == 4 && f->mBytesPerPacket == 4 && f->mFramesPerPacket == 1
        && f->mChannelsPerFrame >= 1 && f->mChannelsPerFrame <= kMaxChannels;
}

static bool SameFormat(const AudioStreamBasicDescription *a, const AudioStreamBasicDescription *b) {
    return a->mSampleRate == b->mSampleRate && a->mFormatID == b->mFormatID && a->mFormatFlags == b->mFormatFlags
        && a->mBytesPerPacket == b->mBytesPerPacket && a->mFramesPerPacket == b->mFramesPerPacket
        && a->mBytesPerFrame == b->mBytesPerFrame && a->mChannelsPerFrame == b->mChannelsPerFrame
        && a->mBitsPerChannel == b->mBitsPerChannel;
}

/// The global scope's stream format is an alias for the output's (as in AUBase).
static AudioStreamBasicDescription *FormatFor(FOHMeter *m, AudioUnitScope scope) {
    switch (scope) {
    case kAudioUnitScope_Input: return &m->inFormat;
    case kAudioUnitScope_Output: case kAudioUnitScope_Global: return &m->outFormat;
    default: return NULL;
    }
}

static void SetName(FOHMeter *m, CFStringRef name) {
    char utf8[256] = "";
    if (name) CFStringGetCString(name, utf8, sizeof utf8, kCFStringEncodingUTF8);
    os_unfair_lock_lock(&m->nameLock);
    memcpy(m->name, utf8, sizeof utf8);
    os_unfair_lock_unlock(&m->nameLock);
}

static void AddInt(CFMutableDictionaryRef d, const char *key, SInt32 value) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
    CFDictionarySetValue(d, k, v);
    CFRelease(k);
    CFRelease(v);
}

static bool IntMatches(CFDictionaryRef d, CFStringRef key, SInt32 expected) {
    CFNumberRef n = CFDictionaryGetValue(d, key);
    SInt32 value;
    return n && CFGetTypeID(n) == CFNumberGetTypeID() && CFNumberGetValue(n, kCFNumberSInt32Type, &value) && value == expected;
}

// MARK: Life cycle

static OSStatus Initialize(void *self) {
    FOHMeter *m = self;
    if (m->initialized) return noErr;
    if (m->inFormat.mChannelsPerFrame != m->outFormat.mChannelsPerFrame) return kAudioUnitErr_FormatNotSupported;
    UInt32 channels = m->outFormat.mChannelsPerFrame;
    m->storage = calloc((size_t)m->maxFrames * channels, sizeof(float));
    m->pull = calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * kMaxChannels);
    if (!m->storage || !m->pull) {
        free(m->storage); free(m->pull);
        m->storage = NULL; m->pull = NULL;
        return kAudio_MemFullError;
    }
    m->initialized = true;
    return noErr;
}

static OSStatus Uninitialize(void *self) {
    FOHMeter *m = self;
    m->initialized = false;
    free(m->storage); free(m->pull);
    m->storage = NULL; m->pull = NULL;
    return noErr;
}

static OSStatus Open(void *self, AudioComponentInstance component) {
    FOHMeter *m = self;
    m->component = component;
    m->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, SendQueue());
    if (!m->timer) return kAudio_MemFullError;
    dispatch_source_set_timer(m->timer, dispatch_time(DISPATCH_TIME_NOW, kSendIntervalMS * NSEC_PER_MSEC),
                              kSendIntervalMS * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(m->timer, ^{ SendLevels(m); });
    dispatch_resume(m->timer);
    return noErr;
}

static void Free(FOHMeter *m) {
    if (m->initialized) Uninitialize(m);
    if (m->contextName) CFRelease(m->contextName);
    if (m->preset.presetName) CFRelease(m->preset.presetName);
    free(m);
}

static OSStatus Close(void *self) {
    FOHMeter *m = self;
    if (!m->timer) { Free(m); return noErr; }
    // The cancel handler runs after any in-flight send, on the send queue, and frees the instance there.
    dispatch_source_set_cancel_handler(m->timer, ^{ Free(m); });
    dispatch_source_cancel(m->timer);
    return noErr;
}

// MARK: Properties

static OSStatus PropertyInfo(FOHMeter *m, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                             UInt32 *outSize, Boolean *outWritable) {
    bool global = scope == kAudioUnitScope_Global;
    bool io = scope == kAudioUnitScope_Input || scope == kAudioUnitScope_Output;
    UInt32 size;
    Boolean writable = false;
    switch (property) {
    case kAudioUnitProperty_ClassInfo:
        if (!global) return kAudioUnitErr_InvalidScope;
        size = sizeof(CFPropertyListRef); writable = true; break;
    case kAudioUnitProperty_MakeConnection:
        if (scope != kAudioUnitScope_Input) return kAudioUnitErr_InvalidScope;
        if (element != 0) return kAudioUnitErr_InvalidElement;
        size = sizeof(AudioUnitConnection); writable = true; break;
    case kAudioUnitProperty_SetRenderCallback:
        if (scope != kAudioUnitScope_Input) return kAudioUnitErr_InvalidScope;
        if (element != 0) return kAudioUnitErr_InvalidElement;
        size = sizeof(AURenderCallbackStruct); writable = true; break;
    case kAudioUnitProperty_SampleRate:
    case kAudioUnitProperty_StreamFormat:
        if (!io && !global) return kAudioUnitErr_InvalidScope;
        if (element != 0) return kAudioUnitErr_InvalidElement;
        size = property == kAudioUnitProperty_SampleRate ? sizeof(Float64) : sizeof(AudioStreamBasicDescription);
        writable = !m->initialized; break;
    case kAudioUnitProperty_ParameterList:
        size = 0; break;
    case kAudioUnitProperty_ElementCount:
        size = sizeof(UInt32); break;
    case kAudioUnitProperty_Latency:
    case kAudioUnitProperty_TailTime:
        if (!global) return kAudioUnitErr_InvalidScope;
        size = sizeof(Float64); break;
    case kAudioUnitProperty_SupportedNumChannels:
        if (!global) return kAudioUnitErr_InvalidScope;
        size = sizeof(AUChannelInfo); break;
    case kAudioUnitProperty_MaximumFramesPerSlice:
        if (!global) return kAudioUnitErr_InvalidScope;
        size = sizeof(UInt32); writable = true; break;
    case kAudioUnitProperty_LastRenderError:
        if (!global) return kAudioUnitErr_InvalidScope;
        size = sizeof(UInt32); break;
    case kAudioUnitProperty_BypassEffect:
    case kAudioUnitProperty_InPlaceProcessing:
    case kAudioUnitProperty_OfflineRender:
        if (!global) return kAudioUnitErr_InvalidScope;
        size = sizeof(UInt32); writable = true; break;
    case kAudioUnitProperty_ShouldAllocateBuffer:
        if (!io) return kAudioUnitErr_InvalidScope;
        if (element != 0) return kAudioUnitErr_InvalidElement;
        size = sizeof(UInt32); writable = true; break;
    case kAudioUnitProperty_ContextName:
        if (!global) return kAudioUnitErr_InvalidScope;
        size = sizeof(CFStringRef); writable = true; break;
    case kAudioUnitProperty_PresentPreset:
        if (!global) return kAudioUnitErr_InvalidScope;
        size = sizeof(AUPreset); writable = true; break;
    case kAudioUnitProperty_HostCallbacks:
        if (!global) return kAudioUnitErr_InvalidScope;
        size = sizeof(HostCallbackInfo); writable = true; break;
    case kAudioUnitProperty_AUHostIdentifier:
        if (!global) return kAudioUnitErr_InvalidScope;
        size = sizeof(AUHostVersionIdentifier); writable = true; break;
    default:
        return kAudioUnitErr_InvalidProperty;
    }
    if (outSize) *outSize = size;
    if (outWritable) *outWritable = writable;
    return noErr;
}

static OSStatus GetPropertyInfo(void *self, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                                UInt32 *outSize, Boolean *outWritable) {
    return PropertyInfo(self, property, scope, element, outSize, outWritable);
}

static OSStatus GetProperty(void *self, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                            void *outData, UInt32 *ioSize) {
    FOHMeter *m = self;
    UInt32 size;
    OSStatus err = PropertyInfo(m, property, scope, element, &size, NULL);
    if (err) return err;
    if (!ioSize) return kAudio_ParamError;
    if (!outData) { *ioSize = size; return noErr; }
    if (*ioSize < size) return kAudioUnitErr_InvalidPropertyValue;
    *ioSize = size;
    switch (property) {
    case kAudioUnitProperty_ClassInfo: {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
        AddInt(d, kAUPresetVersionKey, 0);
        AddInt(d, kAUPresetTypeKey, kAudioUnitType_Effect);
        AddInt(d, kAUPresetSubtypeKey, kSubtype);
        AddInt(d, kAUPresetManufacturerKey, kManufacturer);
        CFDictionarySetValue(d, CFSTR(kAUPresetNameKey), m->preset.presetName ? m->preset.presetName : CFSTR("Untitled"));
        CFDataRef data = CFDataCreate(NULL, NULL, 0);
        CFDictionarySetValue(d, CFSTR(kAUPresetDataKey), data);
        CFRelease(data);
        *(CFPropertyListRef *)outData = d;
        return noErr;
    }
    case kAudioUnitProperty_SampleRate:
        *(Float64 *)outData = FormatFor(m, scope)->mSampleRate;
        return noErr;
    case kAudioUnitProperty_StreamFormat:
        *(AudioStreamBasicDescription *)outData = *FormatFor(m, scope);
        return noErr;
    case kAudioUnitProperty_ParameterList:
        return noErr;
    case kAudioUnitProperty_ElementCount:
        *(UInt32 *)outData = (scope == kAudioUnitScope_Global || scope == kAudioUnitScope_Input
                              || scope == kAudioUnitScope_Output) ? 1 : 0;
        return noErr;
    case kAudioUnitProperty_Latency:
    case kAudioUnitProperty_TailTime:
        *(Float64 *)outData = 0;
        return noErr;
    case kAudioUnitProperty_SupportedNumChannels:
        *(AUChannelInfo *)outData = (AUChannelInfo){ -1, -1 };   // any count, in = out
        return noErr;
    case kAudioUnitProperty_MaximumFramesPerSlice:
        *(UInt32 *)outData = m->maxFrames;
        return noErr;
    case kAudioUnitProperty_LastRenderError:
        *(UInt32 *)outData = 0;
        return noErr;
    case kAudioUnitProperty_BypassEffect:
        *(UInt32 *)outData = m->bypass;
        return noErr;
    case kAudioUnitProperty_InPlaceProcessing:
        *(UInt32 *)outData = m->inPlace;
        return noErr;
    case kAudioUnitProperty_OfflineRender:
        *(UInt32 *)outData = m->offline;
        return noErr;
    case kAudioUnitProperty_ShouldAllocateBuffer:
        *(UInt32 *)outData = m->shouldAllocate[scope == kAudioUnitScope_Output];
        return noErr;
    case kAudioUnitProperty_ContextName:
        if (m->contextName) CFRetain(m->contextName);
        *(CFStringRef *)outData = m->contextName;
        return noErr;
    case kAudioUnitProperty_PresentPreset: {
        AUPreset p = m->preset;
        if (!p.presetName) p.presetName = CFSTR("Untitled");
        CFRetain(p.presetName);
        *(AUPreset *)outData = p;
        return noErr;
    }
    default:
        return kAudioUnitErr_InvalidProperty;   // write-only (render callback, connection, host info)
    }
}

static OSStatus SetProperty(void *self, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                            const void *inData, UInt32 inSize) {
    FOHMeter *m = self;
    UInt32 size;
    Boolean writable;
    OSStatus err = PropertyInfo(m, property, scope, element, &size, &writable);
    if (err) return err;
    if (!inData) return kAudio_ParamError;
    if (inSize < size) return kAudioUnitErr_InvalidPropertyValue;
    switch (property) {
    case kAudioUnitProperty_ClassInfo: {
        CFPropertyListRef plist = *(const CFPropertyListRef *)inData;
        if (!plist || CFGetTypeID(plist) != CFDictionaryGetTypeID()) return kAudioUnitErr_InvalidPropertyValue;
        CFDictionaryRef d = plist;
        if (!IntMatches(d, CFSTR(kAUPresetVersionKey), 0) || !IntMatches(d, CFSTR(kAUPresetTypeKey), kAudioUnitType_Effect)
            || !IntMatches(d, CFSTR(kAUPresetSubtypeKey), kSubtype)
            || !IntMatches(d, CFSTR(kAUPresetManufacturerKey), kManufacturer)) return kAudioUnitErr_InvalidPropertyValue;
        CFStringRef name = CFDictionaryGetValue(d, CFSTR(kAUPresetNameKey));
        if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
            CFRetain(name);
            if (m->preset.presetName) CFRelease(m->preset.presetName);
            m->preset = (AUPreset){ -1, name };
            Notify(m, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0);
        }
        return noErr;
    }
    case kAudioUnitProperty_MakeConnection: {
        const AudioUnitConnection *c = inData;
        m->connection = *c;
        m->hasConnection = c->sourceAudioUnit != NULL;
        if (m->hasConnection) m->inputCallback = (AURenderCallbackStruct){ 0 };
        Notify(m, property, scope, element);
        return noErr;
    }
    case kAudioUnitProperty_SetRenderCallback: {
        m->inputCallback = *(const AURenderCallbackStruct *)inData;
        if (m->inputCallback.inputProc) m->hasConnection = false;
        Notify(m, property, scope, element);
        return noErr;
    }
    case kAudioUnitProperty_SampleRate:
    case kAudioUnitProperty_StreamFormat: {
        AudioStreamBasicDescription *current = FormatFor(m, scope);
        AudioStreamBasicDescription next = *current;
        if (property == kAudioUnitProperty_SampleRate) {
            next.mSampleRate = *(const Float64 *)inData;
            if (!(next.mSampleRate > 0)) return kAudioUnitErr_InvalidPropertyValue;
        } else {
            next = *(const AudioStreamBasicDescription *)inData;
            if (!ValidFormat(&next)) return kAudioUnitErr_FormatNotSupported;
        }
        if (SameFormat(current, &next)) return noErr;
        if (!writable) return kAudioUnitErr_PropertyNotWritable;
        *current = next;
        AudioUnitScope changed = scope == kAudioUnitScope_Global ? kAudioUnitScope_Output : scope;
        Notify(m, kAudioUnitProperty_StreamFormat, changed, 0);
        Notify(m, kAudioUnitProperty_SampleRate, changed, 0);
        return noErr;
    }
    case kAudioUnitProperty_MaximumFramesPerSlice: {
        UInt32 frames = *(const UInt32 *)inData;
        if (frames == m->maxFrames) return noErr;
        if (frames == 0) return kAudioUnitErr_InvalidPropertyValue;
        if (m->initialized) return kAudioUnitErr_Initialized;
        m->maxFrames = frames;
        Notify(m, property, scope, element);
        return noErr;
    }
    case kAudioUnitProperty_BypassEffect: {
        UInt32 bypass = *(const UInt32 *)inData != 0;
        if (bypass == m->bypass) return noErr;
        m->bypass = bypass;
        Notify(m, property, scope, element);
        return noErr;
    }
    case kAudioUnitProperty_InPlaceProcessing:
        m->inPlace = *(const UInt32 *)inData != 0;
        return noErr;
    case kAudioUnitProperty_OfflineRender:
        m->offline = *(const UInt32 *)inData != 0;
        return noErr;
    case kAudioUnitProperty_ShouldAllocateBuffer:
        m->shouldAllocate[scope == kAudioUnitScope_Output] = *(const UInt32 *)inData != 0;
        return noErr;
    case kAudioUnitProperty_ContextName: {
        CFStringRef name = *(const CFStringRef *)inData;
        if (name && CFGetTypeID(name) != CFStringGetTypeID()) return kAudioUnitErr_InvalidPropertyValue;
        if (name) CFRetain(name);
        if (m->contextName) CFRelease(m->contextName);
        m->contextName = name;
        SetName(m, name);
        Notify(m, property, scope, element);
        return noErr;
    }
    case kAudioUnitProperty_PresentPreset: {
        AUPreset p = *(const AUPreset *)inData;
        if (p.presetName) CFRetain(p.presetName);
        if (m->preset.presetName) CFRelease(m->preset.presetName);
        m->preset = p;
        Notify(m, property, scope, element);
        return noErr;
    }
    case kAudioUnitProperty_HostCallbacks:
    case kAudioUnitProperty_AUHostIdentifier:
        return noErr;   // nothing here needs the host's tempo or name
    default:
        return kAudioUnitErr_PropertyNotWritable;
    }
}

static OSStatus AddPropertyListener(void *self, AudioUnitPropertyID property, AudioUnitPropertyListenerProc proc,
                                    void *userData) {
    FOHMeter *m = self;
    if (!proc) return kAudio_ParamError;
    OSStatus err = noErr;
    os_unfair_lock_lock(&m->listenerLock);
    if (m->listenerCount < kMaxListeners) m->listeners[m->listenerCount++] = (Listener){ property, proc, userData };
    else err = kAudio_MemFullError;
    os_unfair_lock_unlock(&m->listenerLock);
    return err;
}

static void RemoveListeners(FOHMeter *m, AudioUnitPropertyID property, AudioUnitPropertyListenerProc proc,
                            bool matchUserData, void *userData) {
    os_unfair_lock_lock(&m->listenerLock);
    int kept = 0;
    for (int i = 0; i < m->listenerCount; i++) {
        Listener l = m->listeners[i];
        bool match = l.property == property && l.proc == proc && (!matchUserData || l.userData == userData);
        if (!match) m->listeners[kept++] = l;
    }
    m->listenerCount = kept;
    os_unfair_lock_unlock(&m->listenerLock);
}

static OSStatus RemovePropertyListener(void *self, AudioUnitPropertyID property, AudioUnitPropertyListenerProc proc) {
    RemoveListeners(self, property, proc, false, NULL);
    return noErr;
}

static OSStatus RemovePropertyListenerWithUserData(void *self, AudioUnitPropertyID property,
                                                   AudioUnitPropertyListenerProc proc, void *userData) {
    RemoveListeners(self, property, proc, true, userData);
    return noErr;
}

static OSStatus AddRenderNotify(void *self, AURenderCallback proc, void *refCon) {
    FOHMeter *m = self;
    if (!proc) return kAudio_ParamError;
    OSStatus err = noErr;
    os_unfair_lock_lock(&m->listenerLock);
    int count = m->notifyCount;
    if (count < kMaxRenderNotify) {
        m->notifies[count] = (RenderNotify){ proc, refCon };
        m->notifyCount = count + 1;   // published after the entry is written
    } else {
        err = kAudio_MemFullError;
    }
    os_unfair_lock_unlock(&m->listenerLock);
    return err;
}

static OSStatus RemoveRenderNotify(void *self, AURenderCallback proc, void *refCon) {
    FOHMeter *m = self;
    os_unfair_lock_lock(&m->listenerLock);
    int count = m->notifyCount, kept = 0;
    for (int i = 0; i < count; i++) {
        if (m->notifies[i].proc != proc || m->notifies[i].refCon != refCon) m->notifies[kept++] = m->notifies[i];
    }
    m->notifyCount = kept;
    os_unfair_lock_unlock(&m->listenerLock);
    return noErr;
}

// MARK: Parameters (none)

static OSStatus GetParameter(void *self, AudioUnitParameterID id, AudioUnitScope scope, AudioUnitElement element,
                             AudioUnitParameterValue *outValue) {
    return kAudioUnitErr_InvalidParameter;
}

static OSStatus SetParameter(void *self, AudioUnitParameterID id, AudioUnitScope scope, AudioUnitElement element,
                             AudioUnitParameterValue value, UInt32 bufferOffset) {
    return kAudioUnitErr_InvalidParameter;
}

static OSStatus ScheduleParameters(void *self, const AudioUnitParameterEvent *events, UInt32 count) {
    return count == 0 ? noErr : kAudioUnitErr_InvalidParameter;
}

// MARK: Render

static void Measure(FOHMeter *m, const AudioBufferList *list, UInt32 channels, UInt32 frames) {
    float peak[kMaxChannels], sum[kMaxChannels];
    for (UInt32 c = 0; c < channels; c++) {
        const float *x = list->mBuffers[c].mData;
        peak[c] = 0;
        sum[c] = 0;
        vDSP_maxmgv(x, 1, &peak[c], frames);
        vDSP_svesq(x, 1, &sum[c], frames);
    }
    os_unfair_lock_lock(&m->levelLock);
    if (m->channels != channels) {
        memset(m->peak, 0, sizeof m->peak);
        memset(m->sumSquares, 0, sizeof m->sumSquares);
        m->frames = 0;
        m->channels = channels;
    }
    for (UInt32 c = 0; c < channels; c++) {
        if (peak[c] > m->peak[c]) m->peak[c] = peak[c];
        m->sumSquares[c] += sum[c];
    }
    m->frames += frames;
    m->renders++;
    os_unfair_lock_unlock(&m->levelLock);
}

static OSStatus Render(void *self, AudioUnitRenderActionFlags *ioFlags, const AudioTimeStamp *timeStamp, UInt32 bus,
                       UInt32 frames, AudioBufferList *ioData) {
    FOHMeter *m = self;
    if (!m->initialized) return kAudioUnitErr_Uninitialized;
    if (bus != 0) return kAudioUnitErr_InvalidElement;
    if (frames > m->maxFrames) return kAudioUnitErr_TooManyFramesToProcess;
    UInt32 channels = m->outFormat.mChannelsPerFrame;
    if (!ioData || !timeStamp || ioData->mNumberBuffers != channels) return kAudio_ParamError;

    AudioUnitRenderActionFlags flags = ioFlags ? *ioFlags : 0;
    int notifies = m->notifyCount;
    for (int i = 0; i < notifies; i++) {
        AudioUnitRenderActionFlags f = flags | kAudioUnitRenderAction_PreRender;
        m->notifies[i].proc(m->notifies[i].refCon, &f, timeStamp, bus, frames, ioData);
    }

    AudioBufferList *pull = m->pull;
    pull->mNumberBuffers = channels;
    for (UInt32 c = 0; c < channels; c++) {
        pull->mBuffers[c] = (AudioBuffer){ 1, frames * 4, m->storage + (size_t)c * m->maxFrames };
    }
    AudioUnitRenderActionFlags pullFlags = 0;
    OSStatus err;
    if (m->inputCallback.inputProc) {
        err = m->inputCallback.inputProc(m->inputCallback.inputProcRefCon, &pullFlags, timeStamp, 0, frames, pull);
    } else if (m->hasConnection) {
        err = AudioUnitRender(m->connection.sourceAudioUnit, &pullFlags, timeStamp, m->connection.sourceOutputNumber,
                              frames, pull);
    } else {
        err = kAudioUnitErr_NoConnection;
    }

    if (err == noErr) {
        for (UInt32 c = 0; c < channels; c++) {
            void *src = pull->mBuffers[c].mData;
            AudioBuffer *dst = &ioData->mBuffers[c];
            if (!dst->mData) dst->mData = src;                       // the host lets us supply the buffer
            else if (dst->mData != src) memcpy(dst->mData, src, frames * 4);
            dst->mDataByteSize = frames * 4;
            dst->mNumberChannels = 1;
        }
        if (pullFlags & kAudioUnitRenderAction_OutputIsSilence) flags |= kAudioUnitRenderAction_OutputIsSilence;
        else flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        if (!m->bypass) Measure(m, ioData, channels, frames);
    }

    for (int i = 0; i < notifies; i++) {
        AudioUnitRenderActionFlags f = flags | kAudioUnitRenderAction_PostRender;
        if (err) f |= kAudioUnitRenderAction_PostRenderError;
        m->notifies[i].proc(m->notifies[i].refCon, &f, timeStamp, bus, frames, ioData);
    }
    if (ioFlags) *ioFlags = flags;
    return err;
}

static OSStatus Reset(void *self, AudioUnitScope scope, AudioUnitElement element) {
    return noErr;   // no state beyond the level window, which the sender clears
}

// MARK: Plug-in interface

static AudioComponentMethod Lookup(SInt16 selector) {
    switch (selector) {
    case kAudioUnitInitializeSelect: return (AudioComponentMethod)Initialize;
    case kAudioUnitUninitializeSelect: return (AudioComponentMethod)Uninitialize;
    case kAudioUnitGetPropertyInfoSelect: return (AudioComponentMethod)GetPropertyInfo;
    case kAudioUnitGetPropertySelect: return (AudioComponentMethod)GetProperty;
    case kAudioUnitSetPropertySelect: return (AudioComponentMethod)SetProperty;
    case kAudioUnitAddPropertyListenerSelect: return (AudioComponentMethod)AddPropertyListener;
    case kAudioUnitRemovePropertyListenerSelect: return (AudioComponentMethod)RemovePropertyListener;
    case kAudioUnitRemovePropertyListenerWithUserDataSelect: return (AudioComponentMethod)RemovePropertyListenerWithUserData;
    case kAudioUnitAddRenderNotifySelect: return (AudioComponentMethod)AddRenderNotify;
    case kAudioUnitRemoveRenderNotifySelect: return (AudioComponentMethod)RemoveRenderNotify;
    case kAudioUnitGetParameterSelect: return (AudioComponentMethod)GetParameter;
    case kAudioUnitSetParameterSelect: return (AudioComponentMethod)SetParameter;
    case kAudioUnitScheduleParametersSelect: return (AudioComponentMethod)ScheduleParameters;
    case kAudioUnitRenderSelect: return (AudioComponentMethod)Render;
    case kAudioUnitResetSelect: return (AudioComponentMethod)Reset;
    default: return NULL;
    }
}

__attribute__((visibility("default")))
void *FOHMeterFactory(const AudioComponentDescription *description) {
    FOHMeter *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->plugIn = (AudioComponentPlugInInterface){ Open, Close, Lookup, NULL };
    m->inFormat = m->outFormat = CanonicalFormat(44100, 2);
    m->maxFrames = kDefaultMaxFrames;
    m->shouldAllocate[0] = m->shouldAllocate[1] = 1;
    m->preset = (AUPreset){ -1, NULL };
    m->listenerLock = m->levelLock = m->nameLock = OS_UNFAIR_LOCK_INIT;
    m->instanceID = arc4random();
    return m;
}
