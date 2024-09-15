import SwiftUI

struct ContentView: View {

    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack {
            PlayerView()
                .task {
										let videoURL: URL = Bundle.main.url(forResource: "mario_s", withExtension: "mp4")!
//                    let video = Video(id: 1, url: URL(string: "http://playgrounds-cdn.apple.com/assets/beach/index.m3u8")!, title: "Day3 Video")
										let video = Video(id: 1, url: videoURL, title: "Day3 Video")
                    player.loadVideo(video)
								}
            Button("Play") {
                player.play()
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(PlayerModel())
}
