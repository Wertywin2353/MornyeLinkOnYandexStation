// mornye-ledviz: low-cost audio spectrum renderer for Yandex Station 2.
// Reads signed 16-bit stereo PCM from a FIFO and writes 89 RGBW pixels to /dev/fb0.
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/signal"
	"syscall"
	"time"
)

const (
	fftSize      = 2048
	sampleRate   = 48000.0
	ledCount     = 89 // index 88 is reserved / not wired on Station 2
	mainLEDCount = 84
	frameBytes   = ledCount * 4
	maxIntensity = 76.0
)

type complex64x struct{ r, i float64 }

func fft(a []complex64x) {
	n := len(a)
	j := 0
	for i := 1; i < n; i++ {
		bit := n >> 1
		for j&bit != 0 {
			j ^= bit
			bit >>= 1
		}
		j ^= bit
		if i < j {
			a[i], a[j] = a[j], a[i]
		}
	}
	for length := 2; length <= n; length <<= 1 {
		half := length >> 1
		angle := -2 * math.Pi / float64(length)
		wr0, wi0 := math.Cos(angle), math.Sin(angle)
		for base := 0; base < n; base += length {
			wr, wi := 1.0, 0.0
			for k := 0; k < half; k++ {
				even := a[base+k]
				odd0 := a[base+k+half]
				odd := complex64x{r: odd0.r*wr - odd0.i*wi, i: odd0.r*wi + odd0.i*wr}
				a[base+k] = complex64x{r: even.r + odd.r, i: even.i + odd.i}
				a[base+k+half] = complex64x{r: even.r - odd.r, i: even.i - odd.i}
				wr, wi = wr*wr0-wi*wi0, wr*wi0+wi*wr0
			}
		}
	}
}

func writeFrame(f *os.File, frame []byte) error {
	if len(frame) != frameBytes {
		return fmt.Errorf("invalid framebuffer size: %d", len(frame))
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return fmt.Errorf("seek framebuffer: %w", err)
	}
	n, err := f.Write(frame)
	if err != nil {
		return fmt.Errorf("write framebuffer: %w", err)
	}
	if n != len(frame) {
		return fmt.Errorf("short framebuffer write: %d/%d", n, len(frame))
	}
	return nil
}

func blankFrame() []byte { return make([]byte, frameBytes) }

func openFramebuffer() (*os.File, error) {
	f, err := os.OpenFile("/dev/fb0", os.O_WRONLY, 0)
	if err != nil {
		return nil, fmt.Errorf("open /dev/fb0: %w", err)
	}
	return f, nil
}

func hsvRGB(h, s, v float64) (byte, byte, byte) {
	h = math.Mod(h, 360)
	if h < 0 {
		h += 360
	}
	c := v * s
	x := c * (1 - math.Abs(math.Mod(h/60, 2)-1))
	m := v - c
	var r, g, b float64
	switch {
	case h < 60:
		r, g, b = c, x, 0
	case h < 120:
		r, g, b = x, c, 0
	case h < 180:
		r, g, b = 0, c, x
	case h < 240:
		r, g, b = 0, x, c
	case h < 300:
		r, g, b = x, 0, c
	default:
		r, g, b = c, 0, x
	}
	return byte(math.Max(0, math.Min(255, (r+m)*255))), byte(math.Max(0, math.Min(255, (g+m)*255))), byte(math.Max(0, math.Min(255, (b+m)*255)))
}

func renderSpectrum(samples []int16, smooth []float64, frame []byte) {
	if len(samples) < fftSize {
		return
	}
	buf := make([]complex64x, fftSize)
	for i := 0; i < fftSize; i++ {
		// Hann window reduces spectral leakage.
		w := 0.5 - 0.5*math.Cos(2*math.Pi*float64(i)/float64(fftSize-1))
		buf[i].r = float64(samples[i]) / 32768.0 * w
	}
	fft(buf)
	minFreq, maxFreq := 55.0, 16000.0
	for led := 0; led < mainLEDCount; led++ {
		f0 := minFreq * math.Pow(maxFreq/minFreq, float64(led)/float64(mainLEDCount))
		f1 := minFreq * math.Pow(maxFreq/minFreq, float64(led+1)/float64(mainLEDCount))
		k0 := int(f0 * float64(fftSize) / sampleRate)
		k1 := int(f1 * float64(fftSize) / sampleRate)
		if k0 < 1 {
			k0 = 1
		}
		if k1 <= k0 {
			k1 = k0 + 1
		}
		if k1 > fftSize/2 {
			k1 = fftSize / 2
		}
		peak := 0.0
		for k := k0; k < k1; k++ {
			mag := math.Hypot(buf[k].r, buf[k].i) / float64(fftSize)
			if mag > peak {
				peak = mag
			}
		}
		db := 20 * math.Log10(peak+1e-8)
		level := (db + 58) / 43 // -58 dB floor, -15 dB near full scale
		if level < 0 {
			level = 0
		}
		if level > 1 {
			level = 1
		}
		// Fast attack, slower decay.
		if level > smooth[led] {
			smooth[led] += (level - smooth[led]) * 0.62
		} else {
			smooth[led] += (level - smooth[led]) * 0.18
		}
		brightness := smooth[led] * maxIntensity
		hue := 270.0 - 245.0*float64(led)/float64(mainLEDCount-1) // violet -> blue/cyan -> red
		r, g, b := hsvRGB(hue, 0.95, brightness/255.0)
		o := led * 4
		frame[o], frame[o+1], frame[o+2], frame[o+3] = r, g, b, 0
	}
	// Four centre/logo LEDs show the low-frequency beat energy.
	bass := 0.0
	for i := 0; i < 10; i++ {
		if smooth[i] > bass {
			bass = smooth[i]
		}
	}
	for i := 84; i < 88; i++ {
		v := bass * 0.72
		r, g, b := hsvRGB(285, 0.9, v)
		o := i * 4
		frame[o], frame[o+1], frame[o+2], frame[o+3] = r, g, b, 0
	}
	// Reserved, unwired pixel remains dark.
	frame[88*4], frame[88*4+1], frame[88*4+2], frame[88*4+3] = 0, 0, 0, 0
}

func runFIFO(path string) error {
	fb, err := openFramebuffer()
	if err != nil {
		return err
	}
	defer fb.Close()
	fifo, err := os.Open(path) // blocks until GStreamer opens the writer
	if err != nil {
		return fmt.Errorf("open PCM FIFO: %w", err)
	}
	defer fifo.Close()
	defer func() { _ = writeFrame(fb, blankFrame()) }()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(sig)
	pcm := make([]byte, fftSize*2*2) // 2048 stereo frames, S16LE
	samples := make([]int16, fftSize)
	smooth := make([]float64, mainLEDCount)
	frame := blankFrame()
	for {
		readDone := make(chan error, 1)
		go func() { _, e := io.ReadFull(fifo, pcm); readDone <- e }()
		select {
		case <-sig:
			return nil
		case err := <-readDone:
			if err != nil {
				if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
					return nil
				}
				return fmt.Errorf("read PCM: %w", err)
			}
		}
		for i := 0; i < fftSize; i++ {
			l := int16(binary.LittleEndian.Uint16(pcm[i*4 : i*4+2]))
			r := int16(binary.LittleEndian.Uint16(pcm[i*4+2 : i*4+4]))
			samples[i] = int16((int32(l) + int32(r)) / 2)
		}
		renderSpectrum(samples, smooth, frame)
		if err := writeFrame(fb, frame); err != nil {
			return err
		}
	}
}

func runTest() error {
	fb, err := openFramebuffer()
	if err != nil {
		return err
	}
	defer fb.Close()
	defer writeFrame(fb, blankFrame())
	frame := blankFrame()
	for i := 0; i < mainLEDCount; i++ {
		h := 270.0 - 245.0*float64(i)/float64(mainLEDCount-1)
		r, g, b := hsvRGB(h, 0.95, 0.24)
		o := i * 4
		frame[o], frame[o+1], frame[o+2], frame[o+3] = r, g, b, 0
	}
	for i := 84; i < 88; i++ {
		frame[i*4], frame[i*4+1], frame[i*4+2] = 45, 15, 60
	}
	if err := writeFrame(fb, frame); err != nil {
		return err
	}
	time.Sleep(2 * time.Second)
	return nil
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println("mornye-ledviz 0.3.0")
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "--test" {
		if err := runTest(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println("LED framebuffer test completed.")
		return
	}
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: mornye-ledviz FIFO | --test")
		os.Exit(2)
	}
	if err := runFIFO(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
