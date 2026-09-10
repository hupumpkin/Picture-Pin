import SwiftUI

struct AnalysisWorkspaceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("待归类分析")
                            .font(.largeTitle.weight(.semibold))
                        Text("从截图证据开始，整理成可行动的设计判断")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("新建分析", systemImage: "plus") { }
                        .buttonStyle(.borderedProminent)
                }

                ForEach(PreviewData.analyses) { item in
                    HStack(spacing: 18) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.10))
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 54, height: 54)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title)
                                .font(.headline)
                            HStack(spacing: 10) {
                                Text("\(item.imageCount) 张截图")
                                Text(item.completed ? "已完成" : "待提问")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()

                        HStack(spacing: -8) {
                            ForEach(0..<min(item.imageCount, 4), id: \.self) { index in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(CapturePalette(rawValue: index % 6)?.background ?? .gray)
                                    .frame(width: 38, height: 52)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            }
                        }
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                }
            }
            .frame(maxWidth: 900)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("分析")
        .toolbar {
            Button("AI 设置", systemImage: "gearshape") { }
        }
    }
}
