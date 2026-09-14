package main

import (
	"bytes"
	"errors"
	"io"
	"math/rand"
	"net"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
	"github.com/wangshiben/natP2pSDK/tunnel"
)

type countingWriter struct {
	bytes.Buffer
	writes int
}

func (writer *countingWriter) Write(payload []byte) (int, error) {
	writer.writes++
	return writer.Buffer.Write(payload)
}

type shortWriter struct {
	bytes.Buffer
	limit  int
	writes int
}

func (writer *shortWriter) Write(payload []byte) (int, error) {
	writer.writes++
	if len(payload) > writer.limit {
		payload = payload[:writer.limit]
	}
	return writer.Buffer.Write(payload)
}

func TestCompressionFrameRoundTrip(t *testing.T) {
	payload := bytes.Repeat([]byte("compressible fknat payload\n"), 8192)
	var encoded bytes.Buffer
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest))
	if err != nil {
		t.Fatal(err)
	}
	if err := writeCompressionFrame(&encoded, encoder, directionClientToServer, payload); err != nil {
		t.Fatal(err)
	}
	_ = encoder.Close()
	var decoded bytes.Buffer
	if err := decodeCopy(&decoded, &encoded, directionClientToServer); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decoded.Bytes(), payload) {
		t.Fatalf("decoded payload mismatch: got %d bytes, want %d", decoded.Len(), len(payload))
	}
}

func TestCompressionBufferSizeUsesBoundedDefault(t *testing.T) {
	t.Setenv("TUNNEL_PUMP_BUF", "")
	got := compressionBufferSize(tunnel.DefaultCopyOptions())
	if got != compressionDefaultBufSize {
		t.Fatalf("compression default buffer = %d, want %d", got, compressionDefaultBufSize)
	}
	if got != 512*1024-compressionHeaderSize {
		t.Fatalf("compression default buffer = %d, want a header-aligned 512 KiB wire frame", got)
	}
}

func TestCompressionDefaultRawFrameAlignsToWireBoundary(t *testing.T) {
	payload := make([]byte, compressionDefaultBufSize)
	if _, err := rand.New(rand.NewSource(512)).Read(payload); err != nil {
		t.Fatal(err)
	}
	var encoded countingWriter
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest))
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Close()
	if err := writeCompressionFrame(&encoded, encoder, directionServerToClient, payload); err != nil {
		t.Fatal(err)
	}
	if encoded.Len() != compressionDefaultWireFrameSize {
		t.Fatalf("default raw wire frame = %d bytes, want %d", encoded.Len(), compressionDefaultWireFrameSize)
	}
	if flags := encoded.Bytes()[6]; flags&compressionFlagRaw == 0 {
		t.Fatalf("incompressible default frame flags=%08b, want raw", flags)
	}
}

func TestCompressionBufferSizeHonorsExplicitOverride(t *testing.T) {
	t.Setenv("TUNNEL_PUMP_BUF", "262144")
	options := tunnel.DefaultCopyOptions()
	if got := compressionBufferSize(options); got != 262144 {
		t.Fatalf("compression override buffer = %d, want 262144", got)
	}
}

func TestCompressionFrameUsesOneWrite(t *testing.T) {
	payload := bytes.Repeat([]byte("one acknowledged tunnel write\n"), 4096)
	var encoded countingWriter
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest))
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Close()
	if err := writeCompressionFrame(&encoded, encoder, directionClientToServer, payload); err != nil {
		t.Fatal(err)
	}
	if encoded.writes != 1 {
		t.Fatalf("compression frame writes = %d, want 1", encoded.writes)
	}
	var decoded bytes.Buffer
	if err := decodeCopy(&decoded, bytes.NewReader(encoded.Bytes()), directionClientToServer); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decoded.Bytes(), payload) {
		t.Fatal("single-write compression frame did not round-trip")
	}
}

func TestCompressionFrameHandlesShortWrites(t *testing.T) {
	payload := make([]byte, 32*1024)
	if _, err := rand.New(rand.NewSource(84)).Read(payload); err != nil {
		t.Fatal(err)
	}
	encoded := shortWriter{limit: 127}
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest))
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Close()
	if err := writeCompressionFrame(&encoded, encoder, directionServerToClient, payload); err != nil {
		t.Fatal(err)
	}
	if encoded.writes < 2 {
		t.Fatal("short writer did not exercise writeAll")
	}
	var decoded bytes.Buffer
	if err := decodeCopy(&decoded, bytes.NewReader(encoded.Bytes()), directionServerToClient); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decoded.Bytes(), payload) {
		t.Fatal("short-written compression frame did not round-trip")
	}
}

func TestEncodeCopyCoalescesShortNetworkReads(t *testing.T) {
	sourceWriter, sourceReader := net.Pipe()
	defer sourceWriter.Close()
	defer sourceReader.Close()

	var encoded countingWriter
	encodeDone := make(chan error, 1)
	go func() {
		encodeDone <- encodeCopy(&encoded, sourceReader, directionClientToServer, tunnel.CopyOptions{
			BufferSize:     64 * 1024,
			CoalesceWindow: 100 * time.Millisecond,
		})
	}()

	chunks := [][]byte{
		bytes.Repeat([]byte("a"), 4096),
		bytes.Repeat([]byte("b"), 4096),
		bytes.Repeat([]byte("c"), 4096),
	}
	for _, chunk := range chunks {
		if _, err := sourceWriter.Write(chunk); err != nil {
			t.Fatal(err)
		}
	}
	if err := sourceWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := <-encodeDone; err != nil {
		t.Fatal(err)
	}
	// One coalesced data frame plus one FIN frame.
	if encoded.writes != 2 {
		t.Fatalf("coalesced stream writes = %d, want 2", encoded.writes)
	}

	var decoded bytes.Buffer
	err := decodeCopy(&decoded, bytes.NewReader(encoded.Bytes()), directionClientToServer)
	if !errors.Is(err, io.EOF) {
		t.Fatalf("decodeCopy error = %v, want EOF from FIN", err)
	}
	want := bytes.Join(chunks, nil)
	if !bytes.Equal(decoded.Bytes(), want) {
		t.Fatalf("coalesced payload mismatch: got %d bytes, want %d", decoded.Len(), len(want))
	}
}

func TestCompressionFrameUsesRawFallbackForIncompressiblePayload(t *testing.T) {
	payload := make([]byte, 32*1024)
	if _, err := rand.New(rand.NewSource(42)).Read(payload); err != nil {
		t.Fatal(err)
	}
	var encoded bytes.Buffer
	encoder, err := zstd.NewWriter(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeCompressionFrame(&encoded, encoder, directionServerToClient, payload); err != nil {
		t.Fatal(err)
	}
	_ = encoder.Close()
	if encoded.Bytes()[6]&compressionFlagRaw == 0 {
		t.Fatal("incompressible payload was unexpectedly expanded into a compressed frame")
	}
	var decoded bytes.Buffer
	if err := decodeCopy(&decoded, &encoded, directionServerToClient); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decoded.Bytes(), payload) {
		t.Fatal("raw fallback did not round-trip")
	}
}

func TestCompressionProbeClassifiesPayloads(t *testing.T) {
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest))
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Close()
	pattern := []byte("repeated-http-content\n")
	compressible := bytes.Repeat(pattern, (compressionProbeBytes*2+len(pattern)-1)/len(pattern))
	compressible = compressible[:compressionProbeBytes*2]
	if !compressionProbeLooksCompressible(encoder, compressible) {
		t.Fatal("compressible payload was rejected by probe")
	}
	incompressible := make([]byte, compressionProbeBytes*2)
	if _, err := rand.New(rand.NewSource(123)).Read(incompressible); err != nil {
		t.Fatal(err)
	}
	if compressionProbeLooksCompressible(encoder, incompressible) {
		t.Fatal("incompressible payload passed compression probe")
	}
}

func TestCompressionFrameRejectsWrongDirection(t *testing.T) {
	payload := []byte("direction-bound payload")
	var encoded bytes.Buffer
	encoder, err := zstd.NewWriter(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeCompressionFrame(&encoded, encoder, directionClientToServer, payload); err != nil {
		t.Fatal(err)
	}
	_ = encoder.Close()
	var decoded bytes.Buffer
	err = decodeCopy(&decoded, &encoded, directionServerToClient)
	if err == nil || !bytes.Contains([]byte(err.Error()), []byte("direction mismatch")) {
		t.Fatalf("wrong direction error = %v", err)
	}
}

func TestCompressionFrameRejectsTruncatedHeader(t *testing.T) {
	var decoded bytes.Buffer
	err := decodeCopy(&decoded, bytes.NewReader([]byte("FZST")), directionClientToServer)
	if err == nil || errors.Is(err, io.EOF) {
		t.Fatalf("truncated frame error = %v", err)
	}
}
