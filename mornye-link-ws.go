package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	mathrand "math/rand"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	defaultConfig     = "/data/local/etc/mornye-link.json"
	defaultCert       = "/data/local/etc/mornye-link-cert.pem"
	defaultLog        = "/tmp/mornye-link-ws.log"
	deviceName        = "Yandex Station 2"
	platform          = "linux"
	clientVersion     = "station2-link-player/0.3.1"
	playerScript      = "/data/local/tmp/mornye-station2.sh"
	playerPIDFile     = "/tmp/mornye-station2-wrapper.pid"
	playerPosFile     = "/tmp/mornye-station2-position"
	playerRepeatFile  = "/data/local/etc/mornye-station2-repeat"
	playerShuffleFile = "/data/local/etc/mornye-station2-shuffle"
	playerVolumeFile  = "/data/local/etc/mornye-station2-volume"
	playerRestartFile = "/tmp/mornye-station2-track-restart"
	wsGUID            = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	maxFrameSize      = 4 << 20
)

type Config struct {
	Server      string `json:"server"`
	Fingerprint string `json:"fingerprint"`
	ServerID    string `json:"serverId"`
	DeviceID    string `json:"deviceId"`
	APIKey      string `json:"apiKey"`
}

type logger struct{ f *os.File }

func (l logger) printf(format string, args ...any) {
	line := time.Now().Format("2006-01-02 15:04:05") + " " + fmt.Sprintf(format, args...) + "\n"
	// The bridge redirects stdout/stderr to the same log file. Writing to both
	// l.f and stdout duplicated every entry, so keep the daemon log single-copy.
	_, _ = io.WriteString(l.f, line)
}

func loadConfig(path string) (Config, *url.URL, error) {
	var c Config
	b, err := os.ReadFile(path)
	if err != nil {
		return c, nil, fmt.Errorf("read config: %w", err)
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return c, nil, fmt.Errorf("parse config: %w", err)
	}
	if c.DeviceID == "" || c.APIKey == "" || c.Fingerprint == "" || c.Server == "" {
		return c, nil, errors.New("config is missing server, fingerprint, deviceId or apiKey")
	}
	if len(c.Fingerprint) != 64 {
		return c, nil, errors.New("config fingerprint is not a SHA-256 hex value")
	}
	u, err := url.Parse(c.Server)
	if err != nil {
		return c, nil, fmt.Errorf("parse server URL: %w", err)
	}
	if u.Scheme != "https" || u.Hostname() == "" {
		return c, nil, errors.New("server must be an https:// URL")
	}
	if u.Port() == "" {
		u.Host = net.JoinHostPort(u.Hostname(), "443")
	}
	return c, u, nil
}

func openPinnedTLS(c Config, u *url.URL, certPath string) (*tls.Conn, error) {
	pemBytes, err := os.ReadFile(certPath)
	if err != nil {
		return nil, fmt.Errorf("read TLS certificate: %w", err)
	}
	pool := x509.NewCertPool()
	if ok := pool.AppendCertsFromPEM(pemBytes); !ok {
		return nil, errors.New("TLS certificate PEM could not be parsed")
	}
	// The Station's server is self-signed. Trust only the exact pinned leaf
	// fingerprint from pairing, while also setting the expected TLS SNI name.
	want, err := hex.DecodeString(strings.ToLower(c.Fingerprint))
	if err != nil {
		return nil, fmt.Errorf("decode fingerprint: %w", err)
	}
	addr := u.Host
	if !strings.Contains(addr, ":") {
		addr = net.JoinHostPort(u.Hostname(), "443")
	}
	raw, err := net.DialTimeout("tcp", addr, 8*time.Second)
	if err != nil {
		return nil, fmt.Errorf("TCP connect %s: %w", addr, err)
	}
	tlsConn := tls.Client(raw, &tls.Config{
		ServerName:         "mornye.local",
		MinVersion:         tls.VersionTLS12,
		InsecureSkipVerify: true, // exact certificate pin checked below
		VerifyConnection: func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 {
				return errors.New("server did not provide a certificate")
			}
			sum := sha256.Sum256(cs.PeerCertificates[0].Raw)
			if !equalBytes(sum[:], want) {
				return fmt.Errorf("TLS certificate fingerprint mismatch: %x", sum)
			}
			return nil
		},
	})
	_ = tlsConn.SetDeadline(time.Now().Add(12 * time.Second))
	if err := tlsConn.Handshake(); err != nil {
		raw.Close()
		return nil, fmt.Errorf("TLS handshake: %w", err)
	}
	_ = tlsConn.SetDeadline(time.Time{})
	return tlsConn, nil
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var v byte
	for i := range a {
		v |= a[i] ^ b[i]
	}
	return v == 0
}

// websocketAccept computes the RFC 6455 Sec-WebSocket-Accept value.
func websocketAccept(key string) string {
	h := sha1.Sum([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(h[:])
}

func websocketConnect(c Config, u *url.URL, certPath string, log logger) (*tls.Conn, *bufio.Reader, error) {
	conn, err := openPinnedTLS(c, u, certPath)
	if err != nil {
		return nil, nil, err
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		conn.Close()
		return nil, nil, err
	}
	key := base64.StdEncoding.EncodeToString(nonce[:])
	port := u.Port()
	if port == "" {
		port = "443"
	}
	hostHeader := "mornye.local:" + port
	request := "GET /mornye/v1/ws HTTP/1.1\r\n" +
		"Host: " + hostHeader + "\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\n" +
		"Authorization: Bearer " + c.APIKey + "\r\n" +
		"User-Agent: " + clientVersion + "\r\n\r\n"
	if _, err := io.WriteString(conn, request); err != nil {
		conn.Close()
		return nil, nil, fmt.Errorf("write websocket request: %w", err)
	}
	reader := bufio.NewReader(conn)
	_ = conn.SetReadDeadline(time.Now().Add(12 * time.Second))
	status, err := reader.ReadString('\n')
	if err != nil {
		conn.Close()
		return nil, nil, fmt.Errorf("read websocket status: %w", err)
	}
	if !strings.Contains(status, " 101 ") {
		var headers strings.Builder
		for i := 0; i < 40; i++ {
			line, e := reader.ReadString('\n')
			if e != nil {
				break
			}
			headers.WriteString(line)
			if line == "\r\n" {
				break
			}
		}
		conn.Close()
		return nil, nil, fmt.Errorf("websocket upgrade rejected: %s%s", strings.TrimSpace(status), headers.String())
	}
	accept := ""
	for i := 0; i < 40; i++ {
		line, e := reader.ReadString('\n')
		if e != nil {
			conn.Close()
			return nil, nil, fmt.Errorf("read websocket headers: %w", e)
		}
		if line == "\r\n" {
			break
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) == 2 && strings.EqualFold(strings.TrimSpace(parts[0]), "Sec-WebSocket-Accept") {
			accept = strings.TrimSpace(parts[1])
		}
	}
	expected := websocketAccept(key)
	if accept != expected {
		conn.Close()
		return nil, nil, errors.New("invalid Sec-WebSocket-Accept from server")
	}
	_ = conn.SetReadDeadline(time.Time{})
	log.printf("WebSocket TLS установлен; HTTP upgrade принят.")
	return conn, reader, nil
}

func writeFrame(w io.Writer, opcode byte, payload []byte) error {
	if len(payload) > maxFrameSize {
		return errors.New("outgoing websocket frame too large")
	}
	var header []byte
	header = append(header, 0x80|(opcode&0x0f)) // FIN + opcode
	switch n := len(payload); {
	case n < 126:
		header = append(header, byte(0x80|n))
	case n <= 65535:
		header = append(header, 0x80|126, byte(n>>8), byte(n))
	default:
		header = append(header, 0x80|127)
		for shift := 56; shift >= 0; shift -= 8 {
			header = append(header, byte(uint64(n)>>uint(shift)))
		}
	}
	var mask [4]byte
	if _, err := rand.Read(mask[:]); err != nil {
		return err
	}
	header = append(header, mask[:]...)
	masked := make([]byte, len(payload))
	for i, b := range payload {
		masked[i] = b ^ mask[i%4]
	}
	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err := w.Write(masked)
	return err
}

type frame struct {
	fin     bool
	opcode  byte
	payload []byte
}

func readFrame(r *bufio.Reader) (frame, error) {
	var f frame
	b0, err := r.ReadByte()
	if err != nil {
		return f, err
	}
	b1, err := r.ReadByte()
	if err != nil {
		return f, err
	}
	if b0&0x70 != 0 {
		return f, errors.New("unsupported websocket RSV bits")
	}
	f.fin = b0&0x80 != 0
	f.opcode = b0 & 0x0f
	length := uint64(b1 & 0x7f)
	if length == 126 {
		var x [2]byte
		if _, err = io.ReadFull(r, x[:]); err != nil {
			return f, err
		}
		length = uint64(x[0])<<8 | uint64(x[1])
	}
	if length == 127 {
		var x [8]byte
		if _, err = io.ReadFull(r, x[:]); err != nil {
			return f, err
		}
		length = 0
		for _, b := range x {
			length = length<<8 | uint64(b)
		}
	}
	if length > maxFrameSize {
		return f, fmt.Errorf("websocket frame too large: %d", length)
	}
	masked := b1&0x80 != 0
	var mask [4]byte
	if masked {
		if _, err = io.ReadFull(r, mask[:]); err != nil {
			return f, err
		}
	}
	f.payload = make([]byte, int(length))
	if _, err = io.ReadFull(r, f.payload); err != nil {
		return f, err
	}
	if masked {
		for i := range f.payload {
			f.payload[i] ^= mask[i%4]
		}
	}
	return f, nil
}

type stationTrack struct {
	SongID     string `json:"songId"`
	Title      string `json:"title"`
	Artist     string `json:"artist"`
	DurationMs int64  `json:"durationMs"`
}

type playQueueArgs struct {
	Queue      []json.RawMessage `json:"queue"`
	Index      int               `json:"index"`
	PositionMs int64             `json:"positionMs"`
	Playing    *bool             `json:"playing"`
	AutoMix    bool              `json:"autoMix"`
	Autoplay   bool              `json:"autoplay"`
	Shuffle    *bool             `json:"shuffle"`
	Repeat     string            `json:"repeat"`
	Volume     *float64          `json:"volume"`
}

type commandEnvelope struct {
	Type   string          `json:"type"`
	Action string          `json:"action"`
	Args   json.RawMessage `json:"args"`
}

type playerRuntime struct {
	queue          []json.RawMessage
	tracks         []stationTrack
	originalQueue  []json.RawMessage
	originalTracks []stationTrack
	baseIndex      int
	index          int
	active         bool
	playing        bool
	autoMix        bool
	autoplay       bool
	shuffle        bool
	repeat         string
	volume         float64
	trackStarted   time.Time
	pausedAt       time.Time
	pausedTotal    time.Duration
	lastPositionMs int64
	restartMarker  string
}

func newPlayerRuntime() *playerRuntime {
	p := &playerRuntime{repeat: "none", volume: 0.5}
	if b, err := os.ReadFile(playerRepeatFile); err == nil {
		mode := strings.ToLower(strings.TrimSpace(string(b)))
		if mode == "one" || mode == "all" {
			p.repeat = mode
		}
	}
	if b, err := os.ReadFile(playerShuffleFile); err == nil {
		mode := strings.ToLower(strings.TrimSpace(string(b)))
		p.shuffle = mode == "on" || mode == "true" || mode == "1"
	}
	if b, err := os.ReadFile(playerVolumeFile); err == nil {
		if n, err := strconv.ParseFloat(strings.TrimSpace(string(b)), 64); err == nil {
			if n > 1 {
				n /= 100
			}
			p.volume = clampVolume(n)
		}
	}
	if b, err := os.ReadFile(playerRestartFile); err == nil {
		p.restartMarker = strings.TrimSpace(string(b))
	}
	return p
}

func (p *playerRuntime) currentRawTrack() json.RawMessage {
	if p.index < 0 || p.index >= len(p.queue) {
		return json.RawMessage("null")
	}
	return p.queue[p.index]
}

func (p *playerRuntime) refresh() {
	if !p.active {
		return
	}
	if b, err := os.ReadFile(playerRestartFile); err == nil {
		marker := strings.TrimSpace(string(b))
		if marker != "" && marker != p.restartMarker {
			p.restartMarker = marker
			p.trackStarted = time.Now()
			p.lastPositionMs = 0
			p.pausedTotal = 0
			if !p.pausedAt.IsZero() {
				p.pausedAt = time.Now()
			}
		}
	}
	if b, err := os.ReadFile(playerPosFile); err == nil {
		if n, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && n > 0 {
			newIndex := p.baseIndex + n - 1
			if newIndex >= 0 && newIndex < len(p.queue) && newIndex != p.index {
				p.index = newIndex
				p.trackStarted = time.Now()
				p.pausedAt = time.Time{}
				p.pausedTotal = 0
				p.lastPositionMs = 0
			}
		}
	}
	if !playerWrapperAlive() {
		p.active = false
		p.playing = false
		return
	}
	p.lastPositionMs = p.positionMs()
}

func (p *playerRuntime) positionMs() int64 {
	if !p.active {
		return p.lastPositionMs
	}
	if p.trackStarted.IsZero() {
		return p.lastPositionMs
	}
	end := time.Now()
	if !p.pausedAt.IsZero() {
		end = p.pausedAt
	}
	elapsed := end.Sub(p.trackStarted) - p.pausedTotal
	if elapsed < 0 {
		return 0
	}
	return elapsed.Milliseconds()
}

func playerWrapperAlive() bool {
	b, err := os.ReadFile(playerPIDFile)
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || pid <= 1 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

func runPlayerScript(args ...string) error {
	if _, err := os.Stat(playerScript); err != nil {
		return fmt.Errorf("не найден плеер %s: %w", playerScript, err)
	}
	cmd := exec.Command("sh", append([]string{playerScript}, args...)...)
	output, err := cmd.CombinedOutput()
	text := strings.TrimSpace(string(output))
	if text != "" {
		for _, line := range strings.Split(text, "\n") {
			loggerLine := strings.TrimSpace(line)
			if loggerLine != "" {
				fmt.Printf("PLAYER: %s\n", loggerLine)
			}
		}
	}
	if err != nil {
		return fmt.Errorf("команда плеера %q завершилась ошибкой: %w (%s)", strings.Join(args, " "), err, text)
	}
	return nil
}

var stationSongID = regexp.MustCompile(`^d:link_[0-9a-fA-F]{64}$`)

func cloneRawQueue(in []json.RawMessage) []json.RawMessage {
	out := make([]json.RawMessage, len(in))
	for i := range in {
		out[i] = append(json.RawMessage(nil), in[i]...)
	}
	return out
}

func cloneTracks(in []stationTrack) []stationTrack {
	out := make([]stationTrack, len(in))
	copy(out, in)
	return out
}

func shuffleTail(queue []json.RawMessage, tracks []stationTrack, from int) {
	if from < 0 {
		from = 0
	}
	if from >= len(queue)-1 {
		return
	}
	r := mathrand.New(mathrand.NewSource(time.Now().UnixNano()))
	for i := len(queue) - 1; i > from+1; i-- {
		j := from + 1 + r.Intn(i-from)
		queue[i], queue[j] = queue[j], queue[i]
		tracks[i], tracks[j] = tracks[j], tracks[i]
	}
}

func (p *playerRuntime) queueIDs(from int) []string {
	if from < 0 {
		from = 0
	}
	if from >= len(p.tracks) {
		return nil
	}
	ids := make([]string, 0, len(p.tracks)-from)
	for i := from; i < len(p.tracks); i++ {
		ids = append(ids, p.tracks[i].SongID)
	}
	return ids
}

func clampVolume(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

func parseCommandFloat(raw json.RawMessage, keys ...string) (float64, bool) {
	var direct float64
	if len(raw) > 0 && raw[0] != '{' && json.Unmarshal(raw, &direct) == nil {
		return direct, true
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(raw, &obj) != nil {
		return 0, false
	}
	for _, key := range keys {
		if b, ok := obj[key]; ok {
			if json.Unmarshal(b, &direct) == nil {
				return direct, true
			}
			var nested map[string]json.RawMessage
			if json.Unmarshal(b, &nested) == nil {
				for _, k := range []string{"positionMs", "milliseconds", "value", "volume"} {
					if x, ok := nested[k]; ok && json.Unmarshal(x, &direct) == nil {
						return direct, true
					}
				}
			}
		}
	}
	return 0, false
}

func parseCommandString(raw json.RawMessage, keys ...string) (string, bool) {
	var direct string
	if len(raw) > 0 && raw[0] == '"' && json.Unmarshal(raw, &direct) == nil {
		return direct, true
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(raw, &obj) != nil {
		return "", false
	}
	for _, key := range keys {
		if b, ok := obj[key]; ok && json.Unmarshal(b, &direct) == nil {
			return direct, true
		}
	}
	return "", false
}

func parseCommandBool(raw json.RawMessage, keys ...string) (bool, bool) {
	var direct bool
	if len(raw) > 0 && (raw[0] == 't' || raw[0] == 'f') && json.Unmarshal(raw, &direct) == nil {
		return direct, true
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(raw, &obj) != nil {
		return false, false
	}
	for _, key := range keys {
		if b, ok := obj[key]; ok && json.Unmarshal(b, &direct) == nil {
			return direct, true
		}
	}
	return false, false
}

func (p *playerRuntime) restartAtCurrent(positionMs int64, log logger) error {
	if len(p.tracks) == 0 || p.index < 0 || p.index >= len(p.tracks) {
		return errors.New("нет текущей композиции для перезапуска")
	}
	ids := p.queueIDs(p.index)
	if len(ids) == 0 {
		return errors.New("очередь пуста")
	}
	args := []string{"playfrom", strconv.FormatInt(positionMs, 10)}
	args = append(args, ids...)
	if err := runPlayerScript(args...); err != nil {
		return err
	}
	p.baseIndex = p.index
	p.active = true
	p.trackStarted = time.Now().Add(-time.Duration(positionMs) * time.Millisecond)
	p.lastPositionMs = positionMs
	if !p.pausedAt.IsZero() || !p.playing {
		if err := runPlayerScript("pause"); err != nil {
			return err
		}
		p.pausedAt = time.Now()
		p.playing = false
	} else {
		p.pausedAt = time.Time{}
		p.playing = true
	}
	log.printf("Текущая композиция перезапущена с позиции %d ms.", positionMs)
	return nil
}

func (p *playerRuntime) handleCommand(action string, rawArgs json.RawMessage, log logger) error {
	switch action {
	case "play_queue":
		var args playQueueArgs
		if err := json.Unmarshal(rawArgs, &args); err != nil {
			return fmt.Errorf("не удалось разобрать play_queue.args: %w", err)
		}
		if len(args.Queue) == 0 || len(args.Queue) > 1000 {
			return fmt.Errorf("очередь содержит недопустимое число треков: %d", len(args.Queue))
		}
		if args.Index < 0 || args.Index >= len(args.Queue) {
			return fmt.Errorf("index=%d вне очереди из %d треков", args.Index, len(args.Queue))
		}
		tracks := make([]stationTrack, len(args.Queue))
		for i, raw := range args.Queue {
			if err := json.Unmarshal(raw, &tracks[i]); err != nil {
				return fmt.Errorf("ошибка элемента очереди %d: %w", i, err)
			}
			if !stationSongID.MatchString(tracks[i].SongID) {
				return fmt.Errorf("неподдерживаемый songId в очереди на позиции %d", i)
			}
		}
		originalQueue := cloneRawQueue(args.Queue)
		originalTracks := cloneTracks(tracks)
		queue := cloneRawQueue(args.Queue)
		repeat := strings.ToLower(strings.TrimSpace(args.Repeat))
		if repeat == "" {
			repeat = p.repeat
		}
		if repeat != "one" && repeat != "all" {
			repeat = "none"
		}
		volume := p.volume
		if args.Volume != nil {
			volume = clampVolume(*args.Volume)
		}
		shuffle := p.shuffle
		if args.Shuffle != nil {
			shuffle = *args.Shuffle
		}
		if shuffle {
			shuffleTail(queue, tracks, args.Index)
		}
		ids := make([]string, 0, len(queue)-args.Index)
		for i := args.Index; i < len(tracks); i++ {
			ids = append(ids, tracks[i].SongID)
		}
		if len(ids) == 0 {
			return errors.New("после текущего индекса нет композиций")
		}
		playerArgs := []string{"playfrom", strconv.FormatInt(maxInt64(args.PositionMs, 0), 10)}
		playerArgs = append(playerArgs, ids...)
		if err := runPlayerScript("repeat", repeat); err != nil {
			log.printf("Не удалось заранее установить repeat: %v", err)
		}
		shuffleValue := "off"
		if shuffle {
			shuffleValue = "on"
		}
		if err := runPlayerScript("shuffle", shuffleValue); err != nil {
			log.printf("Не удалось сохранить shuffle: %v", err)
		}
		if err := runPlayerScript("volume", strconv.Itoa(int(volume*100+0.5))); err != nil {
			log.printf("Не удалось заранее установить volume: %v", err)
		}
		if err := runPlayerScript(playerArgs...); err != nil {
			return err
		}
		p.originalQueue = originalQueue
		p.originalTracks = originalTracks
		p.queue = queue
		p.tracks = tracks
		p.baseIndex = args.Index
		p.index = args.Index
		p.restartMarker = ""
		p.active = true
		p.playing = args.Playing == nil || *args.Playing
		p.autoMix = args.AutoMix
		p.autoplay = args.Autoplay
		p.shuffle = shuffle
		p.repeat = repeat
		p.volume = volume
		p.trackStarted = time.Now().Add(-time.Duration(maxInt64(args.PositionMs, 0)) * time.Millisecond)
		p.pausedAt = time.Time{}
		p.pausedTotal = 0
		p.lastPositionMs = maxInt64(args.PositionMs, 0)
		if !p.playing {
			if err := runPlayerScript("pause"); err != nil {
				return err
			}
			p.pausedAt = time.Now()
		}
		log.printf("Команда play_queue выполнена: %s — %s; очередь=%d; index=%d; seek=%d ms; shuffle=%t; repeat=%s.", tracks[p.index].Artist, tracks[p.index].Title, len(tracks), p.index, args.PositionMs, p.shuffle, p.repeat)
		return nil
	case "pause":
		if err := runPlayerScript("pause"); err != nil {
			return err
		}
		if p.pausedAt.IsZero() {
			p.pausedAt = time.Now()
		}
		p.playing = false
		log.printf("Команда pause выполнена.")
		return nil
	case "resume", "play":
		if err := runPlayerScript("resume"); err != nil {
			return err
		}
		if !p.pausedAt.IsZero() {
			p.pausedTotal += time.Since(p.pausedAt)
			p.pausedAt = time.Time{}
		}
		p.playing = true
		log.printf("Команда %s выполнена.", action)
		return nil
	case "toggle":
		if p.playing {
			if err := runPlayerScript("pause"); err != nil {
				return err
			}
			p.pausedAt = time.Now()
			p.playing = false
		} else {
			if err := runPlayerScript("resume"); err != nil {
				return err
			}
			if !p.pausedAt.IsZero() {
				p.pausedTotal += time.Since(p.pausedAt)
				p.pausedAt = time.Time{}
			}
			p.playing = true
		}
		log.printf("Команда toggle выполнена; playing=%t.", p.playing)
		return nil
	case "next":
		if err := runPlayerScript("next"); err != nil {
			return err
		}
		if !p.pausedAt.IsZero() {
			p.pausedTotal += time.Since(p.pausedAt)
			p.pausedAt = time.Time{}
		}
		p.playing = true
		log.printf("Команда next принята.")
		return nil
	case "previous":
		if len(p.queue) == 0 || !p.active {
			return errors.New("очередь не запущена")
		}
		// Conventional previous-track behavior: if the current track has played
		// for more than three seconds, restart it; otherwise go to the prior item.
		prev := p.index
		if p.positionMs() <= 3000 && p.index > 0 {
			prev = p.index - 1
		}
		p.index = prev
		p.baseIndex = prev
		if err := p.restartAtCurrent(0, log); err != nil {
			return err
		}
		log.printf("Команда previous выполнена; index=%d.", prev)
		return nil
	case "seek", "seek_to", "seekTo", "seekToPosition":
		if !p.active {
			return errors.New("плеер не запущен")
		}
		position, ok := parseCommandFloat(rawArgs, "positionMs", "position_ms", "milliseconds", "position", "value", "timeMs", "seconds")
		if !ok {
			return fmt.Errorf("не удалось извлечь позицию из seek args: %s", truncate(string(rawArgs), 300))
		}
		// Mornye reports positions in milliseconds. Accept a seconds-shaped field
		// only when positionMs is absent and the caller explicitly uses "seconds".
		var fields map[string]json.RawMessage
		if json.Unmarshal(rawArgs, &fields) == nil {
			if _, has := fields["positionMs"]; !has {
				if b, ok := fields["seconds"]; ok {
					var sec float64
					if json.Unmarshal(b, &sec) == nil {
						position = sec * 1000
					}
				}
			}
		}
		if position < 0 {
			position = 0
		}
		if p.index >= 0 && p.index < len(p.tracks) && p.tracks[p.index].DurationMs > 0 && position > float64(p.tracks[p.index].DurationMs) {
			position = float64(p.tracks[p.index].DurationMs)
		}
		if err := p.restartAtCurrent(int64(position), log); err != nil {
			return err
		}
		return nil
	case "volume", "set_volume", "setVolume", "volume_changed":
		v, ok := parseCommandFloat(rawArgs, "volume", "value", "level", "percent")
		if !ok {
			return fmt.Errorf("не удалось извлечь громкость из args: %s", truncate(string(rawArgs), 300))
		}
		if v > 1 {
			v = v / 100
		}
		v = clampVolume(v)
		pct := int(v*100 + 0.5)
		position := p.positionMs()
		if err := runPlayerScript("volume", strconv.Itoa(pct), strconv.FormatInt(position, 10)); err != nil {
			return err
		}
		p.volume = v
		log.printf("Громкость станции установлена: %d%%.", pct)
		return nil
	case "repeat", "set_repeat", "set_repeat_mode", "repeat_mode", "setRepeatMode":
		mode, ok := parseCommandString(rawArgs, "repeat", "mode", "value")
		if !ok {
			n, found := parseCommandFloat(rawArgs, "repeat", "mode", "value")
			if found {
				switch int(n) {
				case 1:
					mode = "one"
				case 2:
					mode = "all"
				default:
					mode = "none"
				}
				ok = true
			}
		}
		if !ok {
			return fmt.Errorf("не удалось извлечь repeat mode из args: %s", truncate(string(rawArgs), 300))
		}
		mode = strings.ToLower(strings.TrimSpace(mode))
		if mode != "one" && mode != "all" {
			mode = "none"
		}
		if err := runPlayerScript("repeat", mode); err != nil {
			return err
		}
		p.repeat = mode
		log.printf("Режим повтора: %s.", mode)
		return nil
	case "shuffle", "set_shuffle", "set_shuffle_mode", "shuffle_mode", "setShuffleMode":
		enabled, ok := parseCommandBool(rawArgs, "shuffle", "enabled", "value")
		if !ok {
			var s string
			s, ok = parseCommandString(rawArgs, "mode", "value")
			if ok {
				enabled = strings.EqualFold(s, "shuffle") || strings.EqualFold(s, "on") || strings.EqualFold(s, "true")
			}
		}
		if !ok {
			return fmt.Errorf("не удалось извлечь shuffle из args: %s", truncate(string(rawArgs), 300))
		}
		shuffleValue := "off"
		if enabled {
			shuffleValue = "on"
		}
		if err := runPlayerScript("shuffle", shuffleValue); err != nil {
			log.printf("Не удалось сохранить shuffle: %v", err)
		}
		if enabled != p.shuffle && len(p.tracks) > 1 && p.active {
			pos := p.positionMs()
			currentSong := ""
			if p.index >= 0 && p.index < len(p.tracks) {
				currentSong = p.tracks[p.index].SongID
			}
			if enabled {
				if len(p.originalQueue) == len(p.queue) && len(p.originalTracks) == len(p.tracks) {
					p.queue = cloneRawQueue(p.originalQueue)
					p.tracks = cloneTracks(p.originalTracks)
				}
				cur := findTrack(p.tracks, currentSong)
				if cur >= 0 {
					p.index = cur
				}
				shuffleTail(p.queue, p.tracks, p.index)
			} else if len(p.originalQueue) == len(p.queue) && len(p.originalTracks) == len(p.tracks) {
				p.queue = cloneRawQueue(p.originalQueue)
				p.tracks = cloneTracks(p.originalTracks)
				cur := findTrack(p.tracks, currentSong)
				if cur >= 0 {
					p.index = cur
				}
			}
			p.shuffle = enabled
			if err := p.restartAtCurrent(pos, log); err != nil {
				return err
			}
		} else {
			p.shuffle = enabled
		}
		log.printf("Shuffle=%t.", enabled)
		return nil
	case "play_on_desktop":
		// Reverse hand-off: capture position before stopping, then release the
		// Station output so the desktop can resume locally.
		position := p.positionMs()
		if p.active {
			if err := runPlayerScript("stop"); err != nil {
				log.printf("play_on_desktop: предупреждение при остановке локального плеера: %v", err)
			}
		}
		p.lastPositionMs = position
		p.active = false
		p.playing = false
		log.printf("play_on_desktop: локальное воспроизведение Станции остановлено для возврата на Desktop.")
		return nil
	case "stop":
		if err := runPlayerScript("stop"); err != nil {
			return err
		}
		p.lastPositionMs = p.positionMs()
		p.playing = false
		p.active = false
		log.printf("Команда stop выполнена.")
		return nil
	default:
		return fmt.Errorf("команда %q пока не поддерживается мостом; args=%s", action, truncate(string(rawArgs), 300))
	}
}

func findTrack(tracks []stationTrack, songID string) int {
	for i := range tracks {
		if tracks[i].SongID == songID {
			return i
		}
	}
	return -1
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func (p *playerRuntime) stateMessage() map[string]any {
	p.refresh()
	var duration int64
	if p.index >= 0 && p.index < len(p.tracks) {
		duration = p.tracks[p.index].DurationMs
	}
	position := p.positionMs()
	if duration > 0 && position > duration {
		position = duration
	}
	return map[string]any{
		"type": "player.state",
		"state": map[string]any{
			"autoMix":    p.autoMix,
			"autoplay":   p.autoplay,
			"durationMs": duration,
			"index":      p.index,
			"playing":    p.active && p.playing,
			"positionMs": position,
			"queue":      p.queue,
			"repeat":     p.repeat,
			"shuffle":    p.shuffle,
			"track":      p.currentRawTrack(),
			"updatedMs":  time.Now().UnixMilli(),
			"volume":     p.volume,
		},
	}
}

func (p *playerRuntime) rememberDesktopState(b []byte, log logger) {
	var envelope struct {
		State struct {
			Shuffle *bool    `json:"shuffle"`
			Repeat  string   `json:"repeat"`
			Volume  *float64 `json:"volume"`
		} `json:"state"`
	}
	if json.Unmarshal(b, &envelope) != nil {
		return
	}
	if envelope.State.Shuffle != nil && *envelope.State.Shuffle != p.shuffle {
		value, _ := json.Marshal(map[string]bool{"shuffle": *envelope.State.Shuffle})
		if p.active {
			if err := p.handleCommand("set_shuffle", value, log); err != nil {
				log.printf("Не удалось применить shuffle из player.state: %v", err)
			}
		} else {
			p.shuffle = *envelope.State.Shuffle
		}
	}
	if envelope.State.Repeat != "" && envelope.State.Repeat != p.repeat {
		value, _ := json.Marshal(map[string]string{"repeat": envelope.State.Repeat})
		if p.active {
			if err := p.handleCommand("set_repeat", value, log); err != nil {
				log.printf("Не удалось применить repeat из player.state: %v", err)
			}
		} else {
			mode := strings.ToLower(envelope.State.Repeat)
			if mode == "one" || mode == "all" {
				p.repeat = mode
			} else {
				p.repeat = "none"
			}
		}
	}
	if envelope.State.Volume != nil && *envelope.State.Volume >= 0 && *envelope.State.Volume <= 1 && math.Abs(*envelope.State.Volume-p.volume) > 0.005 {
		value, _ := json.Marshal(map[string]float64{"volume": *envelope.State.Volume})
		if p.active {
			if err := p.handleCommand("set_volume", value, log); err != nil {
				log.printf("Не удалось применить volume из player.state: %v", err)
			}
		} else {
			p.volume = *envelope.State.Volume
		}
	}
}

type readResult struct {
	frame frame
	err   error
}

func runSession(c Config, u *url.URL, cert string, log logger) error {
	conn, reader, err := websocketConnect(c, u, cert, log)
	if err != nil {
		return err
	}
	defer conn.Close()
	hello, _ := json.Marshal(map[string]string{
		"type": "hello", "deviceId": c.DeviceID, "name": deviceName,
		"platform": platform, "appVersion": clientVersion,
	})
	if err := writeFrame(conn, 1, hello); err != nil {
		return fmt.Errorf("send hello: %w", err)
	}
	log.printf("Отправлен hello для устройства %s (%s).", c.DeviceID, deviceName)

	frames := make(chan readResult, 8)
	go func() {
		for {
			f, e := readFrame(reader)
			select {
			case frames <- readResult{frame: f, err: e}:
			case <-time.After(30 * time.Second):
				return
			}
			if e != nil {
				return
			}
		}
	}()
	player := newPlayerRuntime()
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	var fragmented []byte
	var fragOpcode byte
	for {
		select {
		case result := <-frames:
			if result.err != nil {
				return fmt.Errorf("read websocket frame: %w", result.err)
			}
			f := result.frame
			switch f.opcode {
			case 0x1:
				fragmented = append(fragmented[:0], f.payload...)
				fragOpcode = 1
				if f.fin {
					fragmented = append([]byte(nil), f.payload...)
					if err := handleTextMessage(conn, fragmented, player, log); err != nil {
						log.printf("ОШИБКА обработки WS-сообщения: %v", err)
					}
					fragmented = nil
					fragOpcode = 0
				}
			case 0x0:
				if fragOpcode == 1 {
					fragmented = append(fragmented, f.payload...)
					if f.fin {
						if err := handleTextMessage(conn, fragmented, player, log); err != nil {
							log.printf("ОШИБКА обработки WS-сообщения: %v", err)
						}
						fragmented = nil
						fragOpcode = 0
					}
				}
			case 0x8:
				_ = writeFrame(conn, 0x8, f.payload)
				return errors.New("server closed websocket")
			case 0x9:
				if err := writeFrame(conn, 0xA, f.payload); err != nil {
					return fmt.Errorf("pong: %w", err)
				}
			case 0xA:
			}
		case <-ticker.C:
			if player.active {
				state, _ := json.Marshal(player.stateMessage())
				if err := writeFrame(conn, 1, state); err != nil {
					return fmt.Errorf("send player.state: %w", err)
				}
				log.printf("WS -> player.state: playing=%t index=%d position=%d ms.", player.active && player.playing, player.index, player.positionMs())
			}
		}
	}
}

func handleTextMessage(conn *tls.Conn, b []byte, player *playerRuntime, log logger) error {
	logMessage(log, b)
	var message map[string]json.RawMessage
	if err := json.Unmarshal(b, &message); err != nil {
		return fmt.Errorf("invalid JSON frame: %w", err)
	}
	var typ string
	_ = json.Unmarshal(message["type"], &typ)
	if typ == "player.state" {
		// The desktop snapshot also carries shared playback controls. Apply only
		// changed volume/repeat/shuffle preferences; never copy its track/queue
		// over the Station's own state.
		player.rememberDesktopState(b, log)
		return nil
	}
	if typ != "command" {
		return nil
	}
	var command commandEnvelope
	if err := json.Unmarshal(b, &command); err != nil {
		return err
	}
	if command.Action == "" {
		return errors.New("command без action")
	}
	if err := player.handleCommand(command.Action, command.Args, log); err != nil {
		log.printf("Команда %s не выполнена: %v", command.Action, err)
		return err
	}
	state, err := json.Marshal(player.stateMessage())
	if err != nil {
		return err
	}
	if err := writeFrame(conn, 1, state); err != nil {
		return fmt.Errorf("send player.state after %s: %w", command.Action, err)
	}
	log.printf("WS -> player.state отправлен после %s.", command.Action)
	return nil
}

func logMessage(log logger, b []byte) {
	var m map[string]json.RawMessage
	if json.Unmarshal(b, &m) != nil {
		log.printf("WS <- [не-JSON сообщение, %d байт]", len(b))
		return
	}
	var typ, action string
	_ = json.Unmarshal(m["type"], &typ)
	_ = json.Unmarshal(m["action"], &action)
	if typ == "player.state" {
		var envelope struct {
			State struct {
				Index      int               `json:"index"`
				Playing    bool              `json:"playing"`
				PositionMs int64             `json:"positionMs"`
				DurationMs int64             `json:"durationMs"`
				Queue      []json.RawMessage `json:"queue"`
				Track      struct {
					Title  string `json:"title"`
					Artist string `json:"artist"`
				} `json:"track"`
			} `json:"state"`
		}
		if json.Unmarshal(b, &envelope) == nil {
			log.printf("WS <- player.state: %s — %s; playing=%t; index=%d; position=%d/%d ms; queue=%d.", envelope.State.Track.Artist, envelope.State.Track.Title, envelope.State.Playing, envelope.State.Index, envelope.State.PositionMs, envelope.State.DurationMs, len(envelope.State.Queue))
			return
		}
	}
	if typ == "command" {
		var args struct {
			Index int               `json:"index"`
			Queue []json.RawMessage `json:"queue"`
		}
		_ = json.Unmarshal(m["args"], &args)
		log.printf("WS <- command: action=%s; index=%d; queue=%d.", action, args.Index, len(args.Queue))
		return
	}
	if typ == "welcome" {
		var welcome struct {
			Name     string `json:"name"`
			ServerID string `json:"serverId"`
			Protocol int    `json:"protocol"`
		}
		_ = json.Unmarshal(b, &welcome)
		log.printf("WS <- welcome: %s; protocol=%d; serverId=%s.", welcome.Name, welcome.Protocol, welcome.ServerID)
		return
	}
	if typ != "" {
		log.printf("WS <- %s", typ)
		return
	}
	log.printf("WS <- JSON message (%d bytes)", len(b))
}

func main() {
	configPath := defaultConfig
	certPath := defaultCert
	logPath := defaultLog
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--config":
			if i+1 < len(args) {
				i++
				configPath = args[i]
			}
		case "--cert":
			if i+1 < len(args) {
				i++
				certPath = args[i]
			}
		case "--log":
			if i+1 < len(args) {
				i++
				logPath = args[i]
			}
		case "--version":
			fmt.Println(clientVersion)
			return
		default:
			fmt.Fprintf(os.Stderr, "unknown argument: %s\n", args[i])
			os.Exit(2)
		}
	}
	if err := os.MkdirAll(filepath.Dir(logPath), 0700); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if st, err := os.Stat(logPath); err == nil && st.Size() > 1<<20 {
		_ = os.Rename(logPath, logPath+".1")
	}
	lf, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer lf.Close()
	log := logger{lf}
	c, u, err := loadConfig(configPath)
	if err != nil {
		log.printf("ОШИБКА: %v", err)
		os.Exit(1)
	}
	if _, err := os.Stat(certPath); err != nil {
		log.printf("ОШИБКА: %v", err)
		os.Exit(1)
	}
	log.printf("Запуск клиента Mornye Link; сервер %s", u.Host)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	for {
		done := make(chan error, 1)
		go func() { done <- runSession(c, u, certPath, log) }()
		select {
		case s := <-sig:
			log.printf("Получен сигнал %s; остановка.", s)
			return
		case err := <-done:
			log.printf("Соединение закрыто: %v; повтор через 5 секунд.", err)
		}
		select {
		case s := <-sig:
			log.printf("Получен сигнал %s; остановка.", s)
			return
		case <-time.After(5 * time.Second):
		}
	}
}
