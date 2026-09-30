/*
    wave.cpp — WaveRT miniport + capture stream. See common.h.

    Polling WaveRT: the audio engine asks for the position every period, and the
    stream fills the cyclic buffer up to "now" from the ring. Time is counted in
    samples since RUN (QPC based), so rounding never adds up and every write is a
    whole number of samples.
*/
#include "common.h"

// ---- descriptors -----------------------------------------------------------------

static KSDATARANGE_AUDIO CaptureRange = {
    {
        sizeof(KSDATARANGE_AUDIO), 0, 0, 0,
        STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
        STATICGUIDOF(KSDATAFORMAT_SUBTYPE_PCM),
        STATICGUIDOF(KSDATAFORMAT_SPECIFIER_WAVEFORMATEX)
    },
    MIC_CHANNELS,   // MaximumChannels
    MIC_BITS,       // MinimumBitsPerSample
    MIC_BITS,       // MaximumBitsPerSample
    MIC_RATE,       // MinimumSampleFrequency
    MIC_RATE        // MaximumSampleFrequency
};
static PKSDATARANGE CaptureRanges[] = { PKSDATARANGE(&CaptureRange) };

static KSDATARANGE BridgeRange = {
    sizeof(KSDATARANGE), 0, 0, 0,
    STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
    STATICGUIDOF(KSDATAFORMAT_SUBTYPE_ANALOG),
    STATICGUIDOF(KSDATAFORMAT_SPECIFIER_NONE)
};
static PKSDATARANGE BridgeRanges[] = { &BridgeRange };

static PCPIN_DESCRIPTOR WavePins[] = {
    // WAVE_PIN_BRIDGE: from the topology filter.
    { 0, 0, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(BridgeRanges), BridgeRanges,
        KSPIN_DATAFLOW_IN, KSPIN_COMMUNICATION_NONE, &KSCATEGORY_AUDIO, NULL, 0 } },
    // WAVE_PIN_CAPTURE: the stream apps record from. One at a time; the audio
    // engine shares it between apps.
    { 1, 1, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(CaptureRanges), CaptureRanges,
        KSPIN_DATAFLOW_OUT, KSPIN_COMMUNICATION_SINK, &KSCATEGORY_AUDIO, &KSAUDFNAME_RECORDING_CONTROL, 0 } },
};

static PCNODE_DESCRIPTOR WaveNodes[] = {
    { 0, NULL, &KSNODETYPE_ADC, NULL },
};

static PCCONNECTION_DESCRIPTOR WaveConnections[] = {
    { PCFILTER_NODE, WAVE_PIN_BRIDGE, 0, 1 },
    { 0, 0, PCFILTER_NODE, WAVE_PIN_CAPTURE },
};

static PCFILTER_DESCRIPTOR WaveFilter = {
    0, NULL,
    sizeof(PCPIN_DESCRIPTOR), SIZEOF_ARRAY(WavePins), WavePins,
    sizeof(PCNODE_DESCRIPTOR), SIZEOF_ARRAY(WaveNodes), WaveNodes,
    SIZEOF_ARRAY(WaveConnections), WaveConnections,
    0, NULL
};

// The one format we produce, as the intersection result.
static KSDATAFORMAT_WAVEFORMATEXTENSIBLE OurFormat = {
    {
        sizeof(KSDATAFORMAT_WAVEFORMATEXTENSIBLE), 0, 0, 0,
        STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
        STATICGUIDOF(KSDATAFORMAT_SUBTYPE_PCM),
        STATICGUIDOF(KSDATAFORMAT_SPECIFIER_WAVEFORMATEX)
    },
    {
        { WAVE_FORMAT_EXTENSIBLE, MIC_CHANNELS, MIC_RATE, MIC_RATE * MIC_BLOCK, MIC_BLOCK, MIC_BITS,
          sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX) },
        { MIC_BITS },
        KSAUDIO_SPEAKER_MONO,
        STATICGUIDOF(KSDATAFORMAT_SUBTYPE_PCM)
    }
};

static BOOLEAN IsOurFormat(_In_ PKSDATAFORMAT Format)
{
    if (!IsEqualGUIDAligned(Format->MajorFormat, KSDATAFORMAT_TYPE_AUDIO) ||
        !IsEqualGUIDAligned(Format->Specifier, KSDATAFORMAT_SPECIFIER_WAVEFORMATEX) ||
        Format->FormatSize < sizeof(KSDATAFORMAT_WAVEFORMATEX)) {
        return FALSE;
    }
    PWAVEFORMATEX wfx = (PWAVEFORMATEX)(Format + 1);
    if (wfx->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        if (Format->FormatSize < sizeof(KSDATAFORMAT_WAVEFORMATEXTENSIBLE) ||
            !IsEqualGUIDAligned(((PWAVEFORMATEXTENSIBLE)wfx)->SubFormat, KSDATAFORMAT_SUBTYPE_PCM)) {
            return FALSE;
        }
    } else if (wfx->wFormatTag != WAVE_FORMAT_PCM) {
        return FALSE;
    }
    return wfx->nChannels == MIC_CHANNELS && wfx->nSamplesPerSec == MIC_RATE &&
           wfx->wBitsPerSample == MIC_BITS && wfx->nBlockAlign == MIC_BLOCK;
}

// ---- capture stream ----------------------------------------------------------------

class CCaptureStream : public IMiniportWaveRTStream, public CUnknown
{
public:
    DECLARE_STD_UNKNOWN();
    CCaptureStream(PUNKNOWN Outer) : CUnknown(Outer) {}
    ~CCaptureStream() {}
    IMP_IMiniportWaveRTStream;

    NTSTATUS Init(_In_ PPORTWAVERTSTREAM Port)
    {
        m_Port = Port;
        m_State = KSSTATE_STOP;
        KeInitializeSpinLock(&m_Lock);
        return STATUS_SUCCESS;
    }

private:
    VOID Advance(_In_ LONGLONG Qpc);

    PPORTWAVERTSTREAM m_Port;
    PUCHAR            m_Buffer;
    ULONG             m_BufferSize;   // bytes, a whole number of samples
    ULONG             m_Pos;          // next byte the "hardware" writes
    KSSTATE           m_State;
    KSPIN_LOCK        m_Lock;
    LONGLONG          m_QpcFreq;
    LONGLONG          m_RunQpc;       // QPC when the current RUN began
    ULONGLONG         m_RunSamples;   // samples produced before the current RUN
    ULONGLONG         m_Samples;      // samples produced so far
};

STDMETHODIMP_(NTSTATUS) CCaptureStream::NonDelegatingQueryInterface(_In_ REFIID Iid, _COM_Outptr_ PVOID* Object)
{
    if (IsEqualGUIDAligned(Iid, IID_IUnknown)) {
        *Object = PVOID(PUNKNOWN(PMINIPORTWAVERTSTREAM(this)));
    } else if (IsEqualGUIDAligned(Iid, IID_IMiniportWaveRTStream)) {
        *Object = PVOID(PMINIPORTWAVERTSTREAM(this));
    } else {
        *Object = NULL;
        return STATUS_INVALID_PARAMETER;
    }
    PUNKNOWN(*Object)->AddRef();
    return STATUS_SUCCESS;
}

// Produce the samples due by Qpc into the cyclic buffer. Called with m_Lock held.
VOID CCaptureStream::Advance(_In_ LONGLONG Qpc)
{
    if (!m_Buffer || !m_BufferSize || m_QpcFreq <= 0 || Qpc <= m_RunQpc) {
        return;
    }
    ULONGLONG ticks = (ULONGLONG)(Qpc - m_RunQpc);
    ULONGLONG due = m_RunSamples + (ticks / m_QpcFreq) * MIC_RATE + (ticks % m_QpcFreq) * MIC_RATE / m_QpcFreq;
    if (due <= m_Samples) {
        return;
    }
    ULONGLONG bytes = (due - m_Samples) * MIC_BLOCK;
    m_Samples = due;

    // Position always moves by the full amount so it stays in step with time; if
    // nobody polled for longer than the buffer (it shouldn't happen) only the last
    // buffer's worth is actually filled.
    ULONG fill = bytes > m_BufferSize ? m_BufferSize : (ULONG)bytes;
    ULONG newPos = (ULONG)((m_Pos + bytes) % m_BufferSize);
    ULONG at = (newPos + m_BufferSize - fill) % m_BufferSize;
    while (fill) {
        ULONG run = min(fill, m_BufferSize - at);
        MicRingRead(m_Buffer + at, run);
        at = (at + run) % m_BufferSize;
        fill -= run;
    }
    m_Pos = newPos;
}

STDMETHODIMP_(NTSTATUS) CCaptureStream::SetState(_In_ KSSTATE State)
{
    KIRQL irql;
    LARGE_INTEGER freq;
    LONGLONG now = KeQueryPerformanceCounter(&freq).QuadPart;

    KeAcquireSpinLock(&m_Lock, &irql);
    switch (State) {
    case KSSTATE_STOP:
        m_Pos = 0;
        m_Samples = m_RunSamples = 0;
        break;
    case KSSTATE_PAUSE:
        if (m_State == KSSTATE_RUN) {
            Advance(now);
            m_RunSamples = m_Samples;
        }
        break;
    case KSSTATE_RUN:
        m_QpcFreq = freq.QuadPart;
        m_RunQpc = now;
        m_RunSamples = m_Samples;
        MicRingFlush();
        break;
    default:
        break;
    }
    m_State = State;
    KeReleaseSpinLock(&m_Lock, irql);
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CCaptureStream::GetPosition(_Out_ PKSAUDIO_POSITION Position)
{
    KIRQL irql;
    KeAcquireSpinLock(&m_Lock, &irql);
    if (m_State == KSSTATE_RUN) {
        Advance(KeQueryPerformanceCounter(NULL).QuadPart);
    }
    Position->PlayOffset = m_Pos;
    Position->WriteOffset = m_Pos;
    KeReleaseSpinLock(&m_Lock, irql);
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CCaptureStream::AllocateAudioBuffer(_In_ ULONG RequestedSize, _Out_ PMDL* Mdl,
                                                           _Out_ ULONG* ActualSize, _Out_ ULONG* Offset,
                                                           _Out_ MEMORY_CACHING_TYPE* CacheType)
{
    RequestedSize -= RequestedSize % MIC_BLOCK;
    if (RequestedSize == 0) {
        return STATUS_UNSUCCESSFUL;
    }
    PHYSICAL_ADDRESS high;
    high.QuadPart = MAXULONG;
    PMDL mdl = m_Port->AllocatePagesForMdl(high, RequestedSize);
    if (!mdl) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    PUCHAR buffer = (PUCHAR)m_Port->MapAllocatedPages(mdl, MmCached);
    if (!buffer) {
        m_Port->FreePagesFromMdl(mdl);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    RtlZeroMemory(buffer, RequestedSize);

    KIRQL irql;
    KeAcquireSpinLock(&m_Lock, &irql);
    m_Buffer = buffer;
    m_BufferSize = RequestedSize;
    m_Pos = 0;
    KeReleaseSpinLock(&m_Lock, irql);

    *Mdl = mdl;
    *ActualSize = RequestedSize;
    *Offset = 0;
    *CacheType = MmCached;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(VOID) CCaptureStream::FreeAudioBuffer(_In_opt_ PMDL Mdl, _In_ ULONG)
{
    KIRQL irql;
    KeAcquireSpinLock(&m_Lock, &irql);
    PUCHAR buffer = m_Buffer;
    m_Buffer = NULL;
    m_BufferSize = 0;
    KeReleaseSpinLock(&m_Lock, irql);

    if (Mdl) {
        if (buffer) {
            m_Port->UnmapAllocatedPages(buffer, Mdl);
        }
        m_Port->FreePagesFromMdl(Mdl);
    }
}

STDMETHODIMP_(NTSTATUS) CCaptureStream::SetFormat(_In_ PKSDATAFORMAT)
{
    return STATUS_NOT_SUPPORTED;  // one fixed format
}

STDMETHODIMP_(VOID) CCaptureStream::GetHWLatency(_Out_ KSRTAUDIO_HWLATENCY* Latency)
{
    Latency->ChipsetDelay = 0;
    Latency->CodecDelay = 0;
    Latency->FifoSize = 0;
}

STDMETHODIMP_(NTSTATUS) CCaptureStream::GetPositionRegister(_Out_ KSRTAUDIO_HWREGISTER*)
{
    return STATUS_NOT_IMPLEMENTED;
}

STDMETHODIMP_(NTSTATUS) CCaptureStream::GetClockRegister(_Out_ KSRTAUDIO_HWREGISTER*)
{
    return STATUS_NOT_IMPLEMENTED;
}

// ---- miniport ------------------------------------------------------------------------

class CWaveMiniport : public IMiniportWaveRT, public CUnknown
{
public:
    DECLARE_STD_UNKNOWN();
    CWaveMiniport(PUNKNOWN Outer) : CUnknown(Outer) {}
    ~CWaveMiniport() {}
    IMP_IMiniportWaveRT;
};

STDMETHODIMP_(NTSTATUS) CWaveMiniport::NonDelegatingQueryInterface(_In_ REFIID Iid, _COM_Outptr_ PVOID* Object)
{
    if (IsEqualGUIDAligned(Iid, IID_IUnknown)) {
        *Object = PVOID(PUNKNOWN(PMINIPORTWAVERT(this)));
    } else if (IsEqualGUIDAligned(Iid, IID_IMiniport)) {
        *Object = PVOID(PMINIPORT(this));
    } else if (IsEqualGUIDAligned(Iid, IID_IMiniportWaveRT)) {
        *Object = PVOID(PMINIPORTWAVERT(this));
    } else {
        *Object = NULL;
        return STATUS_INVALID_PARAMETER;
    }
    PUNKNOWN(*Object)->AddRef();
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CWaveMiniport::Init(_In_ PUNKNOWN, _In_ PRESOURCELIST, _In_ PPORTWAVERT)
{
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CWaveMiniport::GetDescription(_Out_ PPCFILTER_DESCRIPTOR* Description)
{
    *Description = &WaveFilter;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CWaveMiniport::DataRangeIntersection(
    _In_ ULONG PinId, _In_ PKSDATARANGE ClientRange, _In_ PKSDATARANGE,
    _In_ ULONG OutputBufferLength,
    _Out_writes_bytes_to_opt_(OutputBufferLength, *ResultantFormatLength) PVOID ResultantFormat,
    _Out_ PULONG ResultantFormatLength)
{
    if (PinId != WAVE_PIN_CAPTURE ||
        !IsEqualGUIDAligned(ClientRange->Specifier, KSDATAFORMAT_SPECIFIER_WAVEFORMATEX)) {
        return STATUS_NOT_IMPLEMENTED;  // let PortCls handle it
    }
    if (ClientRange->FormatSize >= sizeof(KSDATARANGE_AUDIO)) {
        PKSDATARANGE_AUDIO a = (PKSDATARANGE_AUDIO)ClientRange;
        if (a->MaximumChannels < MIC_CHANNELS ||
            a->MinimumBitsPerSample > MIC_BITS || a->MaximumBitsPerSample < MIC_BITS ||
            a->MinimumSampleFrequency > MIC_RATE || a->MaximumSampleFrequency < MIC_RATE) {
            return STATUS_NO_MATCH;
        }
    }
    if (!OutputBufferLength) {
        *ResultantFormatLength = sizeof(OurFormat);
        return STATUS_BUFFER_OVERFLOW;
    }
    if (OutputBufferLength < sizeof(OurFormat)) {
        return STATUS_BUFFER_TOO_SMALL;
    }
    RtlCopyMemory(ResultantFormat, &OurFormat, sizeof(OurFormat));
    *ResultantFormatLength = sizeof(OurFormat);
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CWaveMiniport::NewStream(_Out_ PMINIPORTWAVERTSTREAM* Stream, _In_ PPORTWAVERTSTREAM PortStream,
                                                 _In_ ULONG Pin, _In_ BOOLEAN Capture, _In_ PKSDATAFORMAT DataFormat)
{
    *Stream = NULL;
    if (Pin != WAVE_PIN_CAPTURE || !Capture || !IsOurFormat(DataFormat)) {
        return STATUS_INVALID_PARAMETER;
    }
    CCaptureStream* stream = new (POOL_FLAG_NON_PAGED, NTPODS_POOLTAG) CCaptureStream(NULL);
    if (!stream) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    stream->AddRef();
    NTSTATUS status = stream->Init(PortStream);
    if (NT_SUCCESS(status)) {
        *Stream = PMINIPORTWAVERTSTREAM(stream);
        (*Stream)->AddRef();
    }
    stream->Release();
    return status;
}

STDMETHODIMP_(NTSTATUS) CWaveMiniport::GetDeviceDescription(_Out_ PDEVICE_DESCRIPTION Description)
{
    RtlZeroMemory(Description, sizeof(DEVICE_DESCRIPTION));
    Description->Master = TRUE;
    Description->ScatterGather = TRUE;
    Description->Dma32BitAddresses = TRUE;
    Description->InterfaceType = PCIBus;
    Description->MaximumLength = 0xFFFFFFFF;
    return STATUS_SUCCESS;
}

NTSTATUS CreateWaveMiniport(_Out_ PUNKNOWN* Unknown)
{
    CWaveMiniport* m = new (POOL_FLAG_NON_PAGED, NTPODS_POOLTAG) CWaveMiniport(NULL);
    if (!m) {
        *Unknown = NULL;
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    *Unknown = PUNKNOWN(PMINIPORTWAVERT(m));
    (*Unknown)->AddRef();
    return STATUS_SUCCESS;
}
