import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    @ObservedObject var ttsService: TextToSpeechService
    @State private var isDragging: Bool = false
    
    var body: some View {
        VStack(spacing: 8) {
            // Progress slider
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { ttsService.currentTime },
                        set: { newValue in
                            if !isDragging {
                                ttsService.seek(to: newValue)
                            }
                        }
                    ),
                    in: 0...max(ttsService.duration, 0.1),
                    onEditingChanged: { editing in
                        isDragging = editing
                        if !editing {
                            ttsService.seek(to: ttsService.currentTime)
                        }
                    }
                )
                .disabled(ttsService.duration == 0)
                
                HStack {
                    Text(formatTime(ttsService.currentTime))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(ttsService.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Controls
            HStack(spacing: 16) {
                // Rewind button
                Button(action: {
                    let newTime = max(0, ttsService.currentTime - 10)
                    ttsService.seek(to: newTime)
                }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 16))
                }
                .disabled(ttsService.duration == 0)
                .buttonStyle(.plain)
                
                // Play/Pause button
                Button(action: {
                    if ttsService.isPlaying {
                        ttsService.pause()
                    } else {
                        do {
                            try ttsService.play()
                        } catch {
                            print("Playback error: \(error)")
                        }
                    }
                }) {
                    Image(systemName: ttsService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.blue)
                }
                .disabled(ttsService.duration == 0)
                .buttonStyle(.plain)
                
                // Forward button
                Button(action: {
                    let newTime = min(ttsService.duration, ttsService.currentTime + 10)
                    ttsService.seek(to: newTime)
                }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 16))
                }
                .disabled(ttsService.duration == 0)
                .buttonStyle(.plain)
                
                Spacer()
                
                // Speed control
                Menu {
                    Button("0.5x") {
                        ttsService.setPlaybackRate(0.5)
                    }
                    Button("0.75x") {
                        ttsService.setPlaybackRate(0.75)
                    }
                    Button("1.0x") {
                        ttsService.setPlaybackRate(1.0)
                    }
                    Button("1.25x") {
                        ttsService.setPlaybackRate(1.25)
                    }
                    Button("1.5x") {
                        ttsService.setPlaybackRate(1.5)
                    }
                    Button("2.0x") {
                        ttsService.setPlaybackRate(2.0)
                    }
                } label: {
                    HStack {
                        Image(systemName: "speedometer")
                            .font(.system(size: 14))
                        Text(String(format: "%.2fx", ttsService.playbackRate))
                            .font(.caption)
                    }
                }
                .disabled(ttsService.duration == 0)
                
                // Stop button
                Button(action: {
                    ttsService.stopPlayback()
                }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.red)
                }
                .disabled(!ttsService.isPlaying && ttsService.currentTime == 0)
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

