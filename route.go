package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"
)

const (
	routeMagic            = "FKRT"
	routeVersion          = 1
	routeHeaderSize       = 20
	routeAckMagic         = "FKRA"
	routeAckMaxBytes      = 4096
	transportTCP     byte = 1
	transportUDP     byte = 2
)

type routeHeader struct {
	ConnectionID uint64
	Transport    byte
	RemotePort   uint16
	Probe        bool
}

type routeAck struct {
	Accepted bool
	Code     byte
	Message  string
}

func encodeRouteHeader(header routeHeader) []byte {
	payload := make([]byte, routeHeaderSize)
	copy(payload[:4], routeMagic)
	payload[4] = routeVersion
	payload[5] = header.Transport
	if header.Probe {
		payload[6] = 1
	}
	binary.BigEndian.PutUint64(payload[8:16], header.ConnectionID)
	binary.BigEndian.PutUint16(payload[16:18], header.RemotePort)
	return payload
}

func decodeRouteHeader(payload []byte) (routeHeader, error) {
	if len(payload) != routeHeaderSize {
		return routeHeader{}, fmt.Errorf("路由头长度无效: %d", len(payload))
	}
	if string(payload[:4]) != routeMagic {
		return routeHeader{}, errors.New("路由头 magic 不匹配")
	}
	if payload[4] != routeVersion {
		return routeHeader{}, fmt.Errorf("不支持的路由头版本 %d", payload[4])
	}
	if payload[6] > 1 || payload[7] != 0 || payload[18] != 0 || payload[19] != 0 {
		return routeHeader{}, errors.New("路由头保留字段非零")
	}
	if payload[5] != transportTCP && payload[5] != transportUDP {
		return routeHeader{}, fmt.Errorf("不支持的传输类型 %d", payload[5])
	}
	return routeHeader{ConnectionID: binary.BigEndian.Uint64(payload[8:16]), Transport: payload[5], RemotePort: binary.BigEndian.Uint16(payload[16:18]), Probe: payload[6] == 1}, nil
}

func writeRouteHeader(stream io.Writer, header routeHeader) error {
	return writeAll(stream, encodeRouteHeader(header))
}

func readRouteHeader(stream io.Reader) (routeHeader, error) {
	payload := make([]byte, routeHeaderSize)
	if _, err := io.ReadFull(stream, payload); err != nil {
		return routeHeader{}, err
	}
	return decodeRouteHeader(payload)
}

func writeRouteAck(stream io.Writer, ack routeAck) error {
	message := []byte(strings.TrimSpace(ack.Message))
	if len(message) > routeAckMaxBytes {
		message = message[:routeAckMaxBytes]
	}
	payload := make([]byte, 9+len(message))
	copy(payload[:4], routeAckMagic)
	payload[4] = routeVersion
	if ack.Accepted {
		payload[5] = 1
	}
	payload[6] = ack.Code
	binary.BigEndian.PutUint16(payload[7:9], uint16(len(message)))
	copy(payload[9:], message)
	return writeAll(stream, payload)
}

func readRouteAck(stream io.Reader) (routeAck, error) {
	prefix := make([]byte, 9)
	if _, err := io.ReadFull(stream, prefix); err != nil {
		return routeAck{}, err
	}
	if string(prefix[:4]) != routeAckMagic {
		return routeAck{}, errors.New("路由响应 magic 不匹配")
	}
	if prefix[4] != routeVersion {
		return routeAck{}, fmt.Errorf("不支持的路由响应版本 %d", prefix[4])
	}
	messageLength := int(binary.BigEndian.Uint16(prefix[7:9]))
	if messageLength > routeAckMaxBytes {
		return routeAck{}, errors.New("路由响应过长")
	}
	message := make([]byte, messageLength)
	if _, err := io.ReadFull(stream, message); err != nil {
		return routeAck{}, err
	}
	return routeAck{Accepted: prefix[5] == 1, Code: prefix[6], Message: string(message)}, nil
}
