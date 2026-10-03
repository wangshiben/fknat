module fknat

go 1.25.0

require (
	github.com/klauspost/compress v1.16.7
	github.com/wangshiben/QuicFrameWork v0.0.0
	github.com/wangshiben/natP2pSDK v0.0.0
	github.com/xtaci/kcp-go/v5 v5.6.72
	golang.org/x/crypto v0.55.0
)

require (
	github.com/flynn/noise v1.1.0 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/klauspost/cpuid/v2 v2.3.0 // indirect
	github.com/klauspost/reedsolomon v1.14.0 // indirect
	github.com/pkg/errors v0.9.1 // indirect
	github.com/quic-go/qpack v0.6.0 // indirect
	github.com/quic-go/quic-go v0.59.1 // indirect
	github.com/tjfoc/gmsm v1.4.1 // indirect
	golang.org/x/net v0.58.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.41.0 // indirect
	golang.org/x/time v0.15.0 // indirect
)

replace github.com/wangshiben/natP2pSDK => ../natP2pSDK

replace github.com/wangshiben/QuicFrameWork => ../QuicFramework
