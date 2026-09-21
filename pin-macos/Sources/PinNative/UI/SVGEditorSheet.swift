import SwiftUI
import WebKit

/// 可替换的 SVG 编辑器 Module。当前 Adapter 是零依赖的 DOM 编辑画布；未来接
/// `svgcanvas` 时，素材库与保存事务只需继续使用同一份「载入/回传 SVG」Interface。
struct SVGEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: WorkspaceModel.SVGEditingDocument
    let onSave: (WorkspaceModel.SVGEditingDocument) -> Void
    @State private var editedSource: String

    init(document: WorkspaceModel.SVGEditingDocument, onSave: @escaping (WorkspaceModel.SVGEditingDocument) -> Void) {
        self.document = document
        self.onSave = onSave
        _editedSource = State(initialValue: document.source)
    }

    var body: some View {
        SVGDOMEditor(source: document.source) { editedSource = $0 }
            .frame(minWidth: 940, minHeight: 620)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var saved = document
                        saved.source = editedSource
                        onSave(saved)
                        dismiss()
                    }.disabled(editedSource.isEmpty)
                }
            }
    }
}

private struct SVGDOMEditor: NSViewRepresentable {
    let source: String
    let onChange: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "svgEditor")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.html(source: source), baseURL: nil)
        return view
    }
    func updateNSView(_: WKWebView, context _: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator _: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "svgEditor")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onChange: (String) -> Void
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }
        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "svgEditor", let body = message.body as? [String: Any],
                  let source = body["source"] as? String else { return }
            onChange(source)
        }
    }

    private static func html(source: String) -> String {
        let encoded = Data(source.utf8).base64EncodedString()
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        *{box-sizing:border-box}body{margin:0;font:13px -apple-system,sans-serif;background:#f6f5f2;color:#222;display:grid;grid-template-columns:1fr 270px;height:100vh}.stage{display:grid;place-items:center;overflow:auto;background-image:radial-gradient(#d5d1c8 1px,transparent 1px);background-size:20px 20px}.stage svg{max-width:92%;max-height:92%;background:#fff;box-shadow:0 2px 18px #0002}.inspector{padding:18px;background:#202020;color:#eee;border-left:1px solid #444}.inspector h2{font-size:15px;margin:0 0 14px}.inspector label{display:block;color:#aaa;font-size:11px;margin:12px 0 4px}.inspector input{width:100%;border:1px solid #555;border-radius:5px;background:#303030;color:#fff;padding:7px}.hint{color:#aaa;line-height:1.5}[data-pin-editor-selected]{outline:2px solid #168cff;outline-offset:3px}[data-pin-editor-group]{outline:2px dashed #f36b3c;outline-offset:5px}.crumb{font-size:12px;color:#aaa;margin-bottom:14px}</style></head><body><main class="stage" id="stage"></main><aside class="inspector"><h2 id="title">选择一个元素</h2><div class="crumb" id="crumb">根 SVG</div><div id="fields" class="hint">点击线条、矩形或文本开始编辑。双击编组进入；按 Escape 回到上一层。</div></aside><script>
        const raw=atob('\(encoded)'),doc=new DOMParser().parseFromString(raw,'image/svg+xml');doc.querySelectorAll('script,foreignObject').forEach(n=>n.remove());doc.querySelectorAll('*').forEach(n=>[...n.attributes].filter(a=>a.name.startsWith('on')).forEach(a=>n.removeAttribute(a.name)));const svg=doc.documentElement;document.getElementById('stage').append(svg);let selected=null,group=null,drag=null;const emit=()=>{const copy=svg.cloneNode(true);copy.querySelectorAll('[data-pin-editor-selected],[data-pin-editor-group]').forEach(n=>{n.removeAttribute('data-pin-editor-selected');n.removeAttribute('data-pin-editor-group')});window.webkit.messageHandlers.svgEditor.postMessage({source:new XMLSerializer().serializeToString(copy)})};const field=(n,k)=>`<label>${n}</label><input data-k="${k}" value="${selected.getAttribute(k)||''}">`;function inspect(n){document.querySelectorAll('[data-pin-editor-selected]').forEach(x=>x.removeAttribute('data-pin-editor-selected'));selected=n;n.setAttribute('data-pin-editor-selected','');const t=n.tagName.toLowerCase();document.getElementById('title').textContent=t;let h=field('填充','fill')+field('描边','stroke')+field('描边粗细','stroke-width');if(t==='line')h+=field('起点 X','x1')+field('起点 Y','y1')+field('终点 X','x2')+field('终点 Y','y2');if(t==='rect')h+=field('X','x')+field('Y','y')+field('宽','width')+field('高','height')+field('圆角','rx');if(t==='text')h+=field('文字','textContent')+field('字号','font-size')+field('字重','font-weight');const box=document.getElementById('fields');box.innerHTML=h;box.querySelectorAll('input').forEach(i=>i.oninput=()=>{if(i.dataset.k==='textContent')selected.textContent=i.value;else selected.setAttribute(i.dataset.k,i.value);emit()})}function inside(n){return !group||n===group||group.contains(n)}svg.addEventListener('click',e=>{e.stopPropagation();if(e.target!==svg&&inside(e.target))inspect(e.target)});svg.addEventListener('dblclick',e=>{const g=e.target.closest('g');if(g){if(group)group.removeAttribute('data-pin-editor-group');group=g;g.setAttribute('data-pin-editor-group','');document.getElementById('crumb').textContent='编组：'+(g.id||'未命名')}});window.addEventListener('keydown',e=>{if(e.key==='Escape'&&group){group.removeAttribute('data-pin-editor-group');group=group.parentElement?.closest('g')||null;if(group)group.setAttribute('data-pin-editor-group','');document.getElementById('crumb').textContent=group?'编组：'+(group.id||'未命名'):'根 SVG'}});svg.addEventListener('pointerdown',e=>{if(selected===e.target){drag={x:e.clientX,y:e.clientY,tx:0,ty:0};svg.setPointerCapture(e.pointerId)}});svg.addEventListener('pointermove',e=>{if(!drag)return;drag.tx+=e.clientX-drag.x;drag.ty+=e.clientY-drag.y;drag.x=e.clientX;drag.y=e.clientY;selected.setAttribute('transform',`translate(${drag.tx} ${drag.ty})`)});svg.addEventListener('pointerup',e=>{if(drag){drag=null;emit();svg.releasePointerCapture(e.pointerId)}});</script></body></html>
        """
    }
}
