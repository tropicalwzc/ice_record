import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            AssetsView()
                .tabItem {
                    Label("资产", systemImage: "list.bullet.rectangle.portrait")
                }

            TrendView()
                .tabItem {
                    Label("走势", systemImage: "chart.xyaxis.line")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    RootTabView()
        .environment(AssetStore())
        .environment(SyncCoordinator(database: .shared, transport: DisabledSyncTransport()))
}
