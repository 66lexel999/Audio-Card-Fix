// MockAsio.cpp - a FAKE "Focusrite USB ASIO" driver, only for testing Focusrite-Doctor.ps1
// on a Windows PC (or the GitHub Actions Windows runner) that has no Focusrite.
// It is never given to users.
//
// It implements the IASIO interface from the published ASIO SDK layout (iasiodrv.h),
// so the doctor's live test talks to it exactly like it talks to the real driver.
//
// MOCKASIO_MODE (environment variable, read in init()) picks the behaviour:
//   ok       (default) opens, 2 inputs / 2 outputs, 48000 Hz, streams audio blocks
//   fail54f  init() fails; getErrorMessage() returns a text with "0x54f" in it
//   hang     init() never returns
//   crash    init() crashes the process (access violation)
//   noaudio  opens and starts, but never delivers an audio block
// MOCKASIO_LOG (optional) = path of a text file the driver appends what the host did to.
//
// Build from an "x64 Native Tools" prompt:  cl /nologo /LD /O2 /W3 MockAsio.cpp ole32.lib

#include <windows.h>
#include <objbase.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(linker, "/EXPORT:DllGetClassObject,PRIVATE")
#pragma comment(linker, "/EXPORT:DllCanUnloadNow,PRIVATE")
#pragma comment(linker, "/EXPORT:HoldOpen")

// {AEEBC837-F17A-4CDA-A5BA-B837D12DB50B}
static const CLSID CLSID_MockAsio =
    { 0xaeebc837, 0xf17a, 0x4cda, { 0xa5, 0xba, 0xb8, 0x37, 0xd1, 0x2d, 0xb5, 0x0b } };

// ---- ASIO types (same memory layout as the ASIO SDK) ----
typedef long ASIOBool;
typedef long ASIOError;
typedef double ASIOSampleRate;

enum {
    ASE_OK = 0, ASE_NotPresent = -1000, ASE_HWMalfunction = -999, ASE_InvalidParameter = -998,
    ASE_InvalidMode = -997, ASE_SPNotAdvancing = -996, ASE_NoClock = -995, ASE_NoMemory = -994
};

struct ASIOBufferInfo  { ASIOBool isInput; long channelNum; void *buffers[2]; };
struct ASIOChannelInfo { long channel; ASIOBool isInput; ASIOBool isActive; long channelGroup; long type; char name[32]; };
struct ASIOCallbacks
{
    void  (*bufferSwitch)(long doubleBufferIndex, ASIOBool directProcess);
    void  (*sampleRateDidChange)(ASIOSampleRate sRate);
    long  (*asioMessage)(long selector, long value, void *message, double *opt);
    void *(*bufferSwitchTimeInfo)(void *params, long doubleBufferIndex, ASIOBool directProcess);
};

// IASIO: IUnknown, then these methods in this order. On 32-bit Windows they are
// __thiscall (no STDMETHODCALLTYPE), exactly like the real SDK header.
struct IASIO : public IUnknown
{
    virtual ASIOBool  init(void *sysHandle) = 0;
    virtual void      getDriverName(char *name) = 0;
    virtual long      getDriverVersion() = 0;
    virtual void      getErrorMessage(char *string) = 0;
    virtual ASIOError start() = 0;
    virtual ASIOError stop() = 0;
    virtual ASIOError getChannels(long *numInputChannels, long *numOutputChannels) = 0;
    virtual ASIOError getLatencies(long *inputLatency, long *outputLatency) = 0;
    virtual ASIOError getBufferSize(long *minSize, long *maxSize, long *preferredSize, long *granularity) = 0;
    virtual ASIOError canSampleRate(ASIOSampleRate sampleRate) = 0;
    virtual ASIOError getSampleRate(ASIOSampleRate *sampleRate) = 0;
    virtual ASIOError setSampleRate(ASIOSampleRate sampleRate) = 0;
    virtual ASIOError getClockSources(void *clocks, long *numSources) = 0;
    virtual ASIOError setClockSource(long reference) = 0;
    virtual ASIOError getSamplePosition(void *sPos, void *tStamp) = 0;
    virtual ASIOError getChannelInfo(ASIOChannelInfo *info) = 0;
    virtual ASIOError createBuffers(ASIOBufferInfo *bufferInfos, long numChannels, long bufferSize, ASIOCallbacks *callbacks) = 0;
    virtual ASIOError disposeBuffers() = 0;
    virtual ASIOError controlPanel() = 0;
    virtual ASIOError future(long selector, void *opt) = 0;
    virtual ASIOError outputReady() = 0;
};

static const long kInputs = 2, kOutputs = 2;
static const long kMinBuffer = 64, kMaxBuffer = 1024, kPrefBuffer = 256;
static const long kInt32LSB = 18;
static const int  kMaxChannels = kInputs + kOutputs;

static LONG g_objects = 0;
static LONG g_locks = 0;

static void LogLine(const char *fmt, ...)
{
    char path[MAX_PATH];
    DWORD n = GetEnvironmentVariableA("MOCKASIO_LOG", path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    char line[512];
    va_list args;
    va_start(args, fmt);
    _vsnprintf_s(line, sizeof(line), _TRUNCATE, fmt, args);
    va_end(args);
    FILE *f = NULL;
    if (fopen_s(&f, path, "a") == 0 && f)
    {
        fprintf(f, "pid=%lu %s\n", GetCurrentProcessId(), line);
        fclose(f);
    }
}

class MockAsio : public IASIO
{
public:
    MockAsio() : refs(1), rate(48000.0), numInfos(0), bufferSize(0), thread(NULL), stopEvent(NULL),
                 badWrites(0), goodWrites(0)
    {
        InterlockedIncrement(&g_objects);
        mode[0] = 0;
        errorText[0] = 0;
        memset(&callbacks, 0, sizeof(callbacks));
        memset(infos, 0, sizeof(infos));
    }

    virtual ~MockAsio()
    {
        disposeBuffers();
        InterlockedDecrement(&g_objects);
    }

    // ---- IUnknown ----
    STDMETHODIMP QueryInterface(REFIID riid, void **ppv)
    {
        if (!ppv) return E_POINTER;
        // ASIO hosts ask for the driver's own CLSID as the interface id.
        if (IsEqualGUID(riid, IID_IUnknown) || IsEqualGUID(riid, CLSID_MockAsio))
        {
            *ppv = static_cast<IASIO *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = NULL;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() { return (ULONG)InterlockedIncrement(&refs); }
    STDMETHODIMP_(ULONG) Release()
    {
        LONG r = InterlockedDecrement(&refs);
        if (r == 0)
        {
            LogLine("release (last reference)");
            delete this;
        }
        return (ULONG)r;
    }

    // ---- IASIO ----
    ASIOBool init(void *sysHandle)
    {
        DWORD n = GetEnvironmentVariableA("MOCKASIO_MODE", mode, sizeof(mode));
        if (n == 0 || n >= sizeof(mode)) strcpy_s(mode, "ok");
        LogLine("init mode=%s sysHandle=%s", mode, sysHandle ? "set" : "null");
        if (_stricmp(mode, "hang") == 0) { Sleep(INFINITE); }
        if (_stricmp(mode, "crash") == 0) { *(volatile int *)0 = 1; }
        if (_stricmp(mode, "fail54f") == 0)
        {
            strcpy_s(errorText, "Cannot open the device. (Error code: 0x54f)");
            return 0;
        }
        return 1;
    }

    void getDriverName(char *name) { strcpy_s(name, 32, "Focusrite USB ASIO"); }
    long getDriverVersion() { return 4; }
    void getErrorMessage(char *string) { strcpy_s(string, 124, errorText); }

    ASIOError start()
    {
        if (numInfos == 0) return ASE_InvalidMode;
        if (thread) return ASE_OK;
        LogLine("start");
        if (_stricmp(mode, "noaudio") == 0) return ASE_OK;
        stopEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
        thread = CreateThread(NULL, 0, StreamThread, this, 0, NULL);
        return thread ? ASE_OK : ASE_HWMalfunction;
    }

    ASIOError stop()
    {
        if (thread)
        {
            SetEvent(stopEvent);
            WaitForSingleObject(thread, 5000);
            CloseHandle(thread);
            CloseHandle(stopEvent);
            thread = NULL;
            stopEvent = NULL;
            LogLine("stop blocks-with-silence-written=%ld blocks-not-written=%ld", goodWrites, badWrites);
        }
        return ASE_OK;
    }

    ASIOError getChannels(long *numIn, long *numOut)
    {
        if (!numIn || !numOut) return ASE_InvalidParameter;
        *numIn = kInputs;
        *numOut = kOutputs;
        return ASE_OK;
    }

    ASIOError getLatencies(long *inLat, long *outLat)
    {
        if (!inLat || !outLat) return ASE_InvalidParameter;
        *inLat = bufferSize + 32;
        *outLat = bufferSize + 64;
        return ASE_OK;
    }

    ASIOError getBufferSize(long *minSize, long *maxSize, long *preferredSize, long *granularity)
    {
        if (!minSize || !maxSize || !preferredSize || !granularity) return ASE_InvalidParameter;
        *minSize = kMinBuffer;
        *maxSize = kMaxBuffer;
        *preferredSize = kPrefBuffer;
        *granularity = -1;
        return ASE_OK;
    }

    ASIOError canSampleRate(ASIOSampleRate r)
    {
        // Checks the host passes the double correctly (a wrong calling convention gives garbage).
        if (r == 44100.0 || r == 48000.0 || r == 88200.0 || r == 96000.0) return ASE_OK;
        return ASE_NoClock;
    }

    ASIOError getSampleRate(ASIOSampleRate *r)
    {
        if (!r) return ASE_InvalidParameter;
        *r = rate;
        return ASE_OK;
    }

    ASIOError setSampleRate(ASIOSampleRate r)
    {
        if (canSampleRate(r) != ASE_OK) return ASE_NoClock;
        rate = r;
        return ASE_OK;
    }

    ASIOError getClockSources(void *clocks, long *numSources)
    {
        (void)clocks;
        if (numSources) *numSources = 0;
        return ASE_OK;
    }

    ASIOError setClockSource(long reference) { (void)reference; return ASE_OK; }

    ASIOError getSamplePosition(void *sPos, void *tStamp)
    {
        if (sPos) memset(sPos, 0, 8);
        if (tStamp) memset(tStamp, 0, 8);
        return ASE_OK;
    }

    ASIOError getChannelInfo(ASIOChannelInfo *info)
    {
        if (!info) return ASE_InvalidParameter;
        long count = info->isInput ? kInputs : kOutputs;
        if (info->channel < 0 || info->channel >= count) return ASE_InvalidParameter;
        info->isActive = 0;
        info->channelGroup = 0;
        info->type = kInt32LSB;
        sprintf_s(info->name, "%s %ld", info->isInput ? "Analogue" : "Output", info->channel + 1);
        LogLine("getChannelInfo channel=%ld isInput=%ld", info->channel, info->isInput);
        return ASE_OK;
    }

    ASIOError createBuffers(ASIOBufferInfo *bufferInfos, long numChannels, long size, ASIOCallbacks *cb)
    {
        if (numInfos) disposeBuffers();
        LogLine("createBuffers channels=%ld size=%ld", numChannels, size);
        if (!bufferInfos || !cb || !cb->bufferSwitch || !cb->asioMessage) return Fail("createBuffers: missing pointer");
        if (numChannels < 1 || numChannels > kMaxChannels) return Fail("createBuffers: bad channel count");
        if (size < kMinBuffer || size > kMaxBuffer) return Fail("createBuffers: bad buffer size");
        for (long i = 0; i < numChannels; i++)
        {
            ASIOBufferInfo &bi = bufferInfos[i];
            long count = bi.isInput ? kInputs : kOutputs;
            if ((bi.isInput != 0 && bi.isInput != 1) || bi.channelNum < 0 || bi.channelNum >= count)
                return Fail("createBuffers: bad ASIOBufferInfo (wrong struct layout?)");
        }
        // Check the host's asioMessage callback answers like the ASIO SDK says it should.
        long supported = cb->asioMessage(1, 2, NULL, NULL);   // kAsioSelectorSupported(kAsioEngineVersion)
        long engine = cb->asioMessage(2, 0, NULL, NULL);      // kAsioEngineVersion
        LogLine("asioMessage selectorSupported(engineVersion)=%ld engineVersion=%ld", supported, engine);
        if (supported != 1 || engine != 2) return Fail("createBuffers: asioMessage callback gave wrong answers");

        callbacks = *cb;
        bufferSize = size;
        for (long i = 0; i < numChannels; i++)
        {
            ASIOBufferInfo &bi = bufferInfos[i];
            for (int h = 0; h < 2; h++)
            {
                bi.buffers[h] = calloc((size_t)size, 4);
                if (!bi.buffers[h]) return ASE_NoMemory;
            }
            infos[i] = bi;
        }
        numInfos = numChannels;
        return ASE_OK;
    }

    ASIOError disposeBuffers()
    {
        stop();
        if (numInfos) LogLine("disposeBuffers");
        for (long i = 0; i < numInfos; i++)
        {
            free(infos[i].buffers[0]);
            free(infos[i].buffers[1]);
        }
        memset(infos, 0, sizeof(infos));
        numInfos = 0;
        return ASE_OK;
    }

    ASIOError controlPanel() { return ASE_NotPresent; }
    ASIOError future(long selector, void *opt) { (void)selector; (void)opt; return ASE_InvalidParameter; }
    ASIOError outputReady() { return ASE_NotPresent; }

private:
    ASIOError Fail(const char *why)
    {
        strcpy_s(errorText, why);
        LogLine("%s", why);
        return ASE_InvalidParameter;
    }

    // The "audio clock": calls the host once per buffer, like a real driver does.
    static DWORD WINAPI StreamThread(LPVOID param)
    {
        MockAsio *self = (MockAsio *)param;
        DWORD periodMs = (DWORD)(1000.0 * self->bufferSize / self->rate);
        if (periodMs < 1) periodMs = 1;
        long index = 0;
        while (WaitForSingleObject(self->stopEvent, periodMs) == WAIT_TIMEOUT)
        {
            // Fill the output half with junk; the host must overwrite it with its audio (silence).
            for (long i = 0; i < self->numInfos; i++)
                if (!self->infos[i].isInput) memset(self->infos[i].buffers[index], 0x55, (size_t)self->bufferSize * 4);
            self->callbacks.bufferSwitch(index, 0);
            bool written = true;
            for (long i = 0; i < self->numInfos && written; i++)
            {
                if (self->infos[i].isInput) continue;
                const unsigned char *p = (const unsigned char *)self->infos[i].buffers[index];
                for (long b = 0; b < self->bufferSize * 4; b++) { if (p[b] != 0) { written = false; break; } }
            }
            if (written) self->goodWrites++; else self->badWrites++;
            index = 1 - index;
        }
        return 0;
    }

    LONG refs;
    char mode[32];
    char errorText[124];
    double rate;
    ASIOCallbacks callbacks;
    ASIOBufferInfo infos[kMaxChannels];
    long numInfos;
    long bufferSize;
    HANDLE thread;
    HANDLE stopEvent;
    long badWrites;
    long goodWrites;
};

class Factory : public IClassFactory
{
public:
    STDMETHODIMP QueryInterface(REFIID riid, void **ppv)
    {
        if (!ppv) return E_POINTER;
        if (IsEqualGUID(riid, IID_IUnknown) || IsEqualGUID(riid, IID_IClassFactory))
        {
            *ppv = static_cast<IClassFactory *>(this);
            return S_OK;
        }
        *ppv = NULL;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() { return 2; }
    STDMETHODIMP_(ULONG) Release() { return 1; }
    STDMETHODIMP CreateInstance(IUnknown *outer, REFIID riid, void **ppv)
    {
        if (!ppv) return E_POINTER;
        *ppv = NULL;
        if (outer) return CLASS_E_NOAGGREGATION;
        MockAsio *m = new MockAsio();
        HRESULT hr = m->QueryInterface(riid, ppv);
        m->Release();
        LogLine("CreateInstance hr=0x%08lX", (unsigned long)hr);
        return hr;
    }
    STDMETHODIMP LockServer(BOOL lock)
    {
        if (lock) InterlockedIncrement(&g_locks); else InterlockedDecrement(&g_locks);
        return S_OK;
    }
};

static Factory g_factory;

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID *ppv)
{
    if (!ppv) return E_POINTER;
    *ppv = NULL;
    if (!IsEqualCLSID(rclsid, CLSID_MockAsio)) return CLASS_E_CLASSNOTAVAILABLE;
    return g_factory.QueryInterface(riid, ppv);
}

STDAPI DllCanUnloadNow(void)
{
    return (g_objects == 0 && g_locks == 0) ? S_OK : S_FALSE;
}

// rundll32.exe MockAsio.dll,HoldOpen  - keeps the driver DLL loaded in a process for 10 minutes,
// so the test can check the doctor notices "another program has the ASIO driver open".
extern "C" void CALLBACK HoldOpen(HWND hwnd, HINSTANCE inst, LPSTR cmdLine, int show)
{
    (void)hwnd; (void)inst; (void)cmdLine; (void)show;
    Sleep(10 * 60 * 1000);
}
