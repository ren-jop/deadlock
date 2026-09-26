import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: make_icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

func scaledRect(
    _ x: CGFloat,
    _ y: CGFloat,
    _ width: CGFloat,
    _ height: CGFloat,
    size: CGFloat
) -> NSRect {
    NSRect(
        x: x * size,
        y: y * size,
        width: width * size,
        height: height * size
    )
}

func renderIcon(size: Int) throws -> Data {
    let dimension = CGFloat(size)

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ),
    let context = NSGraphicsContext(
        bitmapImageRep: bitmap
    )
    else {
        throw NSError(
            domain: "deadlock.icon",
            code: 1
        )
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let full = NSRect(
        x: 0,
        y: 0,
        width: dimension,
        height: dimension
    )
    NSColor.clear.setFill()
    full.fill()

    let inset = dimension * 0.045
    let backgroundRect = full.insetBy(
        dx: inset,
        dy: inset
    )
    let background = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: dimension * 0.225,
        yRadius: dimension * 0.225
    )

    let gradient = NSGradient(
        colors: [
            NSColor(
                calibratedRed: 0.035,
                green: 0.038,
                blue: 0.055,
                alpha: 1
            ),
            NSColor(
                calibratedRed: 0.075,
                green: 0.066,
                blue: 0.115,
                alpha: 1
            )
        ]
    )!
    gradient.draw(
        in: background,
        angle: -52
    )

    NSColor(
        calibratedWhite: 1,
        alpha: 0.055
    ).setStroke()
    background.lineWidth =
        max(1, dimension * 0.008)
    background.stroke()

    // Crescent moon: a subtle anime/night-guardian cue without borrowing
    // any copyrighted character or franchise artwork.
    let moonOuter = NSBezierPath(
        ovalIn: scaledRect(
            0.13,
            0.55,
            0.38,
            0.38,
            size: dimension
        )
    )
    let moonCutout = NSBezierPath(
        ovalIn: scaledRect(
            0.245,
            0.62,
            0.30,
            0.30,
            size: dimension
        )
    )
    moonOuter.append(moonCutout)
    moonOuter.windingRule = .evenOdd

    NSColor(
        calibratedRed: 0.78,
        green: 0.78,
        blue: 0.96,
        alpha: 0.96
    ).setFill()
    moonOuter.fill()

    // Guardian sparkle.
    let starCenter = NSPoint(
        x: dimension * 0.76,
        y: dimension * 0.76
    )
    let star = NSBezierPath()
    star.move(
        to: NSPoint(
            x: starCenter.x,
            y: starCenter.y
                + dimension * 0.075
        )
    )
    star.line(
        to: NSPoint(
            x: starCenter.x
                + dimension * 0.026,
            y: starCenter.y
                + dimension * 0.018
        )
    )
    star.line(
        to: NSPoint(
            x: starCenter.x
                + dimension * 0.075,
            y: starCenter.y
        )
    )
    star.line(
        to: NSPoint(
            x: starCenter.x
                + dimension * 0.026,
            y: starCenter.y
                - dimension * 0.018
        )
    )
    star.line(
        to: NSPoint(
            x: starCenter.x,
            y: starCenter.y
                - dimension * 0.075
        )
    )
    star.line(
        to: NSPoint(
            x: starCenter.x
                - dimension * 0.026,
            y: starCenter.y
                - dimension * 0.018
        )
    )
    star.line(
        to: NSPoint(
            x: starCenter.x
                - dimension * 0.075,
            y: starCenter.y
        )
    )
    star.line(
        to: NSPoint(
            x: starCenter.x
                - dimension * 0.026,
            y: starCenter.y
                + dimension * 0.018
        )
    )
    star.close()

    NSColor(
        calibratedRed: 0.92,
        green: 0.91,
        blue: 1.0,
        alpha: 0.9
    ).setFill()
    star.fill()

    // Lock shackle.
    let shackleRect = scaledRect(
        0.34,
        0.35,
        0.32,
        0.34,
        size: dimension
    )
    let shackle = NSBezierPath(
        roundedRect: shackleRect,
        xRadius: dimension * 0.15,
        yRadius: dimension * 0.15
    )
    shackle.lineWidth =
        max(2, dimension * 0.062)
    shackle.lineCapStyle = .round

    NSColor(
        calibratedRed: 0.83,
        green: 0.84,
        blue: 0.93,
        alpha: 1
    ).setStroke()
    shackle.stroke()

    // Lock body.
    let bodyRect = scaledRect(
        0.255,
        0.17,
        0.49,
        0.40,
        size: dimension
    )
    let body = NSBezierPath(
        roundedRect: bodyRect,
        xRadius: dimension * 0.085,
        yRadius: dimension * 0.085
    )

    let bodyGradient = NSGradient(
        colors: [
            NSColor(
                calibratedRed: 0.22,
                green: 0.21,
                blue: 0.31,
                alpha: 1
            ),
            NSColor(
                calibratedRed: 0.13,
                green: 0.13,
                blue: 0.19,
                alpha: 1
            )
        ]
    )!
    bodyGradient.draw(
        in: body,
        angle: -90
    )

    NSColor(
        calibratedRed: 0.82,
        green: 0.81,
        blue: 0.97,
        alpha: 0.55
    ).setStroke()
    body.lineWidth =
        max(1, dimension * 0.008)
    body.stroke()

    // Two restrained "guardian eyes" make the mark feel anime-adjacent while
    // still reading first and foremost as a lock at small sizes.
    let eyeColor = NSColor(
        calibratedRed: 0.72,
        green: 0.79,
        blue: 1.0,
        alpha: 0.88
    )
    eyeColor.setStroke()

    for direction: CGFloat in [-1, 1] {
        let eye = NSBezierPath()
        let cx =
            dimension * (
                direction < 0
                ? 0.405
                : 0.595
            )
        eye.move(
            to: NSPoint(
                x: cx - dimension * 0.045,
                y: dimension * 0.41
            )
        )
        eye.line(
            to: NSPoint(
                x: cx + dimension * 0.045,
                y: dimension * 0.385
            )
        )
        eye.lineWidth =
            max(1.5, dimension * 0.014)
        eye.lineCapStyle = .round
        eye.stroke()
    }

    // Keyhole.
    NSColor(
        calibratedRed: 0.035,
        green: 0.038,
        blue: 0.055,
        alpha: 0.95
    ).setFill()

    let keyCircle = NSBezierPath(
        ovalIn: scaledRect(
            0.467,
            0.275,
            0.066,
            0.066,
            size: dimension
        )
    )
    keyCircle.fill()

    let keyStem = NSBezierPath(
        roundedRect: scaledRect(
            0.485,
            0.22,
            0.03,
            0.09,
            size: dimension
        ),
        xRadius: dimension * 0.012,
        yRadius: dimension * 0.012
    )
    keyStem.fill()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(
        using: .png,
        properties: [:]
    ) else {
        throw NSError(
            domain: "deadlock.icon",
            code: 2
        )
    }

    return png
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in variants {
    let data = try renderIcon(
        size: size
    )
    try data.write(
        to: outputDirectory
            .appendingPathComponent(name),
        options: .atomic
    )
}
