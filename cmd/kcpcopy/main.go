package main

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	kcp "github.com/xtaci/kcp-go/v5"
)

const (
	protocolMagic = "FKCPY001"
	bufferBytes   = 16 * 1024 * 1024
	copyBuffer    = 1024 * 1024
)

type options struct {
	mode          string
	address       string
	destination   string
	keyHex        string
	sendWindow    int
	receiveWindow int
	timeout       time.Duration
}

type sourceFile struct {
	path string
	name string
	size uint64
	sum  [sha256.Size]byte
}

func main() {
	var opts options
	flag.StringVar(&opts.mode, "mode", "", "send or receive")
	flag.StringVar(&opts.address, "address", "", "remote address for send or listen address for receive")
	flag.StringVar(&opts.destination, "destination", "", "destination directory for receive")
	flag.StringVar(&opts.keyHex, "key-hex", "", "32-byte AES key encoded as hexadecimal")
	flag.IntVar(&opts.sendWindow, "send-window", 1536, "KCP send window")
	flag.IntVar(&opts.receiveWindow, "receive-window", 6144, "KCP receive window")
	flag.DurationVar(&opts.timeout, "timeout", 30*time.Minute, "session deadline")
	flag.Parse()
	if err := run(opts, flag.Args()); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(opts options, paths []string) error {
	if opts.address == "" {
		return errors.New("address is required")
	}
	key, err := hex.DecodeString(opts.keyHex)
	if err != nil || len(key) != 32 {
		return errors.New("key-hex must encode exactly 32 bytes")
	}
	crypt, err := kcp.NewAESBlockCrypt(key)
	if err != nil {
		return fmt.Errorf("create KCP encryption: %w", err)
	}
	switch opts.mode {
	case "send":
		if len(paths) == 0 {
			return errors.New("at least one source file is required")
		}
		return send(opts, crypt, paths)
	case "receive":
		if opts.destination == "" {
			return errors.New("destination is required")
		}
		return receive(opts, crypt)
	default:
		return errors.New("mode must be send or receive")
	}
}

func send(opts options, crypt kcp.BlockCrypt, paths []string) error {
	files, total, err := inspectSources(paths)
	if err != nil {
		return err
	}
	started := time.Now()
	session, err := kcp.DialWithOptions(opts.address, crypt, 1, 1)
	if err != nil {
		return fmt.Errorf("dial %s: %w", opts.address, err)
	}
	defer session.Close()
	configureSession(session, opts)
	if err := session.SetDeadline(time.Now().Add(opts.timeout)); err != nil {
		return fmt.Errorf("set deadline: %w", err)
	}
	if err := writeBytes(session, []byte(protocolMagic)); err != nil {
		return err
	}
	if err := binary.Write(session, binary.BigEndian, uint32(len(files))); err != nil {
		return fmt.Errorf("write file count: %w", err)
	}
	buffer := make([]byte, copyBuffer)
	for _, file := range files {
		if err := sendFile(session, file, buffer); err != nil {
			return err
		}
	}
	ack := make([]byte, 2)
	if _, err := io.ReadFull(session, ack); err != nil {
		return fmt.Errorf("read receiver acknowledgement: %w", err)
	}
	if string(ack) != "OK" {
		return fmt.Errorf("receiver returned invalid acknowledgement %q", string(ack))
	}
	seconds := time.Since(started).Seconds()
	fmt.Printf("sent files=%d bytes=%d seconds=%.3f mib_per_second=%.3f\n", len(files), total, seconds, float64(total)/(1024*1024)/seconds)
	return nil
}

func receive(opts options, crypt kcp.BlockCrypt) error {
	if err := os.MkdirAll(opts.destination, 0700); err != nil {
		return fmt.Errorf("create destination: %w", err)
	}
	listener, err := kcp.ListenWithOptions(opts.address, crypt, 1, 1)
	if err != nil {
		return fmt.Errorf("listen %s: %w", opts.address, err)
	}
	defer listener.Close()
	_ = listener.SetReadBuffer(bufferBytes)
	_ = listener.SetWriteBuffer(bufferBytes)
	if err := listener.SetDeadline(time.Now().Add(opts.timeout)); err != nil {
		return fmt.Errorf("set listener deadline: %w", err)
	}
	session, err := listener.AcceptKCP()
	if err != nil {
		return fmt.Errorf("accept KCP session: %w", err)
	}
	defer session.Close()
	configureSession(session, opts)
	if err := session.SetDeadline(time.Now().Add(opts.timeout)); err != nil {
		return fmt.Errorf("set session deadline: %w", err)
	}
	magic := make([]byte, len(protocolMagic))
	if _, err := io.ReadFull(session, magic); err != nil {
		return fmt.Errorf("read protocol magic: %w", err)
	}
	if string(magic) != protocolMagic {
		return errors.New("protocol magic mismatch")
	}
	var count uint32
	if err := binary.Read(session, binary.BigEndian, &count); err != nil {
		return fmt.Errorf("read file count: %w", err)
	}
	if count == 0 || count > 1024 {
		return fmt.Errorf("invalid file count %d", count)
	}
	started := time.Now()
	var total uint64
	buffer := make([]byte, copyBuffer)
	for index := uint32(0); index < count; index++ {
		size, err := receiveFile(session, opts.destination, buffer)
		if err != nil {
			return err
		}
		total += size
	}
	if _, err := session.Write([]byte("OK")); err != nil {
		return fmt.Errorf("write acknowledgement: %w", err)
	}
	// Keep the accepted session alive long enough for the short final response
	// to be delivered and acknowledged before Close tears down the UDP session.
	time.Sleep(2 * time.Second)
	seconds := time.Since(started).Seconds()
	fmt.Printf("received files=%d bytes=%d seconds=%.3f mib_per_second=%.3f\n", count, total, seconds, float64(total)/(1024*1024)/seconds)
	return nil
}

func inspectSources(paths []string) ([]sourceFile, uint64, error) {
	files := make([]sourceFile, 0, len(paths))
	names := make(map[string]struct{}, len(paths))
	var total uint64
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			return nil, 0, fmt.Errorf("stat %s: %w", path, err)
		}
		if !info.Mode().IsRegular() || info.Size() < 0 {
			return nil, 0, fmt.Errorf("source is not a regular file: %s", path)
		}
		name := filepath.Base(path)
		if name == "." || name == string(filepath.Separator) || name == "" {
			return nil, 0, fmt.Errorf("invalid source name: %s", path)
		}
		if _, exists := names[name]; exists {
			return nil, 0, fmt.Errorf("duplicate source name: %s", name)
		}
		names[name] = struct{}{}
		sum, err := hashFile(path)
		if err != nil {
			return nil, 0, err
		}
		file := sourceFile{path: path, name: name, size: uint64(info.Size()), sum: sum}
		files = append(files, file)
		total += file.size
	}
	return files, total, nil
}

func sendFile(writer io.Writer, source sourceFile, buffer []byte) error {
	name := []byte(source.name)
	if len(name) == 0 || len(name) > 65535 {
		return fmt.Errorf("invalid source name length: %s", source.name)
	}
	if err := binary.Write(writer, binary.BigEndian, uint16(len(name))); err != nil {
		return fmt.Errorf("write name length: %w", err)
	}
	if err := writeBytes(writer, name); err != nil {
		return err
	}
	if err := binary.Write(writer, binary.BigEndian, source.size); err != nil {
		return fmt.Errorf("write size for %s: %w", source.name, err)
	}
	if err := writeBytes(writer, source.sum[:]); err != nil {
		return err
	}
	file, err := os.Open(source.path)
	if err != nil {
		return fmt.Errorf("open %s: %w", source.path, err)
	}
	written, err := io.CopyBuffer(writer, io.LimitReader(file, int64(source.size)), buffer)
	closeErr := file.Close()
	if err != nil {
		return fmt.Errorf("send %s: %w", source.name, err)
	}
	if closeErr != nil {
		return fmt.Errorf("close %s: %w", source.name, closeErr)
	}
	if uint64(written) != source.size {
		return fmt.Errorf("short send for %s: got %d want %d", source.name, written, source.size)
	}
	return nil
}

func receiveFile(reader io.Reader, destination string, buffer []byte) (uint64, error) {
	var nameLength uint16
	if err := binary.Read(reader, binary.BigEndian, &nameLength); err != nil {
		return 0, fmt.Errorf("read name length: %w", err)
	}
	if nameLength == 0 {
		return 0, errors.New("empty file name")
	}
	nameBytes := make([]byte, int(nameLength))
	if _, err := io.ReadFull(reader, nameBytes); err != nil {
		return 0, fmt.Errorf("read file name: %w", err)
	}
	name := string(nameBytes)
	if filepath.Base(name) != name || name == "." || name == ".." {
		return 0, fmt.Errorf("unsafe file name %q", name)
	}
	var size uint64
	if err := binary.Read(reader, binary.BigEndian, &size); err != nil {
		return 0, fmt.Errorf("read size for %s: %w", name, err)
	}
	var expected [sha256.Size]byte
	if _, err := io.ReadFull(reader, expected[:]); err != nil {
		return 0, fmt.Errorf("read checksum for %s: %w", name, err)
	}
	finalPath := filepath.Join(destination, name)
	temporaryPath := finalPath + ".partial"
	file, err := os.OpenFile(temporaryPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return 0, fmt.Errorf("create %s: %w", temporaryPath, err)
	}
	hasher := sha256.New()
	written, copyErr := io.CopyBuffer(io.MultiWriter(file, hasher), io.LimitReader(reader, int64(size)), buffer)
	closeErr := file.Close()
	if copyErr != nil {
		_ = os.Remove(temporaryPath)
		return 0, fmt.Errorf("receive %s: %w", name, copyErr)
	}
	if closeErr != nil {
		_ = os.Remove(temporaryPath)
		return 0, fmt.Errorf("close %s: %w", name, closeErr)
	}
	if uint64(written) != size {
		_ = os.Remove(temporaryPath)
		return 0, fmt.Errorf("short receive for %s: got %d want %d", name, written, size)
	}
	actual := hasher.Sum(nil)
	if !equalChecksum(actual, expected[:]) {
		_ = os.Remove(temporaryPath)
		return 0, fmt.Errorf("checksum mismatch for %s", name)
	}
	if err := os.Rename(temporaryPath, finalPath); err != nil {
		_ = os.Remove(temporaryPath)
		return 0, fmt.Errorf("publish %s: %w", name, err)
	}
	return size, nil
}

func configureSession(session *kcp.UDPSession, opts options) {
	session.SetStreamMode(true)
	session.SetACKNoDelay(true)
	session.SetNoDelay(1, 10, 2, 1)
	session.SetMtu(1400)
	session.SetWindowSize(opts.sendWindow, opts.receiveWindow)
	_ = session.SetReadBuffer(bufferBytes)
	_ = session.SetWriteBuffer(bufferBytes)
}

func hashFile(path string) ([sha256.Size]byte, error) {
	var result [sha256.Size]byte
	file, err := os.Open(path)
	if err != nil {
		return result, fmt.Errorf("open %s for checksum: %w", path, err)
	}
	defer file.Close()
	hasher := sha256.New()
	if _, err := io.CopyBuffer(hasher, file, make([]byte, copyBuffer)); err != nil {
		return result, fmt.Errorf("checksum %s: %w", path, err)
	}
	copy(result[:], hasher.Sum(nil))
	return result, nil
}

func writeBytes(writer io.Writer, value []byte) error {
	for len(value) > 0 {
		written, err := writer.Write(value)
		if err != nil {
			return fmt.Errorf("write protocol data: %w", err)
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		value = value[written:]
	}
	return nil
}

func equalChecksum(left, right []byte) bool {
	if len(left) != len(right) {
		return false
	}
	var different byte
	for index := range left {
		different |= left[index] ^ right[index]
	}
	return different == 0
}
