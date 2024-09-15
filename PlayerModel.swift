import AVKit
import Combine
import Observation
import CoreImage
import CoreML
import CoreImage.CIFilterBuiltins

fileprivate let targetSize = CGSize(width: 518, height: 392)

@Observable class PlayerModel {

    private(set) var isPlaying = false
    private(set) var isPlaybackComplete = false
    private(set) var currentItem: Video? = nil
    private(set) var shouldProposeNextVideo = false
    private var player = AVPlayer()

    private var playerViewController: AVPlayerViewController? = nil
    private var playerViewControllerDelegate: AVPlayerViewControllerDelegate? = nil

    private(set) var shouldAutoPlay = true

    private var coordinator: VideoWatchingCoordinator! = nil

    private var timeObserver: Any? = nil
    private var subscriptions = Set<AnyCancellable>()

		private var model: DepthAnythingV2SmallF16?
		private let context = CIContext()
		private let inputPixelBuffer: CVPixelBuffer
	
    init() {
				var buffer: CVPixelBuffer!
				let status = CVPixelBufferCreate(
					kCFAllocatorDefault,
					Int(targetSize.width),
					Int(targetSize.height),
					kCVPixelFormatType_32ARGB,
					nil,
					&buffer
				)
				guard status == kCVReturnSuccess else {
					fatalError("Failed to create pixel buffer")
				}
				inputPixelBuffer = buffer
			
        coordinator = VideoWatchingCoordinator(playbackCoordinator: player.playbackCoordinator)
        observePlayback()
        Task {
            await configureAudioSession()
            await observeSharedVideo()
						try! setupModel()
        }
    }
		private func setupModel() throws {
			print("Loading model...")
			
			let clock = ContinuousClock()
			let start = clock.now
			
			model = try DepthAnythingV2SmallF16()
			
			let duration = clock.now - start
			print("Model loaded (took \(duration.formatted(.units(allowed: [.seconds, .milliseconds]))))")

		}
	
    func makePlayerViewController() -> AVPlayerViewController {
        let delegate = PlayerViewControllerDelegate(player: self)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = delegate

        playerViewController = controller
        playerViewControllerDelegate = delegate

        return controller
    }

    private func observePlayback() {
        guard subscriptions.isEmpty else { return }

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] status in
                self?.isPlaying = status == .playing
            }
            .store(in: &subscriptions)

        NotificationCenter.default
            .publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .map { _ in true }
            .sink { [weak self] isPlaybackComplete in
                self?.isPlaybackComplete = isPlaybackComplete
            }
            .store(in: &subscriptions)

        NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let result = InterruptionResult(notification) else { return }
                if result.type == .ended && result.options == .shouldResume {
                    self?.player.play()
                }
            }.store(in: &subscriptions)

        addTimeObserver()
    }

    private func configureAudioSession() async {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
        } catch {
            print("Unable to configure audio session: \(error.localizedDescription)")
        }
    }

    private func observeSharedVideo() async {
        let current = currentItem
        await coordinator.$sharedVideo
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .filter { $0 != current }
            .sink { [weak self] video in
                guard let self else { return }
                loadVideo(video)
            }
            .store(in: &subscriptions)
    }

    func loadVideo(_ video: Video, autoplay: Bool = true) {
        currentItem = video
        shouldAutoPlay = autoplay
        isPlaybackComplete = false

				replaceCurrentItem(with: video)

        configureAudioExperience()

   }
	
		private func performInference(_ pixelBuffer: CVPixelBuffer) -> CIImage? {
			guard let model else {
				return nil
			}
			let originalSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
			let inputImage = CIImage(cvPixelBuffer: pixelBuffer).resized(to: targetSize)
			context.render(inputImage, to: inputPixelBuffer)
			let result = try! model.prediction(image: inputPixelBuffer)
			let outputImage = CIImage(cvPixelBuffer: result.depth)
				.resized(to: originalSize)
			return outputImage
		}

	
    private func replaceCurrentItem(with video: Video) {
				let asset = AVAsset(url: video.url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.externalMetadata = createMetadataItems(for: video)
        player.replaceCurrentItem(with: playerItem)
        print("🍿 \(video.title) enqueued for playback.")
				let filter = CIFilter.sepiaTone()
				AVVideoComposition.videoComposition(with: asset) { request in
					let pixelBuffer = request.sourceImage.pixelBuffer!
					let outputImage = self.performInference(pixelBuffer)
					request.finish(with: outputImage ?? request.sourceImage, context: nil)
//					filter.inputImage = request.sourceImage
//					request.finish(with: filter.outputImage ?? request.sourceImage, context: nil)
				} completionHandler: { [weak player] videoComposition, error in
					playerItem.videoComposition = videoComposition
					player?.play()
				}
    }

    func reset() {
        currentItem = nil
        player.replaceCurrentItem(with: nil)
        playerViewController = nil
        playerViewControllerDelegate = nil
    }

    private func createMetadataItems(for video: Video) -> [AVMetadataItem] {
        let mapping: [AVMetadataIdentifier: Any] = [
            .commonIdentifierTitle: video.title,
        ]
        return mapping.compactMap { createMetadataItem(for: $0, value: $1) }
    }

    private func createMetadataItem(for identifier: AVMetadataIdentifier,
                                    value: Any) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as? NSCopying & NSObjectProtocol
        item.extendedLanguageTag = "und"
        return item.copy() as! AVMetadataItem
    }

    private func configureAudioExperience() {
        let experience: AVAudioSessionSpatialExperience
        experience = .headTracked(soundStageSize: .small, anchoringStrategy: .front)
        try! AVAudioSession.sharedInstance().setIntendedSpatialExperience(experience)
    }

    // MARK: - Transport Control

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func togglePlayback() {
        player.timeControlStatus == .paused ? play() : pause()
    }

    // MARK: - Time Observation

    private func addTimeObserver() {
        removeTimeObserver()
        let timeInterval = CMTime(value: 1, timescale: 1)
        timeObserver = player.addPeriodicTimeObserver(forInterval: timeInterval, queue: .main) { [weak self] time in
            guard let self = self, let duration = player.currentItem?.duration else { return }
            let isInProposalRange = time.seconds >= duration.seconds - 10.0
            if shouldProposeNextVideo != isInProposalRange {
                shouldProposeNextVideo = isInProposalRange
            }
        }
    }

    private func removeTimeObserver() {
        guard let timeObserver = timeObserver else { return }
        player.removeTimeObserver(timeObserver)
        self.timeObserver = nil
    }

    final class PlayerViewControllerDelegate: NSObject, AVPlayerViewControllerDelegate {

        let player: PlayerModel

        init(player: PlayerModel) {
            self.player = player
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            Task { @MainActor in
                player.reset()
            }
        }
    }
}

struct InterruptionResult {

    let type: AVAudioSession.InterruptionType
    let options: AVAudioSession.InterruptionOptions

    init?(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? AVAudioSession.InterruptionType,
              let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? AVAudioSession.InterruptionOptions else {
            return nil
        }
        self.type = type
        self.options = options
    }
}
