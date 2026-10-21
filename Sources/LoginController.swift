import Foundation
import ServiceManagement

@MainActor
final class LoginController {
    init() {}

    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    var statusDescription: String {
        switch status {
        case .enabled:
            return "开机自动启动已开启"
        case .notRegistered:
            return "开机自动启动已关闭"
        case .requiresApproval:
            return "开机自动启动待系统批准"
        case .notFound:
            return "无法找到自启服务，请检查应用安装位置"
        @unknown default:
            return "开机自动启动状态未知"
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled,
                  service.status != .requiresApproval else { return }
            try service.register()
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
