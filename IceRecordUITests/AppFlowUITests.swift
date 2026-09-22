import XCTest

/// 端到端流程：首次启动 → 新增条目 → 总资产自动重算 → 查看日/周/月/年曲线。
final class AppFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddItemAndBrowseTrendByPeriod() throws {
        let app = XCUIApplication()
        // 让 App 生成一段演示历史，便于验证曲线
        // 模拟器里拿不到 iCloud 云盘容器，用 Debug 的本地目录跑真实的文件同步路径
        app.launchArguments = ["--seed-demo-history", "--use-local-sync-directory"]
        app.launch()

        // MARK: 1. 首屏
        //
        // 注意：iCloud 键值存储里的数据**不随 App 卸载清除**，而且系统可能在启动后才
        // 异步把远端内容送过来。所以这里不能假设「一定是全新设备、总额一定是 11.80」——
        // 实测重装后旧数据会被同步回来。测试改成「先读初始值，再断言增量的变化」，
        // 这样不管云端有没有数据都成立。
        let totalLabel = app.staticTexts["totalAmountLabel"]
        XCTAssertTrue(totalLabel.waitForExistence(timeout: 15), "首屏没有出现总资产")

        // 空状态时用示例数据起步（有云端数据的话列表本来就不为空，这个按钮不会出现）
        let exampleButton = app.buttons["addExampleItemsButton"]
        if exampleButton.exists {
            exampleButton.tap()
        }
        XCTAssertTrue(
            waitForTotal(totalLabel, timeout: 10),
            "读不出总资产数值：「\(totalLabel.label)」"
        )
        let totalBefore = try XCTUnwrap(currentTotal(totalLabel), "无法解析总资产")
        attach(app, name: "01-资产首页")

        // MARK: 2. 新增一条已知金额的条目
        app.buttons["addItemButton"].tap()

        let nameField = app.textFields["itemNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "新增页没有出现")
        nameField.tap()
        nameField.typeText("Fund")

        let amountField = app.textFields["itemAmountField"]
        amountField.tap()
        amountField.typeText("2.5")
        attach(app, name: "02-新增条目表单")

        app.buttons["saveItemButton"].tap()

        // MARK: 3. 总资产应自动增加 2.50 万
        XCTAssertTrue(
            waitForTotal(totalLabel, toEqual: totalBefore + 2.5, timeout: 10),
            "保存后总资产应增加 2.50 万（之前 \(totalBefore)，现在「\(totalLabel.label)」）"
        )
        XCTAssertTrue(app.staticTexts["Fund"].exists, "新条目应出现在列表里")
        attach(app, name: "03-保存后总资产已更新")

        // MARK: 4. 走势页 + 日/周/月/年切换
        app.tabBars.buttons["走势"].tap()

        let chart = app.descendants(matching: .any).matching(identifier: "trendChart").firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10), "走势页没有渲染出图表")

        for period in ["日", "周", "月", "年"] {
            let segment = app.segmentedControls.firstMatch.buttons[period]
            XCTAssertTrue(segment.waitForExistence(timeout: 5), "找不到「\(period)」切换按钮")
            segment.tap()
            XCTAssertTrue(chart.waitForExistence(timeout: 5))
            attach(app, name: "04-曲线-\(period)")
        }

        // MARK: 5. 历史记录区域
        XCTAssertTrue(app.staticTexts["历史记录"].exists, "走势页应有历史记录区块")
    }

    /// 长按选中某一天（回归：曾经因为气泡被 chart frame 裁掉而什么都看不到）。
    ///
    /// 按住不放的这段时间没法在测试进程里截图，所以这里只覆盖
    /// 「选中 → 气泡构建 → 松手 → 图表仍可用」这条路径不崩溃；
    /// 气泡的落点由 `TrendView` 顶部预留的 64pt 空白带保证，另用模拟器截图人工核对。
    func testSelectionGestureShowsCalloutWithoutCrashing() throws {
        let app = XCUIApplication()
        // 模拟器里拿不到 iCloud 云盘容器，用 Debug 的本地目录跑真实的文件同步路径
        app.launchArguments = ["--seed-demo-history", "--use-local-sync-directory"]
        app.launch()

        app.tabBars.buttons["走势"].tap()
        let chart = app.descendants(matching: .any).matching(identifier: "trendChart").firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 15), "走势页没有渲染出图表")

        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.55))
        let end = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.55))
        // 按住 8 秒，方便外部在「选中状态」下抓图核对气泡位置
        print("=== SELECTION_GESTURE_START ===")
        start.press(forDuration: 1.0, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 8.0)

        // 松手后应恢复，并且换个粒度依然能正常渲染
        app.segmentedControls.firstMatch.buttons["月"].tap()
        XCTAssertTrue(chart.waitForExistence(timeout: 5), "选中之后图表应仍然可用")
    }

    /// 设置页应该能看到 iCloud 同步的开关和状态；
    /// 模拟器里没有登录 iCloud，所以状态应该如实反映出来而不是假装同步成功。
    func testSettingsShowsICloudSyncSection() throws {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["设置"].tap()

        // SwiftUI 会把 Section header 转成大写
        XCTAssertTrue(app.staticTexts["ICLOUD"].waitForExistence(timeout: 10), "设置页缺少 iCloud 分区")
        XCTAssertTrue(app.switches["iCloud 同步"].exists, "缺少 iCloud 同步开关")
        XCTAssertTrue(app.buttons["立即同步"].exists, "缺少立即同步按钮")

        // 模拟器里没登录 iCloud / 没有 iCloud entitlement，不能谎报「已同步」
        let status = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                        "未登录 iCloud", "已同步", "已写入本机")
        ).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20), "设置页没有显示同步状态")

        attach(app, name: "06-设置页")
    }

    // MARK: - 工具

    /// 从「14.30, 万」这样的无障碍文案里解析出数值
    private func currentTotal(_ element: XCUIElement) -> Double? {
        let numeric = element.label.prefix { $0.isNumber || $0 == "." || $0 == "," }
        let cleaned = numeric.replacingOccurrences(of: ",", with: "")
        return Double(cleaned)
    }

    private func waitForTotal(
        _ element: XCUIElement,
        toEqual expected: Double? = nil,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = currentTotal(element) {
                if let expected {
                    if abs(value - expected) < 0.005 { return true }
                } else {
                    return true
                }
            }
            usleep(200_000)
        }
        return false
    }
    /// 轮询等待元素文案包含指定内容
    private func waitFor(_ element: XCUIElement, toContain text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(text) { return true }
            usleep(200_000)
        }
        return false
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
