# Selected #define constants from the SDK headers.

# DaqDefs.h – measured value formats (stDaqHeader.DataFormat)
const DAQ_MVALFMT_MASK         = 0x0F
const DAQ_MVALFMT_FLOAT        = 0x14
const DAQ_MVALFMT_DOUBLE       = 0x18
const DAQ_MVALFMT_INT8         = 0x21
const DAQ_MVALFMT_INT16        = 0x22
const DAQ_MVALFMT_INT32        = 0x24
const DAQ_MVALFMT_INT64        = 0x28
const DAQ_MVALFMT_CANRAW       = 0x3E
const DAQ_MVALFMT_FLOAT_ASYNC  = 0x5C
const DAQ_MVALFMT_DOUBLE_ASYNC = 0x50
const DAQ_MVALFMT_INT32_ASYNC  = 0x6C
const DAQ_MVALFMT_INT64_ASYNC  = 0x60
const DAQ_MVALFMT_UINT32_ASYNC = 0xEC
const DAQ_MVALFMT_UINT64_ASYNC = 0xE0

const HDRFORMAT_SYNC  = 0x01
const HDRFORMAT_ASYNC = 0x02

const MAX_SIGNALS_PER_CHAN = 3
const MAX_CONN_COUNT       = 16
const MAX_CANSIGNALS       = 128
const MAX_SIGNALS          = MAX_CONN_COUNT * MAX_SIGNALS_PER_CHAN + MAX_CANSIGNALS
const SIGID_LEN            = 256
const MEASVAL_UNKNOWN      = 3e20
const MEASVAL_OVERFLOW     = 1.7014118e+038
const MEASVALBLOCKSIZELIMIT = 2_000_000

# DSS_FrameDefs.h – module status ids (stModStatItem.Id)
const STATUS_CONNECTED         = 0x0001
const STATUS_TIME              = 0x0004
const STATUS_TEDS              = 0x0008
const STATUS_MEASINVALID       = 0x0010
const STATUS_MEASOVERFLOW      = 0x0020
const STATUS_PARAM_BUSY        = 0x0040
const STATUS_ADJUST_BUSY       = 0x0080
const STATUS_ID_BITS_CONNECTOR = 0x8000

# device types (stConModulInfo.DevType)
const DEVTYPE_ROUTER           = 0x00000001
const DEVTYPE_LEAF             = 0x00000002
const DEVTYPE_VIAROUTER_FLAG   = 0x80000000
const DEVTYPE_ROUTER_VIAROUTER = DEVTYPE_ROUTER | DEVTYPE_VIAROUTER_FLAG
const DEVTYPE_LEAF_VIAROUTER   = DEVTYPE_LEAF | DEVTYPE_VIAROUTER_FLAG
const DEVTYPE_UNKNOWN          = 0x00000000

# TypeDef.h
const HBM_INVALID_UUID   = 0xFFFFFFFFFFFFFFFF
const HBM_BROADCAST_UUID = 0x8FFFFFFFFFFFFFFE

# log file ids (HBM_XUTIL_ParamLogfile / HBM_XUTIL_LogAdd)
const LOGID_COMMUNICATION = UInt32(5002)
const LOGID_ERROR         = UInt32(5003)
const LOGID_DEBUG         = UInt32(5004)

# default TCP port of QuantumX modules
const QX_DEFAULT_PORT = 5001

# Physical unit code meaning "user defined unit string"
const PHYSUNIT_USER = UInt32(100000)
