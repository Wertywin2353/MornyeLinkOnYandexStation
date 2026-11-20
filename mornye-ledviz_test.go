package main

import "testing"

func TestRenderSpectrumFrame(t *testing.T) {
	samples := make([]int16, fftSize)
	for i := range samples {
		samples[i] = 0
	}
	frame := blankFrame()
	smooth := make([]float64, mainLEDCount)
	renderSpectrum(samples, smooth, frame)
	if len(frame) != frameBytes {
		t.Fatalf("frame length = %d, want %d", len(frame), frameBytes)
	}
	if frame[88*4] != 0 || frame[88*4+1] != 0 || frame[88*4+2] != 0 || frame[88*4+3] != 0 {
		t.Fatalf("reserved framebuffer pixel 88 must remain zero")
	}
}
