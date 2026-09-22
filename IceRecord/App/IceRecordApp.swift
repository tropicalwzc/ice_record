import SwiftUI
import UIKit

@main
struct IceRecordApp: App {
    /// 全局唯一的数据源；初始化时会打开本地 SQLite 并载入已有数据
    @State private var store: AssetStore
    /// iCloud 同步
    @State private var sync: SyncCoordinator

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let database = AppDatabase.shared
        // iCloud 云盘文件同步：条目一个文件，快照按年分片，没有总容量上限。
        let transport: SyncTransport = FileSyncTransport()

        let store = AssetStore(database: database)
        let coordinator = SyncCoordinator(database: database, transport: transport)
        coordinator.onRemoteChanges = { [weak store] in
            store?.reloadFromDatabase()
        }
        store.onLocalMutation = { [weak coordinator] in
            coordinator?.scheduleSync()
        }

        _store = State(initialValue: store)
        _sync = State(initialValue: coordinator)

        SyncLog.info("App 启动，同步位置：\(transport.containerIdentifier ?? "无")")
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(sync)
                .task {
                    // 启动先同步一次，把其他设备的改动回灌进来
                    await sync.performInitialSync()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                sync.syncOnAppear()
            }
        }
    }
}
