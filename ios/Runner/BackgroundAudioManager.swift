import AVFoundation

/// Plays a silent looping audio buffer to keep the app alive in the background
/// while generation is running. Requires UIBackgroundModes: audio in Info.plist.
class BackgroundAudioManager {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?

  func start() {
    guard engine == nil else { return }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, options: .mixWithOthers)
      try session.setActive(true)

      let e = AVAudioEngine()
      let p = AVAudioPlayerNode()
      e.attach(p)

      let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
      buffer.frameLength = 1024
      // All-zero samples = silence

      e.connect(p, to: e.mainMixerNode, format: format)
      try e.start()
      p.scheduleBuffer(buffer, at: nil, options: .loops)
      p.play()

      engine = e
      player = p
    } catch {
      print("[BackgroundAudio] start error: \(error)")
    }
  }

  func stop() {
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    try? AVAudioSession.sharedInstance().setActive(
      false, options: .notifyOthersOnDeactivation
    )
  }
}
