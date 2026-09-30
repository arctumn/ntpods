/*
    topo.cpp — topology miniport. See common.h.

    Just a microphone pin bridged straight to the wave filter: no volume or mute
    nodes, so Windows uses its own software volume for the endpoint.
*/
#include "common.h"

static KSDATARANGE BridgeRange = {
    sizeof(KSDATARANGE), 0, 0, 0,
    STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
    STATICGUIDOF(KSDATAFORMAT_SUBTYPE_ANALOG),
    STATICGUIDOF(KSDATAFORMAT_SPECIFIER_NONE)
};
static PKSDATARANGE BridgeRanges[] = { &BridgeRange };

static PCPIN_DESCRIPTOR TopoPins[] = {
    // TOPO_PIN_MIC: what Windows shows as the device (a microphone).
    { 0, 0, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(BridgeRanges), BridgeRanges,
        KSPIN_DATAFLOW_IN, KSPIN_COMMUNICATION_NONE, &KSNODETYPE_MICROPHONE, NULL, 0 } },
    // TOPO_PIN_BRIDGE: to the wave filter.
    { 0, 0, 0, NULL,
      { 0, NULL, 0, NULL, SIZEOF_ARRAY(BridgeRanges), BridgeRanges,
        KSPIN_DATAFLOW_OUT, KSPIN_COMMUNICATION_NONE, &KSCATEGORY_AUDIO, NULL, 0 } },
};

static PCCONNECTION_DESCRIPTOR TopoConnections[] = {
    { PCFILTER_NODE, TOPO_PIN_MIC, PCFILTER_NODE, TOPO_PIN_BRIDGE },
};

static PCFILTER_DESCRIPTOR TopoFilter = {
    0, NULL,
    sizeof(PCPIN_DESCRIPTOR), SIZEOF_ARRAY(TopoPins), TopoPins,
    sizeof(PCNODE_DESCRIPTOR), 0, NULL,
    SIZEOF_ARRAY(TopoConnections), TopoConnections,
    0, NULL
};

class CTopoMiniport : public IMiniportTopology, public CUnknown
{
public:
    DECLARE_STD_UNKNOWN();
    CTopoMiniport(PUNKNOWN Outer) : CUnknown(Outer) {}
    ~CTopoMiniport() {}
    IMP_IMiniportTopology;
};

STDMETHODIMP_(NTSTATUS) CTopoMiniport::NonDelegatingQueryInterface(_In_ REFIID Iid, _COM_Outptr_ PVOID* Object)
{
    if (IsEqualGUIDAligned(Iid, IID_IUnknown)) {
        *Object = PVOID(PUNKNOWN(PMINIPORTTOPOLOGY(this)));
    } else if (IsEqualGUIDAligned(Iid, IID_IMiniport)) {
        *Object = PVOID(PMINIPORT(this));
    } else if (IsEqualGUIDAligned(Iid, IID_IMiniportTopology)) {
        *Object = PVOID(PMINIPORTTOPOLOGY(this));
    } else {
        *Object = NULL;
        return STATUS_INVALID_PARAMETER;
    }
    PUNKNOWN(*Object)->AddRef();
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CTopoMiniport::Init(_In_ PUNKNOWN, _In_ PRESOURCELIST, _In_ PPORTTOPOLOGY)
{
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CTopoMiniport::GetDescription(_Out_ PPCFILTER_DESCRIPTOR* Description)
{
    *Description = &TopoFilter;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CTopoMiniport::DataRangeIntersection(
    _In_ ULONG, _In_ PKSDATARANGE, _In_ PKSDATARANGE, _In_ ULONG OutputBufferLength,
    _Out_writes_bytes_to_opt_(OutputBufferLength, *ResultantFormatLength) PVOID,
    _Out_ PULONG ResultantFormatLength)
{
    UNREFERENCED_PARAMETER(OutputBufferLength);
    *ResultantFormatLength = 0;
    return STATUS_NOT_IMPLEMENTED;  // bridge pins only; PortCls handles them
}

NTSTATUS CreateTopoMiniport(_Out_ PUNKNOWN* Unknown)
{
    CTopoMiniport* m = new (POOL_FLAG_NON_PAGED, NTPODS_POOLTAG) CTopoMiniport(NULL);
    if (!m) {
        *Unknown = NULL;
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    *Unknown = PUNKNOWN(PMINIPORTTOPOLOGY(m));
    (*Unknown)->AddRef();
    return STATUS_SUCCESS;
}
