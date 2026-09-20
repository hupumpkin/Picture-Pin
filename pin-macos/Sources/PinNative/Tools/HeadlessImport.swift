import Foundation

/// `--import <path>...`（§3.7）：不开窗口导入一批文件，供快照与人工验收。
///
/// 走的是**真导入流水线**（`WorkspaceModel.importFiles` → `ImportCoordinator`），
/// 和工具栏按钮同一条路：验收的人先在这里导入 TestAssets，再打开 App 看画布上
/// 的图——「导入写进库了」和「画布摆对了」在同一次验收里一次看清。
///
/// 默认写真实 profile 的数据目录（那是人工验收要看的库）；自动化流程传
/// `--data-dir <目录>` 打临时目录，绝不在没人看着的时候碰真实数据。
///
/// 退出码：全部成功 0，任一被拒 1——脚本可以直接拿它判断。
@MainActor
enum HeadlessImport {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--import")
    }

    static func runAndExit() async -> Never {
        let parsed = parse(arguments: CommandLine.arguments)
        guard !parsed.paths.isEmpty else {
            FileHandle.standardError.write(Data("""
            用法：--import <path>... [--data-dir <目录>]
              --import 之后的参数是文件路径，遇到下一个 -- 开头的参数停止；
              --data-dir 覆盖数据目录（默认是启动 profile 的真实目录）。
            """.utf8))
            exit(2)
        }

        let environment = AppEnvironment.resolveForLaunch(
            dataDirectoryOverride: parsed.dataDirectory
        )
        print("导入 \(parsed.paths.count) 个文件到：\(environment.dataDirectory.path)")

        let model = WorkspaceModel(environment: environment)
        await model.recoverStorage()
        guard model.storageError == nil else {
            FileHandle.standardError.write(Data(
                "素材库没准备好：\(model.storageError ?? "未知原因")\n".utf8
            ))
            exit(1)
        }
        // Same startup path as the UI: default board must be durable before import.

        let urls = parsed.paths.map { URL(fileURLWithPath: $0) }
        let outcomes = await model.importFiles(urls)
        for url in urls {
            if let outcome = outcomes[url] {
                print("  \(outcome.message)（\(url.lastPathComponent)）")
            }
        }

        let summary = ImportFeedback.summary(of: outcomes, orderedBy: urls)
        switch summary {
        case .importing, .nothingToPaste:
            // 都不可达：`.importing` 是上面已经 await 完整批；
            // `.nothingToPaste` 只从粘贴那条通道产生，而这条路径收的是文件。
            exit(1)
        case .canvasSaveFailed(let stored, let rejected, let reason):
            print("素材库已存入 \(stored) 张，但画布未保存；另有 \(rejected) 张被拒：\(reason)")
            exit(1)
        case .finished(let imported, let rejected, _):
            print("完成：导入 \(imported) 张，拒绝 \(rejected) 张")
            if let writer = model.writer {
                // 写调度器的账本（§3.1）：提交/落库/重排队。重排队不是 0 就说明
                // 有写入失败后重试过——人工验收时这一行是「数据真的写进去了」的旁证。
                print(
                    "写调度器：收活 \(writer.submittedCount)、提交 \(writer.commitCount)、"
                    + "重排队 \(writer.requeueCount)"
                )
            }
            exit(rejected == 0 ? 0 : 1)
        }
    }

    /// 参数解析。纯函数，自检直接断言。
    ///
    /// `--import` 之后依次收路径，遇到下一个 `--` 开头的参数停止；
    /// `--data-dir` 在路径段里也认（自动化的习惯写法是把它放最后）。
    static func parse(arguments: [String]) -> (paths: [String], dataDirectory: URL?) {
        guard let importIndex = arguments.firstIndex(of: "--import") else {
            return ([], nil)
        }
        var paths: [String] = []
        var dataDirectory: URL?
        var index = importIndex + 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--data-dir", index + 1 < arguments.count {
                dataDirectory = URL(fileURLWithPath: arguments[index + 1])
                index += 2
                continue
            }
            if argument.hasPrefix("--") { break }
            paths.append(argument)
            index += 1
        }
        return (paths, dataDirectory)
    }
}
