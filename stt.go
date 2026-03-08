package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// transcribeResponse matches the JSON shape from the STT service.
type transcribeResponse struct {
	Text  string `json:"text,omitempty"`
	Error string `json:"error,omitempty"`
}

// transcribeAudio POSTs an audio file to the STT service and returns the transcription text.
func transcribeAudio(sttURL, filePath string) (string, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return "", fmt.Errorf("open audio file: %w", err)
	}
	defer f.Close()

	// Build multipart form body
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	part, err := w.CreateFormFile("file", filepath.Base(filePath))
	if err != nil {
		return "", fmt.Errorf("create form file: %w", err)
	}
	if _, err := io.Copy(part, f); err != nil {
		return "", fmt.Errorf("copy audio data: %w", err)
	}
	w.Close()

	req, err := http.NewRequest(http.MethodPost, sttURL, &buf)
	if err != nil {
		return "", fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", w.FormDataContentType())

	client := &http.Client{Timeout: 5 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("STT request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read STT response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("STT returned %d: %s", resp.StatusCode, string(body))
	}

	var result transcribeResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return "", fmt.Errorf("parse STT response: %w", err)
	}

	if result.Error != "" {
		return "", fmt.Errorf("STT error: %s", result.Error)
	}

	return result.Text, nil
}

// concatAudioFiles joins multiple audio files into a single WAV using ffmpeg's
// concat demuxer. Returns the path to the combined file. Caller is responsible
// for cleaning up both the output file and the input chunks.
func concatAudioFiles(paths []string, outPath string) error {
	// Build ffmpeg concat file list
	var list strings.Builder
	for _, p := range paths {
		fmt.Fprintf(&list, "file '%s'\n", p)
	}

	listPath := outPath + ".txt"
	if err := os.WriteFile(listPath, []byte(list.String()), 0644); err != nil {
		return fmt.Errorf("write concat list: %w", err)
	}
	defer os.Remove(listPath)

	cmd := exec.Command("ffmpeg", "-y", "-f", "concat", "-safe", "0",
		"-i", listPath, "-c", "copy", outPath)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ffmpeg concat: %w\n%s", err, string(out))
	}
	return nil
}
