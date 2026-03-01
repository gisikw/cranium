package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
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
