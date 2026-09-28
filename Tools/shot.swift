// Renders a local HTML file to a PNG at its natural content height.
import Foundation
import WebKit
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: shot <in.html> <out.png> [width]"); exit(1) }
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let width = args.count > 3 ? Double(args[3])! : 1200

final class Shooter: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let out: URL
    init(width: Double, out: URL) {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800), configuration: cfg)
        self.out = out
        super.init()
        web.navigationDelegate = self
    }
    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        // Let fonts and gradients settle, then measure the real height.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            w.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                let h = (result as? NSNumber)?.doubleValue ?? 1200
                w.frame = NSRect(x: 0, y: 0, width: w.frame.width, height: h)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let cfg = WKSnapshotConfiguration()
                    cfg.rect = NSRect(x: 0, y: 0, width: w.frame.width, height: h)
                    cfg.snapshotWidth = NSNumber(value: w.frame.width * 2)   // 2x for retina
                    w.takeSnapshot(with: cfg) { image, err in
                        guard let image, let tiff = image.tiffRepresentation,
                              let rep = NSBitmapImageRep(data: tiff),
                              let png = rep.representation(using: .png, properties: [:]) else {
                            print("snapshot failed: \(err?.localizedDescription ?? "?")"); exit(1)
                        }
                        try? png.write(to: self.out)
                        print("wrote \(self.out.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
                        exit(0)
                    }
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let s = Shooter(width: width, out: outURL)
s.web.loadFileURL(inURL, allowingReadAccessTo: inURL.deletingLastPathComponent())
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("timeout"); exit(1) }
app.run()
