import Foundation

/// 把剪贴板里的位图字节落成一个临时文件，好让它能走**和其他两条通道完全一样**
/// 的导入流水线（§7 第 3 条）。
///
/// ## 为什么要绕这一下
///
/// `AssetStore.ingest` 的入参是一个 URL，它做的是"复制 → 哈希 → 读属性 → 入库"。
/// 位图没有 URL，看上去需要给它单开一条 `ingest(data:)`。不这么做，是因为
/// 那条路的每一段都要重写一遍，而"重写一遍"的历史教训很具体：**导入政策
/// （超大文件拒绝）会只在文件那条路上生效**，粘贴进来的巨图绕过它，落盘之后
/// 每次全档解码都可能顶穿内存（§3.9）。
///
/// 落一个临时文件，位图就和文件选择器选的图走同一条路：同一个上限、同一套
/// 失败清理、同一套属性读取。多出来的一步是写盘，代价是一次本地复制。
///
/// ## 每个文件一个独立目录
///
/// 临时文件放在 `临时目录/pin-paste/<UUID>/` 里。放进独立目录是为了删除时
/// 一次 `removeItem` 就把目录连同文件一起清掉——只删文件的话，粘贴一百次
/// 会在临时目录里留下一个空目录，而且没人会去看那里。
struct TemporaryImageWriter {

    /// 临时文件的根目录。默认系统临时目录；自检指到自己的临时目录里，
    /// 跑完自己清干净。
    var root: URL = FileManager.default.temporaryDirectory

    /// 写入一份字节。**调用方负责删除**（返回值所在的目录整个删掉即可）。
    ///
    /// - Returns: 落盘后的 URL。它的扩展名决定了 `AssetStore` 的落盘后缀，
    ///   所以名字里必须带 `.png`。
    func write(_ data: Data, named name: String) throws -> URL {
        let directory = root
            .appendingPathComponent("pin-paste", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 名字里的路径分隔符要去掉：`suggestedName` 是我们自己造的，但现在
        // 也允许调用方传，而带 `/` 的名字会让写入跑到目录外面去。
        let filename = name.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 删掉 `write` 造出来的那一整个目录。删不掉不算错：临时目录由系统回收，
    /// 为它抛错会把一次成功的导入变成失败。
    func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
