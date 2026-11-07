//
//  Player.swift
//  Waze
//
//  AVPlayer with FairPlay: the key session asks the app for each key, the app makes the SPC with
//  Disney's certificate, posts it to the license server, and hands back the CKC. Media keys come
//  through MPRemoteCommandCenter.
//

import AVFoundation
import MediaPlayer
import Combine

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var current: Item?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published var error: String?

    private let client: DisneyClient
    private let keySession = AVContentKeySession(keySystem: .fairPlayStreaming)
    private let keys: KeyDelegate
    private var observers: [NSKeyValueObservation] = []

    init(client: DisneyClient) {
        self.client = client
        keys = KeyDelegate(client: client)
        keySession.setDelegate(keys, queue: DispatchQueue(label: "waze.fairplay"))
        observers = [
            player.observe(\.rate, options: .new) { [weak self] player, _ in
                MainActor.assumeIsolated {
                    self?.isPlaying = player.rate > 0
                    self?.updateNowPlayingInfo()
                }
            },
        ]
        installRemoteCommands()
    }

    func play(_ item: Item) {
        guard let action = item.play else { return }
        current = item
        isLoading = true
        error = nil
        Task {
            do {
                let playback = try await client.playback(resourceId: action.resourceId)
                let certificate = try await client.certificate()
                keys.prepare(licenseURL: playback.licenseURL, certificate: certificate)
                let asset = AVURLAsset(url: playback.streamURL)
                keySession.addContentKeyRecipient(asset)
                let playerItem = AVPlayerItem(asset: asset)
                player.replaceCurrentItem(with: playerItem)
                if playback.resume > 0 {
                    await player.seek(to: CMTime(seconds: playback.resume, preferredTimescale: 1000))
                }
                player.play()
            } catch {
                self.error = error.localizedDescription
                current = nil
            }
            isLoading = false
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        updateNowPlayingInfo()
    }

    func playPause() {
        isPlaying ? player.pause() : player.play()
    }

    func skip(_ seconds: Double) {
        let target = CMTimeAdd(player.currentTime(), CMTime(seconds: seconds, preferredTimescale: 1000))
        player.seek(to: CMTimeMaximum(target, .zero))
    }

    // MARK: Media keys

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.playPause(); return .success }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.skip(10); return .success }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-10); return .success }
    }

    /// The system only routes media keys to an app that is "now playing", so say so.
    private func updateNowPlayingInfo() {
        let info = MPNowPlayingInfoCenter.default()
        guard let current else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.subtitle ?? "Disney+"]
        info.playbackState = isPlaying ? .playing : .paused
    }
}

/// Answers AVContentKeySession's key requests. Key URIs look like "skd://<base64 json>"; Disney's
/// license server wants that base64 part (the URI's host) as the content identifier.
private final class KeyDelegate: NSObject, AVContentKeySessionDelegate {
    private let client: DisneyClient
    private var licenseURL: URL?
    private var certificate: Data?

    init(client: DisneyClient) { self.client = client }

    func prepare(licenseURL: URL, certificate: Data) {
        self.licenseURL = licenseURL
        self.certificate = certificate
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        handle(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        handle(keyRequest)
    }

    private func handle(_ keyRequest: AVContentKeyRequest) {
        guard let identifier = keyRequest.identifier as? String, let licenseURL, let certificate else {
            keyRequest.processContentKeyResponseError(DisneyError.badResponse("key request"))
            return
        }
        let contentId = identifier.replacingOccurrences(of: "skd://", with: "")
        keyRequest.makeStreamingContentKeyRequestData(forApp: certificate, contentIdentifier: Data(contentId.utf8),
                                                      options: [AVContentKeyRequestProtocolVersionsKey: [1]]) { spc, error in
            guard let spc else {
                keyRequest.processContentKeyResponseError(error ?? DisneyError.badResponse("SPC"))
                return
            }
            Task {
                do {
                    let ckc = try await self.client.license(licenseURL, spc: spc)
                    keyRequest.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
                } catch {
                    keyRequest.processContentKeyResponseError(error)
                }
            }
        }
    }
}
