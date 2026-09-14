package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"github.com/klauspost/compress/zstd"
	"github.com/wangshiben/natP2pSDK/tunnel"
)

const (
	compressionMagic          = "FZST"
	compressionVersion        = 1
	compressionHeaderSize     = 16
	compressionFlagRaw        = 1 << 0
	compressionFlagFin        = 1 << 1
	compressionClientToServer = 1
	compressionServerToClient = 2
	compressionMaxFrameBytes  = 4 * 1024 * 1024
	// Keep the default compression aggregation bounded to an exact 512 KiB wire
	// frame (including this protocol's 16-byte header).
	// A 4 MiB frame fans out into sixteen concurrent 256 KiB billable sends;
	// two HTTP streams can therefore fill the entire per-connection send
	// window at once. On a congested KCP path the oldest send reaches the
	// delivery timeout before the fallback carrier drains the burst, rotating
	// the shared billing session and cancelling otherwise healthy transfers.
	// An aligned 512 KiB frame still amortizes framing and compression work,
	// avoids a header-only tail tunnel chunk at both 64 KiB and 256 KiB chunk
	// sizes, and keeps the burst small enough for control/ACK traffic to progress.
	compressionDefaultWireFrameSize = 512 * 1024
	compressionDefaultBufSize       = compressionDefaultWireFrameSize - compressionHeaderSize
	// Probe only a small sample before compressing a full frame. The local HTTP
	// fixture is intentionally random, so a full Zstd pass would be discarded
	// as raw output while still consuming CPU on every 4 MiB chunk.
	compressionProbeBytes           = 64 * 1024
	compressionProbeMinRatioPercent = 98
)

type compressionDirection byte

const (
	directionClientToServer compressionDirection = compressionClientToServer
	directionServerToClient compressionDirection = compressionServerToClient
)

type compressionBridgeMode byte

const (
	compressionClientMode compressionBridgeMode = iota + 1
	compressionServerMode
)

// compressedBridge preserves the two half-duplex directions of a TCP tunnel.
// The application side always sees raw bytes; only the tunnel side carries
// framed Zstd data. This keeps SDK handshake/control frames untouched.
func compressedBridge(left, right io.ReadWriteCloser, mode compressionBridgeMode, options tunnel.CopyOptions) error {
	if os.Getenv("FKNAT_DISABLE_COMPRESSION") == "1" {
		return tunnel.Bridge(left, right, options)
	}
	if left == nil || right == nil {
		return errors.New("compression bridge: both endpoints are required")
	}
	bufferSize := compressionBufferSize(options)
	options.BufferSize = bufferSize
	if options.CoalesceWindow < 0 {
		options.CoalesceWindow = tunnel.DefaultCopyOptions().CoalesceWindow
	}
	results := make(chan error, 2)
	if mode == compressionClientMode {
		go func() { results <- encodeCopy(right, left, directionClientToServer, options) }()
		go func() { results <- decodeCopy(left, right, directionServerToClient) }()
	} else if mode == compressionServerMode {
		go func() { results <- decodeCopy(right, left, directionClientToServer) }()
		go func() { results <- encodeCopy(left, right, directionServerToClient, options) }()
	} else {
		return errors.New("compression bridge: invalid mode")
	}
	var firstErr error
	for range 2 {
		pumpErr := <-results
		if pumpErr == nil || errors.Is(pumpErr, io.EOF) {
			continue
		}
		// A locally closed endpoint cannot produce a FIN frame. Tear down
		// the peer immediately in that case; otherwise a blocked opposite
		// pump would keep the connection alive forever.
		firstErr = pumpErr
		_ = left.Close()
		_ = right.Close()
		return firstErr
	}
	_ = left.Close()
	_ = right.Close()
	return firstErr
}

func compressionBufferSize(options tunnel.CopyOptions) int {
	bufferSize := options.BufferSize
	if bufferSize < 4096 || bufferSize > compressionMaxFrameBytes {
		return compressionDefaultBufSize
	}
	// An explicit TUNNEL_PUMP_BUF override remains authoritative. The default
	// deliberately matches the generic tunnel buffer so one compression frame
	// cannot manufacture a full-window burst of billable messages.
	if os.Getenv("TUNNEL_PUMP_BUF") == "" && bufferSize == tunnel.DefaultCopyOptions().BufferSize {
		return compressionDefaultBufSize
	}
	return bufferSize
}

func encodeCopy(destination io.Writer, source io.Reader, direction compressionDirection, options tunnel.CopyOptions) error {
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest))
	if err != nil {
		return fmt.Errorf("create zstd encoder: %w", err)
	}
	defer encoder.Close()
	buffer := make([]byte, options.BufferSize)
	deadlineSource, canCoalesce := source.(interface{ SetReadDeadline(time.Time) error })
	for {
		if canCoalesce {
			_ = deadlineSource.SetReadDeadline(time.Time{})
		}
		read, readErr := source.Read(buffer)
		if read > 0 && read < len(buffer) && readErr == nil && canCoalesce {
			_ = deadlineSource.SetReadDeadline(time.Now().Add(options.CoalesceWindow))
			for read < len(buffer) {
				additional, drainErr := source.Read(buffer[read:])
				read += additional
				if drainErr != nil {
					if netErr, ok := drainErr.(net.Error); ok && netErr.Timeout() {
						readErr = nil
					} else {
						readErr = drainErr
					}
					break
				}
			}
			_ = deadlineSource.SetReadDeadline(time.Time{})
		}
		if read > 0 {
			if err := writeCompressionFrame(destination, encoder, direction, buffer[:read]); err != nil {
				return err
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				if err := writeCompressionFin(destination, direction); err != nil {
					return err
				}
				return nil
			}
			return readErr
		}
	}
}

func decodeCopy(destination io.Writer, source io.Reader, expected compressionDirection) error {
	decoder, err := zstd.NewReader(nil,
		zstd.WithDecoderConcurrency(1),
		zstd.WithDecoderMaxMemory(compressionMaxFrameBytes*2),
		zstd.WithDecoderMaxWindow(compressionMaxFrameBytes),
	)
	if err != nil {
		return fmt.Errorf("create zstd decoder: %w", err)
	}
	defer decoder.Close()
	header := make([]byte, compressionHeaderSize)
	for {
		read, readErr := io.ReadFull(source, header)
		if readErr != nil {
			if errors.Is(readErr, io.EOF) && read == 0 {
				return nil
			}
			return fmt.Errorf("read compression frame header: %w", readErr)
		}
		if string(header[:4]) != compressionMagic {
			return errors.New("compression frame magic mismatch")
		}
		if header[4] != compressionVersion {
			return fmt.Errorf("unsupported compression frame version %d", header[4])
		}
		if compressionDirection(header[5]) != expected {
			return fmt.Errorf("compression direction mismatch: got=%d want=%d", header[5], expected)
		}
		if header[6]&^byte(compressionFlagRaw|compressionFlagFin) != 0 {
			return fmt.Errorf("compression frame has unknown flags 0x%x", header[6])
		}
		if header[7] != 0 {
			return errors.New("compression frame reserved bits are not zero")
		}
		rawSize := binary.BigEndian.Uint32(header[8:12])
		encodedSize := binary.BigEndian.Uint32(header[12:16])
		if header[6]&compressionFlagFin != 0 {
			if rawSize != 0 || encodedSize != 0 || header[6]&compressionFlagRaw != 0 {
				return errors.New("invalid compression FIN frame")
			}
			if closer, ok := destination.(interface{ CloseWrite() error }); ok {
				if err := closer.CloseWrite(); err != nil && !errors.Is(err, net.ErrClosed) {
					return fmt.Errorf("close compression destination write half: %w", err)
				}
			}
			return io.EOF
		}
		if rawSize == 0 || rawSize > compressionMaxFrameBytes {
			return fmt.Errorf("invalid compression raw size %d", rawSize)
		}
		if encodedSize == 0 || encodedSize > compressionMaxFrameBytes {
			return fmt.Errorf("invalid compression encoded size %d", encodedSize)
		}
		encoded := make([]byte, encodedSize)
		if _, err := io.ReadFull(source, encoded); err != nil {
			return fmt.Errorf("read compression frame payload: %w", err)
		}
		var decoded []byte
		if header[6]&compressionFlagRaw != 0 {
			if uint32(len(encoded)) != rawSize {
				return fmt.Errorf("raw compression frame size mismatch: got=%d want=%d", len(encoded), rawSize)
			}
			decoded = encoded
		} else {
			decoded, err = decodeBounded(decoder, encoded, rawSize)
			if err != nil {
				return err
			}
		}
		if err := writeAll(destination, decoded); err != nil {
			return err
		}
	}
}

func decodeBounded(decoder *zstd.Decoder, encoded []byte, rawSize uint32) ([]byte, error) {
	encodedReader := bytes.NewReader(encoded)
	if err := decoder.Reset(encodedReader); err != nil {
		return nil, fmt.Errorf("reset zstd decoder: %w", err)
	}
	decoded := make([]byte, rawSize)
	if _, err := io.ReadFull(decoder, decoded); err != nil {
		return nil, fmt.Errorf("decode zstd frame: %w", err)
	}
	var extra [1]byte
	read, err := decoder.Read(extra[:])
	if read != 0 {
		return nil, fmt.Errorf("decoded compression frame exceeds declared size %d", rawSize)
	}
	if err != io.EOF {
		if err == nil {
			return nil, fmt.Errorf("decoded compression frame did not terminate at declared size %d", rawSize)
		}
		return nil, fmt.Errorf("finish zstd frame: %w", err)
	}
	if encodedReader.Len() != 0 {
		return nil, errors.New("zstd frame has trailing encoded bytes")
	}
	return decoded, nil
}

func writeCompressionFrame(destination io.Writer, encoder *zstd.Encoder, direction compressionDirection, raw []byte) error {
	if len(raw) == 0 || len(raw) > compressionMaxFrameBytes {
		return fmt.Errorf("invalid compression input size %d", len(raw))
	}
	flags := byte(0)
	var encoded []byte
	if len(raw) > compressionProbeBytes && !compressionProbeLooksCompressible(encoder, raw) {
		// Keep the wire format unchanged: the raw flag tells the peer to bypass
		// the decoder, while avoiding a second full-frame compression attempt.
		flags = compressionFlagRaw
		encoded = raw
	} else {
		encoded = encoder.EncodeAll(raw, nil)
		if len(encoded) >= len(raw) {
			encoded = raw
			flags = compressionFlagRaw
		}
	}
	frame := make([]byte, compressionHeaderSize+len(encoded))
	copy(frame[:4], compressionMagic)
	frame[4] = compressionVersion
	frame[5] = byte(direction)
	frame[6] = flags
	binary.BigEndian.PutUint32(frame[8:12], uint32(len(raw)))
	binary.BigEndian.PutUint32(frame[12:16], uint32(len(encoded)))
	copy(frame[compressionHeaderSize:], encoded)
	if err := writeAll(destination, frame); err != nil {
		return fmt.Errorf("write compression frame: %w", err)
	}
	return nil
}

func compressionProbeLooksCompressible(encoder *zstd.Encoder, raw []byte) bool {
	if encoder == nil || len(raw) <= compressionProbeBytes {
		return true
	}
	// Sample the beginning, middle, and end so a partially compressible payload
	// does not get classified from a single unusually repetitive prefix.
	probe := make([]byte, compressionProbeBytes)
	first := compressionProbeBytes / 2
	copy(probe[:first], raw[:first])
	remaining := compressionProbeBytes - first
	middle := remaining / 2
	middleStart := (len(raw) - middle) / 2
	copy(probe[first:first+middle], raw[middleStart:middleStart+middle])
	last := remaining - middle
	copy(probe[first+middle:], raw[len(raw)-last:])
	encoded := encoder.EncodeAll(probe, nil)
	return len(encoded)*100 < len(probe)*compressionProbeMinRatioPercent
}

func writeCompressionFin(destination io.Writer, direction compressionDirection) error {
	header := make([]byte, compressionHeaderSize)
	copy(header[:4], compressionMagic)
	header[4] = compressionVersion
	header[5] = byte(direction)
	header[6] = compressionFlagFin
	if err := writeAll(destination, header); err != nil {
		return fmt.Errorf("write compression FIN frame: %w", err)
	}
	return nil
}

func writeAll(destination io.Writer, payload []byte) error {
	for len(payload) > 0 {
		written, err := destination.Write(payload)
		if written > 0 {
			payload = payload[written:]
		}
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}
