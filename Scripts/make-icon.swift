// Draws the app icon and writes every size the Mac needs into an .appiconset folder:
//
//     swift Scripts/make-icon.swift TranscriptIsland/Assets.xcassets/AppIcon.appiconset
//
// The icon is the app in miniature: the black island with a white waveform, casting a soft
// shadow, on a blue rounded square.

import AppKit
import SwiftUI

struct IconView: View {
    // Apple's macOS icon grid: an 824 pt rounded square centered on a 1024 pt canvas.
    private let plate = RoundedRectangle(cornerRadius: 185, style: .continuous)
    private let barHeights: [CGFloat] = [70, 128, 166, 110, 62]

    var body: some View {
        ZStack {
            plate
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.42, green: 0.78, blue: 1.00),
                        Color(red: 0.20, green: 0.52, blue: 1.00),
                        Color(red: 0.30, green: 0.33, blue: 0.96),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay {
                    // Soft light from above.
                    plate.fill(RadialGradient(
                        colors: [.white.opacity(0.38), .white.opacity(0)],
                        center: UnitPoint(x: 0.5, y: -0.05), startRadius: 0, endRadius: 640
                    ))
                }
                .overlay {
                    plate.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .center),
                        lineWidth: 3
                    )
                }
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 10)

            island
        }
        .frame(width: 1024, height: 1024)
    }

    private var island: some View {
        Capsule(style: .continuous)
            .fill(.black)
            .frame(width: 624, height: 252)
            .overlay {
                Capsule(style: .continuous).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 3
                )
            }
            // Layered, soft shadows, like the app's island.
            .shadow(color: Color(red: 0.03, green: 0.08, blue: 0.35).opacity(0.55), radius: 48, y: 36)
            .shadow(color: .black.opacity(0.28), radius: 12, y: 8)
            .overlay {
                HStack(spacing: 32) {
                    ForEach(barHeights.indices, id: \.self) { index in
                        Capsule().fill(.white).frame(width: 42, height: barHeights[index])
                    }
                }
            }
            .offset(y: -8)
    }
}

/// The sizes of a Mac app icon, in pixels.
let pixelSizes = [16, 32, 64, 128, 256, 512, 1024]

/// (point size, scale) pairs for the asset catalog, each pointing at one of the files above.
let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <AppIcon.appiconset folder>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

try MainActor.assumeIsolated {
    for pixels in pixelSizes {
        // Rendered from vectors at each size, not scaled down from the largest.
        let renderer = ImageRenderer(content: IconView())
        renderer.scale = CGFloat(pixels) / 1024
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            fatalError("couldn't render the \(pixels) px icon")
        }
        try png.write(to: folder.appendingPathComponent("icon_\(pixels).png"))
    }
}

let images = slots.map { slot in
    """
        {
          "filename" : "icon_\(slot.points * slot.scale).png",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.points)x\(slot.points)"
        }
    """
}.joined(separator: ",\n")
let contents = """
    {
      "images" : [
    \(images)
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
try contents.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(pixelSizes.count) sizes to \(folder.path)")
