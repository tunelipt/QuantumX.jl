// CxxWrap bindings for the HBM QuantumX low-level API (HBM_QX_Framework.dll, 32 bit).
//
// Conventions of this raw layer (Julia module QuantumX.LibQX):
//   * Functions keep their C names (HBM_XPAR_ReadXML, ...) and argument order.
//   * `const char*` inputs are Julia Strings.
//   * Scalar output pointers are removed from the argument list and returned in a
//     tuple after the C return code:   rc, out1, out2, ... = HBM_Xxx(inputs...)
//   * Text output buffers (char* pData, UINT32* pDatLen, UINT32 MaxSize) keep the
//     MaxSize argument (buffer allocated here) and return a String.
//   * Binary buffers are caller-owned Julia arrays (Vector{UInt8}, Vector{Float64},
//     Vector{Int32}); their length is used as MaxSize.
//   * Structs are mapped 1:1 onto Julia isbits mirror types (see src/types.jl).
//   * No function throws on a negative return code; checking is done in Julia.

#include "jlcxx/jlcxx.hpp"
#include "jlcxx/tuple.hpp"
#include "jlcxx/array.hpp"

#include <cstddef>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <tuple>
#include <type_traits>
#include <vector>

#include "HBM_QX_Framework.h"

// stModStatItem has a user-defined default constructor in the SDK header
// (`stModStatItem() : Id(0) {}`), which makes it non-trivial. jlcxx then treats it as
// a wrapped C++ object (boxed pointer) instead of an isbits mirror and aborts with
// "jl_datatype_nfields(dt) == 1" when boxing. It is plain data otherwise, so force
// the mirrored mapping.
template <> struct jlcxx::IsMirroredType<stModStatItem> : std::true_type {};

namespace
{

using DeviceInfo = std::remove_reference_t<decltype(std::declval<stDeviceList>().Device[0])>;

// Every struct mapped with map_type must be treated as an isbits mirror by jlcxx.
template <typename... T> constexpr bool all_mirrored = (jlcxx::IsMirroredType<T>::value && ...);
static_assert(all_mirrored<stSensor, stCanSigDesc, stSignalParams, stCanSignalParams,
                           stAlarmIndexParams, stAlarmGlobalParams, stPeakIndexParams,
                           stGateIndexParams, stTrigInfo, stDaqHeader, stErrStatItem,
                           stModStatItem, stConModulInfo, DeviceInfo>,
              "a mapped struct is not mirrored by jlcxx (non-trivial C++ type?)");
static_assert(std::is_trivially_copyable_v<stModStatItem>, "stModStatItem must be memcpy-able");

// ---------------------------------------------------------------- helpers

// Convert a filled char buffer to std::string. `len` is what the DLL reported; it may
// or may not include the terminating NUL, and may exceed the buffer when truncated.
std::string to_string(const std::vector<char>& buf, UINT32 len)
{
  size_t n = std::min<size_t>(len, buf.size() > 0 ? buf.size() - 1 : 0);
  if (n == 0)
    n = strnlen(buf.data(), buf.size());
  while (n > 0 && buf[n - 1] == '\0')
    --n;
  return std::string(buf.data(), n);
}

std::string cstr_or_empty(const char* p) { return p ? std::string(p) : std::string(); }

// Fixed-size char array from std::string (always NUL terminated, truncating)
template <size_t N> void copy_str(char (&dst)[N], const std::string& s)
{
  std::memset(dst, 0, N);
  std::strncpy(dst, s.c_str(), N - 1);
}

// Text output: f(char* buf, UINT32* len, UINT32 maxsize) -> int
template <typename F> std::tuple<int, std::string> read_text(UINT32 maxsize, F&& f)
{
  std::vector<char> buf(size_t(maxsize) + 1, '\0');
  UINT32 len = 0;
  int rc = f(buf.data(), &len, maxsize);
  return std::make_tuple(rc, to_string(buf, len));
}

// Xpath composer helpers: f(char* buf, UINT32 maxlen, UINT32* reallen) -> void
template <typename F> std::string compose_path(UINT32 maxlen, F&& f)
{
  std::vector<char> buf(size_t(maxlen) + 1, '\0');
  UINT32 len = 0;
  f(buf.data(), maxlen, &len);
  return to_string(buf, len);
}

// XML composer helpers: f(char* buf, UINT32 maxlen, UINT32* reallen) -> INT32
template <typename F> std::tuple<int, std::string> compose_xml(UINT32 maxlen, F&& f)
{
  std::vector<char> buf(size_t(maxlen) + 1, '\0');
  UINT32 len = 0;
  int rc = f(buf.data(), maxlen, &len);
  return std::make_tuple(rc, to_string(buf, len));
}

// Build a GC-rooted Julia Vector{T} of mapped isbits structs
template <typename T, typename Src>
jlcxx::Array<T> make_array(const Src* items, size_t count)
{
  jlcxx::Array<T> arr;
  JL_GC_PUSH1(arr.gc_pointer());
  for (size_t i = 0; i < count; ++i)
    arr.push_back(items[i]);
  JL_GC_POP();
  return arr;
}

// Julia Vector{Any} of Strings
jlcxx::Array<jl_value_t*> make_string_array(const std::vector<std::string>& v)
{
  jlcxx::Array<jl_value_t*> arr;
  jl_value_t* s = nullptr;
  JL_GC_PUSH2(arr.gc_pointer(), &s);
  for (const auto& x : v)
  {
    s = jl_cstr_to_string(x.c_str());
    arr.push_back(s);
  }
  JL_GC_POP();
  return arr;
}

// Resolve an export of HBM_QX_Framework.dll at run time. Needed where the vendor import
// library does not match the header: HBM_XCTRL_ReadXML and HBM_XSYS_RequestDebugInfo
// are exported undecorated by the DLL, but HBM_QX_Framework.lib refers to them by
// C++-mangled names (?HBM_XCTRL_ReadXML@@YGH_KPBDPADPAII@Z, ...).
template <typename Fn> Fn hbm_proc(const char* name)
{
  HMODULE h = GetModuleHandleA("HBM_QX_Framework.dll");
  FARPROC p = h ? GetProcAddress(h, name) : nullptr;
  if (!p)
    throw std::runtime_error(std::string(name) + " is not exported by HBM_QX_Framework.dll");
  return reinterpret_cast<Fn>(reinterpret_cast<void*>(p));
}

using fnCtrlReadXML = int(WINAPI*)(UINT64, const char*, void*, UINT32*, UINT32);
using fnRequestDebugInfo = int(WINAPI*)(UINT64, UINT32, char*, char*, char*, char*, char*, char*, UINT32);

// ------------------------------------------------- async measured value requests
// HBM_XDAQ_Async_GetMeasValBlock writes the received length to *pRxLen when the
// request completes, i.e. after the call returned. Keep that UINT32 alive here,
// keyed by the request handle, until HBM_XCOM_Async_ReadData* reports completion.
std::mutex g_async_mutex;
std::map<UINT32, std::unique_ptr<UINT32>> g_async_len;

UINT32 async_len(UINT32 handle, bool erase)
{
  std::lock_guard<std::mutex> lock(g_async_mutex);
  auto it = g_async_len.find(handle);
  if (it == g_async_len.end())
    return 0;
  UINT32 len = *it->second;
  if (erase)
    g_async_len.erase(it);
  return len;
}

// ----------------------------------------------- layout information for tests
#define QX_FIELD(T, f) names += #T "." #f ","; offs.push_back(int(offsetof(T, f)))
#define QX_SIZE(T) names += #T ".sizeof,"; offs.push_back(int(sizeof(T)))

std::tuple<std::string, jlcxx::Array<int>> layout_info()
{
  std::string names;
  std::vector<int> offs;
  QX_SIZE(stTwoPointScaling); QX_SIZE(stScaling); QX_FIELD(stScaling, TwoPoint);
  QX_SIZE(stBridgeSensor); QX_FIELD(stBridgeSensor, Impedance);
  QX_SIZE(stIndBridgeSensor); QX_FIELD(stIndBridgeSensor, Impedance);
  QX_SIZE(stThermoCouple); QX_SIZE(stPressure); QX_SIZE(stPotentiometer); QX_SIZE(stPt);
  QX_SIZE(stFrequency); QX_SIZE(stCounter); QX_SIZE(stSSI); QX_SIZE(stSensorIdent);
  QX_SIZE(stSensor);
  QX_FIELD(stSensor, PhysUnit); QX_FIELD(stSensor, PhysUnitUsr); QX_FIELD(stSensor, Identification);
  QX_FIELD(stSensor, Type); QX_FIELD(stSensor, Scaling); QX_FIELD(stSensor, Bridge);
  QX_FIELD(stSensor, IndBridge); QX_FIELD(stSensor, ThermoCouple); QX_FIELD(stSensor, Pt);
  QX_FIELD(stSensor, Frequency); QX_FIELD(stSensor, Counter); QX_FIELD(stSensor, SSI);
  QX_FIELD(stSensor, Poti); QX_FIELD(stSensor, Pressure);
  QX_SIZE(stCanSigDesc);
  QX_FIELD(stCanSigDesc, Identifier); QX_FIELD(stCanSigDesc, ScalingFactor); QX_FIELD(stCanSigDesc, PhysUnit);
  QX_FIELD(stCanSigDesc, PhysUnitUsr); QX_FIELD(stCanSigDesc, ModeBitSequence); QX_FIELD(stCanSigDesc, ModeValue);
  QX_FIELD(stCanSigDesc, ModeStartbit); QX_FIELD(stCanSigDesc, SignalType);
  QX_SIZE(stSignalParams); QX_FIELD(stSignalParams, FiltFreq); QX_FIELD(stSignalParams, OutputUnitUsr);
  QX_SIZE(stCanSignalParams); QX_FIELD(stCanSignalParams, DecimalPlaces);
  QX_SIZE(stAlarmIndexParams); QX_FIELD(stAlarmIndexParams, Level); QX_FIELD(stAlarmIndexParams, NotificationId);
  QX_SIZE(stAlarmGlobalParams);
  QX_SIZE(stPeakIndexParams); QX_FIELD(stPeakIndexParams, InputGate);
  QX_SIZE(stGateIndexParams); QX_FIELD(stGateIndexParams, OnLevel);
  QX_SIZE(stTrigInfo); QX_FIELD(stTrigInfo, Uuid); QX_FIELD(stTrigInfo, LevelMin); QX_FIELD(stTrigInfo, Name);
  QX_SIZE(stDaqHeader); QX_FIELD(stDaqHeader, MeasValCount); QX_FIELD(stDaqHeader, TimeStamp); QX_FIELD(stDaqHeader, u);
  QX_SIZE(stErrStatItem); QX_FIELD(stErrStatItem, ErrText);
  QX_SIZE(stModStatItem); QX_FIELD(stModStatItem, Value); QX_FIELD(stModStatItem, Info);
  QX_SIZE(stConModulInfo); QX_FIELD(stConModulInfo, DevType); QX_FIELD(stConModulInfo, InterfaceHandle);
  QX_SIZE(DeviceInfo); QX_FIELD(DeviceInfo, Port); QX_FIELD(DeviceInfo, Uuid); QX_FIELD(DeviceInfo, Name); QX_FIELD(DeviceInfo, Type);
  jlcxx::Array<int> arr;
  JL_GC_PUSH1(arr.gc_pointer());
  for (int o : offs)
    arr.push_back(o);
  JL_GC_POP();
  return std::make_tuple(names, arr);
}
#undef QX_FIELD
#undef QX_SIZE

} // namespace

JLCXX_MODULE define_julia_module(jlcxx::Module& mod)
{
  using jlcxx::ArrayRef;
  using std::string;
  using std::make_tuple;

  // ---------------------------------------------------------- type mappings
  // Enums used in function signatures -> Julia @enum types (src/generated/enums.jl)
  mod.map_type<enParView>("ParView");
  mod.map_type<enBgService>("BgService");
  mod.map_type<enScaleType>("ScaleType");
  mod.map_type<enLogDataFormat>("LogDataFormat");
  mod.map_type<enLogWrapMode>("LogWrapMode");
  // Structs -> Julia isbits mirror types (src/types.jl)
  mod.map_type<stSensor>("stSensor");
  mod.map_type<stCanSigDesc>("stCanSigDesc");
  mod.map_type<stSignalParams>("stSignalParams");
  mod.map_type<stCanSignalParams>("stCanSignalParams");
  mod.map_type<stAlarmIndexParams>("stAlarmIndexParams");
  mod.map_type<stAlarmGlobalParams>("stAlarmGlobalParams");
  mod.map_type<stPeakIndexParams>("stPeakIndexParams");
  mod.map_type<stGateIndexParams>("stGateIndexParams");
  mod.map_type<stTrigInfo>("stTrigInfo");
  mod.map_type<stDaqHeader>("stDaqHeader");
  mod.map_type<stErrStatItem>("stErrStatItem");
  mod.map_type<stModStatItem>("stModStatItem");
  mod.map_type<stConModulInfo>("stConModulInfo");
  mod.map_type<DeviceInfo>("stDeviceInfo");

  mod.method("layout_info", &layout_info);

  // ============================================================ XPAR (parameters)
  mod.method("HBM_XPAR_WriteXML", [](UINT64 uuid, enParView view, const string& data, UINT32 size) {
    return HBM_XPAR_WriteXML(uuid, view, data.c_str(), size);
  });
  mod.method("HBM_XPAR_ReadXML", [](UINT64 uuid, enParView view, UINT32 currentChoicesOnly, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XPAR_ReadXML(uuid, view, currentChoicesOnly, b, l, m); });
  });
  mod.method("HBM_XPAR_ReadXSD", [](UINT64 uuid, enParView view, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XPAR_ReadXSD(uuid, view, b, l, m); });
  });
  mod.method("HBM_XPAR_ReadXSLT", [](UINT64 uuid, enParView view, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XPAR_ReadXSLT(uuid, view, b, l, m); });
  });
  mod.method("HBM_XPAR_WriteXMLSect", [](UINT64 uuid, enParView view, const string& xpath, const string& data, UINT32 size) {
    return HBM_XPAR_WriteXMLSect(uuid, view, xpath.c_str(), data.c_str(), size);
  });
  mod.method("HBM_XPAR_WriteDoublePar", [](UINT64 uuid, enParView view, const string& xpath, const string& name, double v) {
    return HBM_XPAR_WriteDoublePar(uuid, view, xpath.c_str(), name.c_str(), v);
  });
  mod.method("HBM_XPAR_ReadDoublePar", [](UINT64 uuid, enParView view, const string& xpath, const string& name) {
    double v = 0.0;
    int rc = HBM_XPAR_ReadDoublePar(uuid, view, xpath.c_str(), name.c_str(), &v);
    return make_tuple(rc, v);
  });
  mod.method("HBM_XPAR_WriteIntPar", [](UINT64 uuid, enParView view, const string& xpath, const string& name, INT32 v) {
    return HBM_XPAR_WriteIntPar(uuid, view, xpath.c_str(), name.c_str(), v);
  });
  mod.method("HBM_XPAR_WriteStringPar", [](UINT64 uuid, enParView view, const string& xpath, const string& name, const string& v) {
    return HBM_XPAR_WriteStringPar(uuid, view, xpath.c_str(), name.c_str(), v.c_str());
  });
  mod.method("HBM_XPAR_ActivateDefaultSetting", [](UINT64 uuid, enParView view, const string& xpath) {
    return HBM_XPAR_ActivateDefaultSetting(uuid, view, xpath.c_str());
  });
  mod.method("HBM_XPAR_ActivateAllDefaultSettings", [](UINT64 uuid) { return HBM_XPAR_ActivateAllDefaultSettings(uuid); });
  mod.method("HBM_XPAR_ReadXMLSect", [](UINT64 uuid, enParView view, UINT32 currentChoicesOnly, const string& xpath, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XPAR_ReadXMLSect(uuid, view, currentChoicesOnly, xpath.c_str(), b, l, m); });
  });
  mod.method("HBM_XPAR_ReadXSLTSect", [](UINT64 uuid, enParView view, const string& xpath, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XPAR_ReadXSLTSect(uuid, view, xpath.c_str(), b, l, m); });
  });
  mod.method("HBM_XPAR_ReadXSDSect", [](UINT64 uuid, enParView view, const string& xpath, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XPAR_ReadXSDSect(uuid, view, xpath.c_str(), b, l, m); });
  });
  // rc, tid, datlen = HBM_XPAR_ReadTedsBinary(uuid, connector, buf::Vector{UInt8})
  mod.method("HBM_XPAR_ReadTedsBinary", [](UINT64 uuid, UINT32 connector, ArrayRef<UINT8, 1> buf) {
    char tid[32] = {0};
    UINT32 len = 0;
    int rc = HBM_XPAR_ReadTedsBinary(uuid, connector, tid, buf.data(), &len, UINT32(buf.size()));
    return make_tuple(rc, cstr_or_empty(tid), len);
  });
  // rc, tid = HBM_XPAR_WriteTedsBinary(uuid, connector, data::Vector{UInt8})
  mod.method("HBM_XPAR_WriteTedsBinary", [](UINT64 uuid, UINT32 connector, ArrayRef<UINT8, 1> data) {
    char tid[32] = {0};
    int rc = HBM_XPAR_WriteTedsBinary(uuid, connector, tid, data.data(), UINT32(data.size()));
    return make_tuple(rc, cstr_or_empty(tid));
  });
  mod.method("HBM_XPAR_GetLastErrMsg", []() {
    char* p = nullptr;
    UINT32 len = 0;
    int rc = HBM_XPAR_GetLastErrMsg(&p, &len);
    return make_tuple(rc, p ? string(p, strnlen(p, len)) : string());
  });
  mod.method("HBM_XPAR_GetParViews", [](UINT64 uuid, const string& filename) { return HBM_XPAR_GetParViews(uuid, filename.c_str()); });
  mod.method("HBM_XPAR_GetParViewsString", [](UINT64 uuid, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XPAR_GetParViewsString(uuid, b, l, m); });
  });

  // ============================================================ XSYS (system)
  mod.method("HBM_XSYS_WriteFile", [](UINT64 uuid, const string& file, const string& src, const string& dst) {
    return HBM_XSYS_WriteFile(uuid, file.c_str(), src.c_str(), dst.c_str());
  });
  mod.method("HBM_XSYS_ReadFile", [](UINT64 uuid, const string& file, const string& src, const string& dst) {
    return HBM_XSYS_ReadFile(uuid, file.c_str(), src.c_str(), dst.c_str());
  });
  mod.method("HBM_XSYS_WriteFirmware", [](UINT64 uuid, const string& path) { return HBM_XSYS_WriteFirmware(uuid, path.c_str()); });
  mod.method("HBM_XSYS_StartFlashing", [](UINT64 uuid) { return HBM_XSYS_StartFlashing(uuid); });
  mod.method("HBM_XSYS_StartMSPFlashing", [](UINT64 uuid, UINT32 msp) { return HBM_XSYS_StartMSPFlashing(uuid, msp); });
  mod.method("HBM_XSYS_GetFlashStatus", [](UINT64 uuid) {
    INT32 status = 0;
    UINT32 progress = 0;
    int rc = HBM_XSYS_GetFlashStatus(uuid, &status, &progress);
    return make_tuple(rc, status, progress);
  });
  mod.method("HBM_XSYS_GetBackgroundServiceResult", [](UINT64 uuid, UINT32 connector, enBgService svc, UINT32 maxlen) {
    return read_text(maxlen, [&](char* b, UINT32* l, UINT32 m) { return HBM_XSYS_GetBackgroundServiceResult(uuid, connector, svc, b, l, m); });
  });
  mod.method("HBM_XSYS_DoRestartSystem", [](UINT64 uuid, bool cold, bool useUDP) {
    return HBM_XSYS_DoRestartSystem(uuid, cold ? HBM_TRUE : HBM_FALSE, useUDP ? HBM_TRUE : HBM_FALSE);
  });
  mod.method("HBM_XSYS_SetSimValue", [](UINT64 uuid, UINT32 conn, UINT32 chan, UINT32 sig, UINT32 mode, double value) {
    return HBM_XSYS_SetSimValue(uuid, conn, chan, sig, mode, value);
  });
  mod.method("HBM_XSYS_RequestDebugInfo", [](UINT64 uuid, UINT32 id, const string& p1, const string& p2, const string& p3,
                                             const string& p4, const string& p5, UINT32 retbufsize) {
    std::vector<string> pars{p1, p2, p3, p4, p5}; // DLL takes non-const char*
    std::vector<std::vector<char>> bufs;
    for (auto& p : pars)
      bufs.emplace_back(p.c_str(), p.c_str() + p.size() + 1);
    std::vector<char> ret(size_t(retbufsize) + 1, '\0');
    static const auto fn = hbm_proc<fnRequestDebugInfo>("HBM_XSYS_RequestDebugInfo");
    int rc = fn(uuid, id, bufs[0].data(), bufs[1].data(), bufs[2].data(), bufs[3].data(),
                                       bufs[4].data(), ret.data(), retbufsize);
    return make_tuple(rc, string(ret.data(), strnlen(ret.data(), ret.size())));
  });
  mod.method("HBM_XSYS_GetMx840RgRx", [](UINT64 uuid, UINT32 conn) {
    INT32 rg = 0, rx = 0;
    INT32 rc = HBM_XSYS_GetMx840RgRx(uuid, conn, &rg, &rx);
    return make_tuple(int(rc), rg, rx);
  });
  mod.method("HBM_XSYS_GetMx840CalUgMeasUx", [](UINT64 uuid, UINT32 conn) {
    INT32 ug = 0, ux = 0;
    INT32 rc = HBM_XSYS_GetMx840CalUgMeasUx(uuid, conn, &ug, &ux);
    return make_tuple(int(rc), ug, ux);
  });

  // ============================================================ XDAQ (acquisition)
  mod.method("HBM_XDAQ_OpenSubscription", [](UINT64 uuid) { return HBM_XDAQ_OpenSubscription(uuid); });
  mod.method("HBM_XDAQ_AddSignal", [](UINT64 uuid, const string& sigid, UINT16 usersigid, UINT32 blocksize) {
    return HBM_XDAQ_AddSignal(uuid, sigid.c_str(), usersigid, blocksize);
  });
  mod.method("HBM_XDAQ_FinishSubscription", [](UINT64 uuid, UINT64 starttime) { return HBM_XDAQ_FinishSubscription(uuid, starttime); });
  mod.method("HBM_XDAQ_ClearSubscription", [](UINT64 uuid) { return HBM_XDAQ_ClearSubscription(uuid); });
  // rc, rxlen = HBM_XDAQ_GetMeasValBlock(uuid, buf::Vector{UInt8})
  mod.method("HBM_XDAQ_GetMeasValBlock", [](UINT64 uuid, ArrayRef<UINT8, 1> buf) {
    UINT32 rxlen = 0;
    int rc = HBM_XDAQ_GetMeasValBlock(uuid, buf.data(), &rxlen, UINT32(buf.size()));
    return make_tuple(rc, rxlen);
  });
  // rc, handle = HBM_XDAQ_Async_GetMeasValBlock(uuid, buf::Vector{UInt8})
  // `buf` is written asynchronously: keep it alive (and unmoved) until
  // HBM_XCOM_Async_ReadData(_Timeout) reports completion.
  mod.method("HBM_XDAQ_Async_GetMeasValBlock", [](UINT64 uuid, ArrayRef<UINT8, 1> buf) {
    auto len = std::make_unique<UINT32>(0);
    UINT32 handle = 0;
    INT32 rc;
    {
      std::lock_guard<std::mutex> lock(g_async_mutex);
      rc = HBM_XDAQ_Async_GetMeasValBlock(uuid, buf.data(), len.get(), UINT32(buf.size()), &handle);
      if (rc >= 0)
        g_async_len[handle] = std::move(len);
    }
    return make_tuple(int(rc), handle);
  });
  mod.method("HBM_XDAQ_GetAnalogMeasVal", [](UINT64 uuid, UINT32 conn, UINT32 sig, enScaleType scale) {
    double v = 0.0;
    int rc = HBM_XDAQ_GetAnalogMeasVal(uuid, conn, sig, scale, &v);
    return make_tuple(rc, v);
  });
  mod.method("HBM_XDAQ_GetCanMeasVal", [](UINT64 uuid, UINT32 conn, UINT32 chan) {
    double v = 0.0;
    int rc = HBM_XDAQ_GetCanMeasVal(uuid, conn, chan, &v);
    return make_tuple(rc, v);
  });
  // rc, sigcnt = HBM_XDAQ_GetAllMeasVals(uuid, enabledOnly, vals::Vector{Float64})
  mod.method("HBM_XDAQ_GetAllMeasVals", [](UINT64 uuid, UINT32 enabledOnly, ArrayRef<double, 1> vals) {
    UINT32 cnt = 0;
    int rc = HBM_XDAQ_GetAllMeasVals(uuid, enabledOnly, &cnt, vals.data(), UINT32(vals.size()));
    return make_tuple(rc, cnt);
  });
  mod.method("HBM_XDAQ_GetMeasVal", [](UINT64 uuid, const string& sigid) {
    double v = 0.0;
    int rc = HBM_XDAQ_GetMeasVal(uuid, sigid.c_str(), &v);
    return make_tuple(rc, v);
  });
  mod.method("HBM_XDAQ_ActivateTrigger", [](const stTrigInfo& trig) {
    stTrigInfo t = trig;
    return HBM_XDAQ_ActivateTrigger(&t);
  });
  mod.method("HBM_XDAQ_ClearTrigger", [](const string& name) {
    std::vector<char> n(name.c_str(), name.c_str() + name.size() + 1);
    return HBM_XDAQ_ClearTrigger(n.data());
  });
  mod.method("HBM_XDAQ_WaitForTrigger", [](UINT32 timeout, const string& expr) {
    UINT64 t = 0;
    int rc = HBM_XDAQ_WaitForTrigger(timeout, expr.c_str(), &t);
    return make_tuple(rc, t);
  });
  // rc, sigids::Vector{Any} = HBM_XDAQ_GetSignalList(uuid)
  mod.method("HBM_XDAQ_GetSignalList", [](UINT64 uuid) {
    auto list = std::make_unique<stSignalList>(); // ~45 kB, keep off the stack
    std::memset(list.get(), 0, sizeof(stSignalList));
    int rc = HBM_XDAQ_GetSignalList(uuid, list.get());
    std::vector<string> ids;
    if (rc >= 0)
      for (UINT32 i = 0; i < std::min<UINT32>(list->SigCnt, MAX_SIGNALS); ++i)
        ids.emplace_back(list->SigId[i], strnlen(list->SigId[i], SIGID_LEN + 1));
    return make_tuple(rc, make_string_array(ids));
  });

  // ============================================================ XSTAT (status)
  mod.method("HBM_XSTAT_GetConnectedModules", [](UINT64 uuid, UINT32 maxcount) {
    std::vector<stConModulInfo> mods(std::max<UINT32>(maxcount, 1));
    UINT32 cnt = 0;
    int rc = HBM_XSTAT_GetConnectedModules(uuid, mods.data(), &cnt, maxcount);
    size_t n = rc >= 0 ? std::min<size_t>(cnt, maxcount) : 0;
    return make_tuple(rc, make_array<stConModulInfo>(mods.data(), n));
  });
  mod.method("HBM_XSTAT_GetTopology", [](const string& filename) { return HBM_XSTAT_GetTopology(filename.c_str()); });
  mod.method("HBM_XSTAT_GetTopologyString", [](UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XSTAT_GetTopologyString(b, l, m); });
  });
  mod.method("HBM_XSTAT_GetErrorStatus", [](UINT64 uuid) {
    auto list = std::make_unique<stErrStatList>();
    std::memset(list.get(), 0, sizeof(stErrStatList));
    INT32 rc = HBM_XSTAT_GetErrorStatus(uuid, list.get());
    size_t n = rc >= 0 ? std::min<size_t>(list->Count, MAX_ERRLIST_ITEMS) : 0;
    return make_tuple(int(rc), make_array<stErrStatItem>(list->Item, n));
  });
  mod.method("HBM_XSTAT_GetModuleStatus", [](UINT64 uuid) {
    auto list = std::make_unique<stModStatList>();
    INT32 rc = HBM_XSTAT_GetModuleStatus(uuid, list.get());
    size_t n = rc >= 0 ? std::min<size_t>(list->Count, MAX_STATUSLIST_ITEMS) : 0;
    return make_tuple(int(rc), make_array<stModStatItem>(list->Item, n));
  });

  // ============================================================ XCTRL (controls)
  // args: Vector{Any} of Strings (0..8 entries)
  mod.method("HBM_XCTRL_Execute", [](UINT64 uuid, const string& control, UINT64 timestamp, ArrayRef<jl_value_t*, 1> args) {
    std::vector<const char*> argv;
    for (size_t i = 0; i < args.size(); ++i)
    {
      jl_value_t* a = args[i];
      if (!jl_is_string(a))
        throw std::runtime_error("HBM_XCTRL_Execute: all arguments must be Strings");
      argv.push_back(jl_string_ptr(a));
    }
    return HBM_XCTRL_Execute(uuid, control.c_str(), timestamp, UINT32(argv.size()), argv.empty() ? nullptr : argv.data());
  });
  mod.method("HBM_XCTRL_ExecuteXMLPars", [](UINT64 uuid, const string& control, UINT64 timestamp, const string& xmlpars, UINT32 maxsize) {
    std::vector<char> buf(size_t(maxsize) + 1, '\0');
    unsigned int len = 0;
    int rc = HBM_XCTRL_ExecuteXMLPars(uuid, control.c_str(), timestamp, xmlpars.c_str(), buf.data(), &len, maxsize);
    return make_tuple(rc, to_string(buf, len));
  });
  mod.method("HBM_XCTRL_GetControls", [](UINT64 uuid, const string& filename) { return HBM_XCTRL_GetControls(uuid, filename.c_str()); });
  mod.method("HBM_XCTRL_GetControlsString", [](UINT64 uuid, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XCTRL_GetControlsString(uuid, b, l, m); });
  });
  mod.method("HBM_XCTRL_SetLedMode", [](UINT64 uuid, UINT32 led, UINT32 mode) { return int(HBM_XCTRL_SetLedMode(uuid, led, mode)); });
  mod.method("HBM_XCTRL_ReadXML", [](UINT64 uuid, const string& control, UINT32 maxsize) {
    static const auto fn = hbm_proc<fnCtrlReadXML>("HBM_XCTRL_ReadXML");
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return fn(uuid, control.c_str(), b, l, m); });
  });
  mod.method("HBM_XCTRL_ReadXSD", [](UINT64 uuid, const string& control, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XCTRL_ReadXSD(uuid, control.c_str(), b, l, m); });
  });
  mod.method("HBM_XCTRL_ReadXSLT", [](UINT64 uuid, const string& control, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XCTRL_ReadXSLT(uuid, control.c_str(), b, l, m); });
  });
  mod.method("HBM_XCTRL_SetCalPoint", [](UINT64 uuid, UINT32 chan, UINT32 nr, UINT32 type, double v) { return HBM_XCTRL_SetCalPoint(uuid, chan, nr, type, v); });
  mod.method("HBM_XCTRL_SetPllVoltage", [](UINT64 uuid, UINT32 cmd, double v) { return HBM_XCTRL_SetPllVoltage(uuid, cmd, v); });
  mod.method("HBM_XCTRL_SetZeroWithTarget", [](UINT64 uuid, UINT32 conn, UINT32 chan, double target) {
    return HBM_XCTRL_SetZeroWithTarget(uuid, conn, chan, target);
  });
  mod.method("HBM_XCTRL_SetZero", [](UINT64 uuid, UINT32 conn, UINT32 chan) { return HBM_XCTRL_SetZero(uuid, conn, chan); });
  mod.method("HBM_XCTRL_SetInputSource", [](UINT64 uuid, UINT32 conn, UINT32 type, UINT32 src) { return HBM_XCTRL_SetInputSource(uuid, conn, type, src); });
  mod.method("HBM_XCTRL_CorrectPhase", [](UINT64 uuid, UINT32 conn) { return HBM_XCTRL_CorrectPhase(uuid, conn); });
  mod.method("HBM_XCTRL_ActivateTeds", [](UINT64 uuid, UINT32 conn, UINT64 ts) { return HBM_XCTRL_ActivateTeds(uuid, conn, ts); });
  mod.method("HBM_XCTRL_SetI2SToCal", [](UINT64 uuid, UINT32 src) { return HBM_XCTRL_SetI2SToCal(uuid, src); });
  // HBM_XCTRL_TransmitUserCanMsg(uuid, conn, identifier, data::Vector{UInt8}) — length(data) <= 8
  mod.method("HBM_XCTRL_TransmitUserCanMsg", [](UINT64 uuid, UINT32 conn, UINT32 identifier, ArrayRef<UINT8, 1> data) {
    if (data.size() > 8)
      throw std::runtime_error("HBM_XCTRL_TransmitUserCanMsg: at most 8 data bytes");
    UINT8 b[8] = {0};
    for (size_t i = 0; i < data.size(); ++i)
      b[i] = data[i];
    return int(HBM_XCTRL_TransmitUserCanMsg(uuid, conn, identifier, UINT8(data.size()), b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]));
  });

  // ============================================================ XADMIN
  mod.method("HBM_XADMIN_Login", [](UINT64 uuid, const string& user, const string& pw) { return HBM_XADMIN_Login(uuid, user.c_str(), pw.c_str()); });
  mod.method("HBM_XADMIN_Logout", [](UINT64 uuid) { return HBM_XADMIN_Logout(uuid); });

  // ============================================================ XCOM (communication)
  mod.method("HBM_XCOM_GetOwnUUID", []() { return HBM_XCOM_GetOwnUUID(); });
  mod.method("HBM_XCOM_StartTcpServer", [](UINT16 port) { return HBM_XCOM_StartTcpServer(port); });
  mod.method("HBM_XCOM_ConnectToTcpIpDev", [](const string& ip, UINT16 port) {
    UINT64 uuid = 0;
    int rc = HBM_XCOM_ConnectToTcpIpDev(ip.c_str(), port, &uuid);
    return make_tuple(rc, uuid);
  });
  mod.method("HBM_XCOM_DisconnectFromTcpIpDev", [](const string& ip, UINT16 port) { return HBM_XCOM_DisconnectFromTcpIpDev(ip.c_str(), port); });
  mod.method("HBM_XCOM_GetNetAdapter", [](UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XCOM_GetNetAdapter(b, l, m); });
  });
  mod.method("HBM_XCOM_DoFirewireScan", [](UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XCOM_DoFirewireScan(b, l, m); });
  });
  mod.method("HBM_XCOM_DoNetScan", [](UINT32 adapter, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XCOM_DoNetScan(adapter, b, l, m); });
  });
  mod.method("HBM_XCOM_DisableHBMDevice", []() { HBM_XCOM_DisableHBMDevice(); });
  mod.method("HBM_XCOM_ReadNetSetting", [](UINT64 uuid, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XCOM_ReadNetSetting(uuid, b, l, m); });
  });
  mod.method("HBM_XCOM_ReadNetSettings", [](UINT64 uuid, UINT32 maxsize) {
    return read_text(maxsize, [&](char* b, UINT32* l, UINT32 m) { return HBM_XCOM_ReadNetSettings(uuid, b, l, m); });
  });
  mod.method("HBM_XCOM_WriteNetSetting", [](UINT64 uuid, const string& data, UINT32 len) {
    std::vector<char> d(data.c_str(), data.c_str() + data.size() + 1);
    return int(HBM_XCOM_WriteNetSetting(uuid, d.data(), len));
  });
  // rc, rxlen = HBM_XCOM_Async_ReadData(handle)
  mod.method("HBM_XCOM_Async_ReadData", [](UINT32 handle) {
    INT32 rc = HBM_XCOM_Async_ReadData(handle);
    return make_tuple(int(rc), async_len(handle, rc != ERR_EVFLG_PTHREADS));
  });
  mod.method("HBM_XCOM_Async_ReadData_Timeout", [](UINT32 handle, UINT32 timeout_ms) {
    INT32 rc = HBM_XCOM_Async_ReadData_Timeout(handle, timeout_ms);
    return make_tuple(int(rc), async_len(handle, rc != ERR_EVFLG_PTHREADS));
  });
  mod.method("HBM_XCOM_ScanFirewireSegment", []() {
    auto list = std::make_unique<stDeviceList>();
    std::memset(list.get(), 0, sizeof(stDeviceList));
    INT32 rc = HBM_XCOM_ScanFirewireSegment(list.get());
    size_t n = rc >= 0 ? std::min<size_t>(list->Count, MAX_DEVICE) : 0;
    return make_tuple(int(rc), make_array<DeviceInfo>(list->Device, n));
  });
  mod.method("HBM_XCOM_ScanEthSegment", [](UINT32 adapter) {
    auto list = std::make_unique<stDeviceList>();
    std::memset(list.get(), 0, sizeof(stDeviceList));
    INT32 rc = HBM_XCOM_ScanEthSegment(adapter, list.get());
    size_t n = rc >= 0 ? std::min<size_t>(list->Count, MAX_DEVICE) : 0;
    return make_tuple(int(rc), make_array<DeviceInfo>(list->Device, n));
  });
  mod.method("HBM_XCOM_GetSyncReqrSrvLastErrDat", []() {
    char* p = nullptr;
    UINT32 len = 0;
    int rc = HBM_XCOM_GetSyncReqrSrvLastErrDat(&p, &len);
    return make_tuple(rc, p ? string(p, strnlen(p, len)) : string());
  });

  // ============================================================ XUTIL (utilities)
  mod.method("HBM_XUTIL_SetWorkDir", [](const string& dir) { return int(HBM_XUTIL_SetWorkDir(dir.c_str())); });
  mod.method("HBM_XUTIL_GetText", [](INT32 handle) { return cstr_or_empty(HBM_XUTIL_GetText(handle)); });
  mod.method("HBM_XUTIL_GetTextFromModule", [](UINT64 uuid, INT32 handle) { return cstr_or_empty(HBM_XUTIL_GetTextFromModule(uuid, handle)); });
  mod.method("HBM_XUTIL_GetUnitNameFromCode", [](UINT32 code) { return cstr_or_empty(HBM_XUTIL_GetUnitNameFromCode(code)); });
  mod.method("HBM_XUTIL_GetUnitCodeFromName", [](const string& name) { return HBM_XUTIL_GetUnitCodeFromName(name.c_str()); });
  // rc, header, offset = HBM_XUTIL_GetDaqHeader(mode, sigid, buf::Vector{UInt8}, srcsize)
  mod.method("HBM_XUTIL_GetDaqHeader", [](UINT32 mode, UINT32 sigid, ArrayRef<UINT8, 1> buf, UINT32 srcsize) {
    stDaqHeader hdr;
    std::memset(&hdr, 0, sizeof(hdr));
    UINT32 offset = 0;
    srcsize = std::min<UINT32>(srcsize, UINT32(buf.size()));
    INT32 rc = HBM_XUTIL_GetDaqHeader(mode, sigid, buf.data(), srcsize, &hdr, &offset);
    return make_tuple(int(rc), hdr, offset);
  });
  // rc = HBM_XUTIL_GetDaqData(buf::Vector{UInt8}, offset, header, dst::Ptr{Cvoid}, dstsize)
  mod.method("HBM_XUTIL_GetDaqData", [](ArrayRef<UINT8, 1> buf, UINT32 offset, const stDaqHeader& hdr, void* dst, UINT32 dstsize) {
    return int(HBM_XUTIL_GetDaqData(buf.data(), offset, &hdr, dst, dstsize));
  });
  mod.method("HBM_XUTIL_ComposeAmplifierPath", [](UINT32 conn, UINT32 maxlen) {
    std::vector<char> buf(size_t(maxlen) + 1, '\0');
    HBM_XUTIL_ComposeAmplifierPath(conn, buf.data(), maxlen);
    return string(buf.data(), strnlen(buf.data(), buf.size()));
  });
  mod.method("HBM_XUTIL_ComposeSignalPath", [](UINT32 conn, UINT32 chan, UINT32 sig, UINT32 conntype, UINT32 maxlen) {
    return compose_path(maxlen, [&](char* b, UINT32 m, UINT32* l) { HBM_XUTIL_ComposeSignalPath(conn, chan, sig, conntype, b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposeChannelPath", [](UINT32 conn, UINT32 chan, UINT32 conntype, UINT32 maxlen) {
    return compose_path(maxlen, [&](char* b, UINT32 m, UINT32* l) { HBM_XUTIL_ComposeChannelPath(conn, chan, conntype, b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposeSensorPath", [](UINT32 conn, UINT32 chan, UINT32 conntype, UINT32 maxlen) {
    return compose_path(maxlen, [&](char* b, UINT32 m, UINT32* l) { HBM_XUTIL_ComposeSensorPath(conn, chan, conntype, b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposeAlarmPath", [](UINT32 maxlen) {
    return compose_path(maxlen, [&](char* b, UINT32 m, UINT32* l) { HBM_XUTIL_ComposeAlarmPath(b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposePeakPath", [](UINT32 maxlen) {
    return compose_path(maxlen, [&](char* b, UINT32 m, UINT32* l) { HBM_XUTIL_ComposePeakPath(b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposeGatePath", [](UINT32 maxlen) {
    return compose_path(maxlen, [&](char* b, UINT32 m, UINT32* l) { HBM_XUTIL_ComposeGatePath(b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposeSensor", [](const stSensor& s, UINT32 maxlen) {
    return compose_xml(maxlen, [&](char* b, UINT32 m, UINT32* l) { return HBM_XUTIL_ComposeSensor(&s, b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposeCanSensor", [](const stCanSigDesc& s, UINT32 maxlen) {
    return compose_xml(maxlen, [&](char* b, UINT32 m, UINT32* l) { return HBM_XUTIL_ComposeCanSensor(&s, b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposeCanSignal", [](const stCanSignalParams& s, UINT32 maxlen) {
    return compose_xml(maxlen, [&](char* b, UINT32 m, UINT32* l) { return HBM_XUTIL_ComposeCanSignal(&s, b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposeSignal", [](const stSignalParams& s, UINT32 maxlen) {
    return compose_xml(maxlen, [&](char* b, UINT32 m, UINT32* l) { return HBM_XUTIL_ComposeSignal(&s, b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposeAlarmGlobal", [](const stAlarmGlobalParams& s, UINT32 maxlen) {
    return compose_xml(maxlen, [&](char* b, UINT32 m, UINT32* l) { return HBM_XUTIL_ComposeAlarmGlobal(&s, b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposeAlarmIndex", [](UINT32 index, const stAlarmIndexParams& s, UINT32 maxlen) {
    return compose_xml(maxlen, [&](char* b, UINT32 m, UINT32* l) { return HBM_XUTIL_ComposeAlarmIndex(index, &s, b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposeGateIndex", [](UINT32 index, const stGateIndexParams& s, UINT32 maxlen) {
    return compose_xml(maxlen, [&](char* b, UINT32 m, UINT32* l) { return HBM_XUTIL_ComposeGateIndex(index, &s, b, m, l); });
  });
  mod.method("HBM_XUTIL_ComposePeakIndex", [](UINT32 index, const stPeakIndexParams& s, UINT32 maxlen) {
    return compose_xml(maxlen, [&](char* b, UINT32 m, UINT32* l) { return HBM_XUTIL_ComposePeakIndex(index, &s, b, m, l); });
  });
  mod.method("HBM_XUTIL_ParseCanSensor", [](const string& xml, UINT32 len) {
    stCanSigDesc s;
    std::memset(&s, 0, sizeof(s));
    INT32 rc = HBM_XUTIL_ParseCanSensor(xml.c_str(), &s, len);
    return make_tuple(int(rc), s);
  });
  mod.method("HBM_XUTIL_ParseCanSignal", [](const string& xml, UINT32 len) {
    stCanSignalParams s;
    std::memset(&s, 0, sizeof(s));
    INT32 rc = HBM_XUTIL_ParseCanSignal(xml.c_str(), &s, len);
    return make_tuple(int(rc), s);
  });
  mod.method("HBM_XUTIL_ParseSensor", [](const string& xml, UINT32 len) {
    stSensor s;
    std::memset(&s, 0, sizeof(s));
    INT32 rc = HBM_XUTIL_ParseSensor(xml.c_str(), &s, len);
    return make_tuple(int(rc), s);
  });
  // rc = HBM_XUTIL_ParseErrors(conn, chan, mode, xml, len, errlist::Vector{Int32})
  mod.method("HBM_XUTIL_ParseErrors", [](UINT32 conn, UINT32 chan, UINT32 mode, const string& xml, UINT32 len, ArrayRef<INT32, 1> errlist) {
    return int(HBM_XUTIL_ParseErrors(conn, chan, mode, xml.c_str(), len, errlist.data(), UINT32(errlist.size())));
  });
  mod.method("HBM_XUTIL_ParseSignal", [](const string& xml, UINT32 len) {
    stSignalParams s;
    std::memset(&s, 0, sizeof(s));
    INT32 rc = HBM_XUTIL_ParseSignal(xml.c_str(), &s, len);
    return make_tuple(int(rc), s);
  });
  mod.method("HBM_XUTIL_ParseSignalPath", [](const string& xpath, UINT32 len) {
    UINT32 conn = 0, chan = 0, sig = 0, conntype = 0;
    INT32 rc = HBM_XUTIL_ParseSignalPath(xpath.c_str(), len, &conn, &chan, &sig, &conntype);
    return make_tuple(int(rc), conn, chan, sig, conntype);
  });
  mod.method("HBM_XUTIL_ParseAlarmGlobal", [](const string& xml) {
    stAlarmGlobalParams s;
    std::memset(&s, 0, sizeof(s));
    INT32 rc = HBM_XUTIL_ParseAlarmGlobal(xml.c_str(), &s);
    return make_tuple(int(rc), s);
  });
  mod.method("HBM_XUTIL_ParseAlarmIndex", [](UINT32 index, const string& xml) {
    stAlarmIndexParams s;
    std::memset(&s, 0, sizeof(s));
    INT32 rc = HBM_XUTIL_ParseAlarmIndex(index, xml.c_str(), &s);
    return make_tuple(int(rc), s);
  });
  mod.method("HBM_XUTIL_ParseGateIndex", [](UINT32 index, const string& xml) {
    stGateIndexParams s;
    std::memset(&s, 0, sizeof(s));
    INT32 rc = HBM_XUTIL_ParseGateIndex(index, xml.c_str(), &s);
    return make_tuple(int(rc), s);
  });
  mod.method("HBM_XUTIL_ParsePeakIndex", [](UINT32 index, const string& xml) {
    stPeakIndexParams s;
    std::memset(&s, 0, sizeof(s));
    INT32 rc = HBM_XUTIL_ParsePeakIndex(index, xml.c_str(), &s);
    return make_tuple(int(rc), s);
  });
  mod.method("HBM_XUTIL_GetLastXmlError", []() { return cstr_or_empty(HBM_XUTIL_GetLastXmlError()); });
  mod.method("HBM_XUTIL_SetNilValues", [](double d, INT32 i, UINT32 u) { HBM_XUTIL_SetNilValues(d, i, u); });
  mod.method("HBM_XUTIL_GetNilValues", []() {
    double d = 0.0;
    INT32 i = 0;
    UINT32 u = 0;
    HBM_XUTIL_GetNilValues(&d, &i, &u);
    return make_tuple(d, i, u);
  });
  mod.method("HBM_XUTIL_GetDllVersion", []() { return cstr_or_empty(HBM_XUTIL_GetDllVersion()); });
  mod.method("HBM_XUTIL_ParamLogfile", [](UINT32 type, const string& name, enLogDataFormat fmt, enLogWrapMode wrap, UINT32 size, UINT32 source) {
    return int(HBM_XUTIL_ParamLogfile(type, name.c_str(), fmt, wrap, size, source));
  });
  mod.method("HBM_XUTIL_LogAdd", [](UINT32 type, const string& text) {
    std::vector<char> t(text.c_str(), text.c_str() + text.size() + 1);
    return int(HBM_XUTIL_LogAdd(type, t.data()));
  });

  // ============================================================ init / unload
  mod.method("HBM_Init", []() { return int(HBM_Init()); });
  mod.method("HBM_Unload", []() { HBM_Unload(); });
}
