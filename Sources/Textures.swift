import Foundation

// All art is generated in code, so the project needs no image assets.

let TEX = 64

@inline(__always)
func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
    let rr = UInt32(max(0, min(255, r)))
    let gg = UInt32(max(0, min(255, g)))
    let bb = UInt32(max(0, min(255, b)))
    return rr | (gg << 8) | (bb << 16) | 0xFF00_0000
}

@inline(__always)
func hash2(_ x: Int, _ y: Int, _ seed: Int = 0) -> Int {
    var h = x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 1_442_695_041
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h = h ^ (h >> 16)
    return h & 0xFF
}

@inline(__always)
func shadeColor(_ c: UInt32, _ s: Int) -> UInt32 {
    let r = (Int(c & 0xFF) * s) >> 8
    let g = (Int((c >> 8) & 0xFF) * s) >> 8
    let b = (Int((c >> 16) & 0xFF) * s) >> 8
    return UInt32(min(255, r)) | (UInt32(min(255, g)) << 8) | (UInt32(min(255, b)) << 16) | 0xFF00_0000
}

func makeTexture(_ f: (Int, Int) -> UInt32) -> [UInt32] {
    var out = [UInt32](repeating: 0, count: TEX * TEX)
    for y in 0..<TEX {
        for x in 0..<TEX {
            out[y * TEX + x] = f(x, y)
        }
    }
    return out
}

let texTech: [UInt32] = makeTexture { (x: Int, y: Int) -> UInt32 in
    var v = 110 + hash2(x, y) % 14
    let mx = x % 32
    let my = y % 32
    if mx == 0 || my == 0 { v -= 45 }
    if mx == 1 || my == 1 { v += 20 }
    if (mx == 4 || mx == 27) && (my == 4 || my == 27) { v += 50 }
    if y >= 12 && y < 16 { return rgb(v - 40, v - 10, v + 25) }
    return rgb(v, v + 4, v + 10)
}

let texBrick: [UInt32] = makeTexture { (x: Int, y: Int) -> UInt32 in
    let row = y / 16
    let xo = (x + (row % 2) * 16) % 32
    if y % 16 == 0 || xo == 0 { return rgb(60, 50, 45) }
    let n = hash2(x / 2, y / 2, row)
    return rgb(150 + n % 30, 80 + n % 20, 55 + n % 15)
}

let texGreen: [UInt32] = makeTexture { (x: Int, y: Int) -> UInt32 in
    var g = 120 + hash2(x, y, 3) % 16
    if x % 16 == 0 { g -= 50 }
    if y % 32 < 3 { g -= 30 }
    if x % 16 == 15 { g += 20 }
    return rgb(g / 3, g, g / 3 + 10)
}

let texRed: [UInt32] = makeTexture { (x: Int, y: Int) -> UInt32 in
    if y >= 48 {
        let stripe = ((x + y) / 8) % 2 == 0
        return stripe ? rgb(220, 190, 20) : rgb(30, 30, 30)
    }
    let n = hash2(x, y, 5) % 20
    var r = 130 + n
    if y % 16 == 0 { r -= 50 }
    return rgb(r, 25 + n / 2, 25 + n / 2)
}

let texDoor: [UInt32] = makeTexture { (x: Int, y: Int) -> UInt32 in
    let n = hash2(x, y, 7) % 12
    if x == 32 || x == 31 { return rgb(30, 30, 35) }
    if y < 6 || y >= 58 { return rgb(200 + n, 170 + n, 20) }
    var base = 150 + n
    if y % 16 == 0 { base -= 40 }
    return rgb(base - 10, base, base + 15)
}

let texExit: [UInt32] = makeTexture { (x: Int, y: Int) -> UInt32 in
    let n = hash2(x, y, 9) % 10
    if x >= 14 && x < 50 && y >= 14 && y < 50 {
        if x < 17 || x >= 47 || y < 17 || y >= 47 { return rgb(230, 230, 230) }
        return rgb(30 + n, 200 + n, 40 + n)
    }
    return rgb(70 + n, 70 + n, 80 + n)
}

let texFloor: [UInt32] = makeTexture { (x: Int, y: Int) -> UInt32 in
    var v = 70 + hash2(x, y, 11) % 12
    if x % 32 == 0 || y % 32 == 0 { v -= 25 }
    return rgb(v, v - 5, v - 10)
}

let texSlime: [UInt32] = makeTexture { (x: Int, y: Int) -> UInt32 in
    let n = hash2(x / 4, y / 4, 13) % 40
    return rgb(30 + n / 2, 120 + n * 2, 30)
}

let texCeil: [UInt32] = makeTexture { (x: Int, y: Int) -> UInt32 in
    if x >= 24 && x < 40 && y >= 24 && y < 40 { return rgb(235, 235, 200) }
    var v = 55 + hash2(x, y, 17) % 8
    if x % 32 == 0 || y % 32 == 0 { v -= 20 }
    return rgb(v, v, v + 6)
}

// Index = wall type (1...6). 5 = door, 6 = exit switch.
let wallTextures: [[UInt32]] = [[], texTech, texBrick, texGreen, texRed, texDoor, texExit]

// MARK: - Sprites (u, v in 0...1, v = 0 is the top)

@inline(__always)
func inCircle(_ u: Double, _ v: Double, _ cx: Double, _ cy: Double, _ r: Double) -> Bool {
    let dx = u - cx
    let dy = v - cy
    return dx * dx + dy * dy <= r * r
}

@inline(__always)
func inRect(_ u: Double, _ v: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Bool {
    return u >= x0 && u <= x1 && v >= y0 && v <= y1
}

func enemyPixel(kind: Int, u: Double, v: Double, walk: Bool, hurt: Bool, corpse: Bool) -> UInt32? {
    if corpse {
        let a = (u - 0.5) / 0.38
        let b = (v - 0.93) / 0.07
        if a * a + b * b <= 1.0 {
            return kind == 0 ? rgb(110, 50, 35) : rgb(90, 40, 40)
        }
        return nil
    }
    var c: UInt32? = nil
    let ls = walk ? 0.04 : 0.0
    let imp = (kind == 0)

    if inRect(u, v, 0.36 - ls, 0.62, 0.48 - ls, 1.0) || inRect(u, v, 0.52 + ls, 0.62, 0.64 + ls, 1.0) {
        c = imp ? rgb(95, 55, 35) : rgb(60, 70, 50)
    }
    if inRect(u, v, 0.34, 0.30, 0.66, 0.64) {
        c = imp ? rgb(140, 80, 50) : rgb(95, 115, 75)
        if inRect(u, v, 0.34, 0.54, 0.66, 0.58) { c = rgb(40, 30, 20) }
    }
    if inRect(u, v, 0.22, 0.32, 0.34, 0.58) || inRect(u, v, 0.66, 0.32, 0.78, 0.58) {
        c = imp ? rgb(150, 90, 60) : rgb(150, 125, 100)
    }
    if inCircle(u, v, 0.5, 0.2, 0.12) {
        c = imp ? rgb(160, 95, 65) : rgb(165, 135, 110)
        if inCircle(u, v, 0.45, 0.19, 0.022) || inCircle(u, v, 0.55, 0.19, 0.022) {
            c = rgb(255, 230, 40)
        }
    }
    if imp {
        if inRect(u, v, 0.38, 0.05, 0.42, 0.12) || inRect(u, v, 0.58, 0.05, 0.62, 0.12) {
            c = rgb(230, 220, 200)
        }
    } else {
        if inRect(u, v, 0.38, 0.07, 0.62, 0.12) { c = rgb(70, 90, 60) }
        if inRect(u, v, 0.66, 0.42, 0.88, 0.47) { c = rgb(50, 50, 55) }
    }
    if hurt && c != nil { return rgb(255, 210, 210) }
    return c
}

func pickupPixel(kind: Int, u: Double, v: Double) -> UInt32? {
    if kind == 0 {
        if inRect(u, v, 0.15, 0.2, 0.85, 0.95) {
            if inRect(u, v, 0.43, 0.3, 0.57, 0.85) || inRect(u, v, 0.28, 0.5, 0.72, 0.65) {
                return rgb(210, 20, 20)
            }
            return rgb(235, 235, 235)
        }
        return nil
    }
    if inRect(u, v, 0.2, 0.35, 0.8, 0.95) {
        if inRect(u, v, 0.2, 0.55, 0.8, 0.62) { return rgb(40, 40, 30) }
        return rgb(200, 165, 40)
    }
    return nil
}

func fireballPixel(u: Double, v: Double) -> UInt32? {
    let dx = u - 0.5
    let dy = v - 0.5
    let d = (dx * dx + dy * dy).squareRoot()
    if d > 0.45 { return nil }
    if d < 0.2 { return rgb(255, 240, 120) }
    return rgb(255, 120 + Int(d * 100.0), 20)
}
