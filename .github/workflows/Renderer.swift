import UIKit

let PLANE_LEN = 0.78

struct SpriteItem {
    var dist: Double
    var kind: Int      // 0 enemy, 1 pickup, 2 projectile
    var idx: Int
}

final class Renderer {
    let w: Int
    let h: Int
    let pixels: UnsafeMutablePointer<UInt32>
    var zbuf: [Double]
    let ctx: CGContext
    let focal: Double

    init(width: Int, height: Int) {
        let buf = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
        buf.initialize(repeating: 0xFF00_0000, count: width * height)
        let cs = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: buf,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        w = width
        h = height
        pixels = buf
        ctx = context
        zbuf = [Double](repeating: 0, count: width)
        focal = Double(width) / 2.0 / PLANE_LEN
    }

    deinit {
        pixels.deallocate()
    }

    func makeImage() -> UIImage? {
        guard let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Frame

    func render(_ g: Game) {
        let halfH = h / 2
        let dirX = cos(g.angle)
        let dirY = sin(g.angle)
        let planeX = -dirY * PLANE_LEN
        let planeY = dirX * PLANE_LEN
        let px = g.px
        let py = g.py

        drawFloorAndCeiling(g, halfH: halfH, dirX: dirX, dirY: dirY, planeX: planeX, planeY: planeY)
        drawWalls(g, halfH: halfH, dirX: dirX, dirY: dirY, planeX: planeX, planeY: planeY)
        drawSprites(g, halfH: halfH, dirX: dirX, dirY: dirY, planeX: planeX, planeY: planeY, px: px, py: py)
        drawWeapon(g)
        drawCrosshair(halfH: halfH)
        applyTint(g)
    }

    private func drawFloorAndCeiling(_ g: Game, halfH: Int, dirX: Double, dirY: Double, planeX: Double, planeY: Double) {
        let rx0 = dirX - planeX
        let ry0 = dirY - planeY
        let rx1 = dirX + planeX
        let ry1 = dirY + planeY
        let slimeShift = Int(g.time * 10.0)
        let floorTex = texFloor
        let slimeTex = texSlime
        let ceilTex = texCeil

        for y in halfH..<h {
            let p = Double(y - halfH) + 0.5
            let rowDist = 0.5 * focal / p
            let sh = max(30, 256 - Int(rowDist * 18.0))
            let stepX = rowDist * (rx1 - rx0) / Double(w)
            let stepY = rowDist * (ry1 - ry0) / Double(w)
            var fx = g.px + rowDist * rx0
            var fy = g.py + rowDist * ry0
            let rowF = y * w
            let rowC = (h - 1 - y) * w

            for x in 0..<w {
                let cxI = Int(fx.rounded(.down))
                let cyI = Int(fy.rounded(.down))
                let tx = Int((fx - Double(cxI)) * 64.0) & 63
                let ty = Int((fy - Double(cyI)) * 64.0) & 63

                var isSlime = false
                if cxI >= 0 && cyI >= 0 && cxI < MAP_W && cyI < MAP_H {
                    isSlime = g.floorType[cyI * MAP_W + cxI] == 1
                }
                let fc: UInt32
                var shade = sh
                if isSlime {
                    let sty = (ty + slimeShift) & 63
                    let stx = (tx + slimeShift / 2) & 63
                    fc = slimeTex[sty * 64 + stx]
                    shade = max(sh, 170)
                } else {
                    fc = floorTex[ty * 64 + tx]
                }
                pixels[rowF + x] = shadeColor(fc, shade)
                pixels[rowC + x] = shadeColor(ceilTex[ty * 64 + tx], sh)

                fx += stepX
                fy += stepY
            }
        }
    }

    private func drawWalls(_ g: Game, halfH: Int, dirX: Double, dirY: Double, planeX: Double, planeY: Double) {
        let px = g.px
        let py = g.py

        for x in 0..<w {
            let camX = 2.0 * Double(x) / Double(w) - 1.0
            let rdx = dirX + planeX * camX
            let rdy = dirY + planeY * camX
            var mapX = Int(px.rounded(.down))
            var mapY = Int(py.rounded(.down))
            let ddx = rdx == 0 ? 1e30 : abs(1.0 / rdx)
            let ddy = rdy == 0 ? 1e30 : abs(1.0 / rdy)
            var sdx: Double
            var sdy: Double
            let stepX: Int
            let stepY: Int
            if rdx < 0 {
                stepX = -1
                sdx = (px - Double(mapX)) * ddx
            } else {
                stepX = 1
                sdx = (Double(mapX) + 1.0 - px) * ddx
            }
            if rdy < 0 {
                stepY = -1
                sdy = (py - Double(mapY)) * ddy
            } else {
                stepY = 1
                sdy = (Double(mapY) + 1.0 - py) * ddy
            }

            var side = 0
            var hitType = 0
            var steps = 0
            while steps < 80 {
                steps += 1
                if sdx < sdy {
                    sdx += ddx
                    mapX += stepX
                    side = 0
                } else {
                    sdy += ddy
                    mapY += stepY
                    side = 1
                }
                let c = g.cell(mapX, mapY)
                if c != 0 {
                    if c == 5 && g.doorOpen[mapY * MAP_W + mapX] >= 0.98 { continue }
                    hitType = c
                    break
                }
            }

            if hitType == 0 {
                zbuf[x] = 1e9
                continue
            }

            var perp = side == 0 ? (sdx - ddx) : (sdy - ddy)
            if perp < 0.05 { perp = 0.05 }
            zbuf[x] = perp

            var wallX = side == 0 ? (py + perp * rdy) : (px + perp * rdx)
            wallX -= wallX.rounded(.down)
            var texX = Int(wallX * 64.0) & 63
            if side == 0 && rdx > 0 { texX = 63 - texX }
            if side == 1 && rdy < 0 { texX = 63 - texX }

            let lineH = Int(focal / perp)
            let top = halfH - lineH / 2
            let bottom = halfH + lineH / 2
            var doorF = 0.0
            var visibleBottom = bottom
            if hitType == 5 {
                doorF = g.doorOpen[mapY * MAP_W + mapX]
                visibleBottom = bottom - Int(doorF * Double(lineH))
            }
            let yStart = max(0, top)
            let yEnd = min(h, visibleBottom)
            if yStart >= yEnd { continue }

            var sh = max(30, 256 - Int(perp * 18.0))
            if side == 1 { sh = (sh * 205) >> 8 }
            let tex = wallTextures[hitType]
            let invLine = 1.0 / Double(max(1, lineH))

            for y in yStart..<yEnd {
                let v = Double(y - top) * invLine + doorF
                let texY = Int(v * 64.0) & 63
                pixels[y * w + x] = shadeColor(tex[texY * 64 + texX], sh)
            }
        }
    }

    private func drawSprites(_ g: Game, halfH: Int, dirX: Double, dirY: Double, planeX: Double, planeY: Double, px: Double, py: Double) {
        var items: [SpriteItem] = []
        for (i, e) in g.enemies.enumerated() {
            let dx = e.x - px
            let dy = e.y - py
            items.append(SpriteItem(dist: dx * dx + dy * dy, kind: 0, idx: i))
        }
        for (i, p) in g.pickups.enumerated() where !p.taken {
            let dx = p.x - px
            let dy = p.y - py
            items.append(SpriteItem(dist: dx * dx + dy * dy, kind: 1, idx: i))
        }
        for (i, p) in g.projectiles.enumerated() {
            let dx = p.x - px
            let dy = p.y - py
            items.append(SpriteItem(dist: dx * dx + dy * dy, kind: 2, idx: i))
        }
        items.sort { $0.dist > $1.dist }

        let invDet = 1.0 / (planeX * dirY - dirX * planeY)

        for it in items {
            var sx = 0.0
            var sy = 0.0
            var scale = 1.0
            var lift = 0.0
            var widthRatio = 0.6
            var enemyKind = 0
            var walk = false
            var hurt = false
            var corpse = false
            var pickupKind = 0

            switch it.kind {
            case 0:
                let e = g.enemies[it.idx]
                sx = e.x
                sy = e.y
                scale = 0.85
                widthRatio = 0.6
                enemyKind = e.kind
                corpse = !e.alive
                hurt = e.hurt > 0
                walk = e.moving && (Int(e.anim * 5.0) % 2 == 0)
            case 1:
                let p = g.pickups[it.idx]
                sx = p.x
                sy = p.y
                scale = 0.35
                widthRatio = 1.0
                pickupKind = p.kind
            default:
                let p = g.projectiles[it.idx]
                sx = p.x
                sy = p.y
                scale = 0.28
                lift = 0.35
                widthRatio = 1.0
            }

            let rx = sx - px
            let ry = sy - py
            let tx = invDet * (dirY * rx - dirX * ry)
            let ty = invDet * (-planeY * rx + planeX * ry)
            if ty < 0.2 { continue }

            let screenX = Int(Double(w) / 2.0 * (1.0 + tx / ty))
            let hPx = Int(focal / ty * scale)
            if hPx < 1 || hPx > 4000 { continue }
            let wPx = Int(Double(hPx) * widthRatio)
            if wPx < 1 { continue }

            let bottom = halfH + Int(0.5 * focal / ty) - Int(lift * focal / ty)
            let top = bottom - hPx
            let left = screenX - wPx / 2
            let shade = max(40, 256 - Int(ty * 14.0))

            let x0 = max(0, left)
            let x1 = min(w, left + wPx)
            let y0 = max(0, top)
            let y1 = min(h, bottom)
            if x0 >= x1 || y0 >= y1 { continue }

            for x in x0..<x1 {
                if ty >= zbuf[x] { continue }
                let u = (Double(x - left) + 0.5) / Double(wPx)
                for y in y0..<y1 {
                    let v = (Double(y - top) + 0.5) / Double(hPx)
                    var c: UInt32? = nil
                    switch it.kind {
                    case 0:
                        c = enemyPixel(kind: enemyKind, u: u, v: v, walk: walk, hurt: hurt, corpse: corpse)
                    case 1:
                        c = pickupPixel(kind: pickupKind, u: u, v: v)
                    default:
                        c = fireballPixel(u: u, v: v)
                    }
                    if let col = c {
                        pixels[y * w + x] = it.kind == 2 ? col : shadeColor(col, shade)
                    }
                }
            }
        }
    }

    // MARK: - HUD pieces drawn into the frame

    private func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: UInt32) {
        let xa = max(0, x0)
        let xb = min(w, x1)
        let ya = max(0, y0)
        let yb = min(h, y1)
        if xa >= xb || ya >= yb { return }
        for y in ya..<yb {
            for x in xa..<xb {
                pixels[y * w + x] = c
            }
        }
    }

    private func fillCircle(_ cx: Int, _ cy: Int, _ r: Int, _ c: UInt32) {
        let ya = max(0, cy - r)
        let yb = min(h - 1, cy + r)
        let xa = max(0, cx - r)
        let xb = min(w - 1, cx + r)
        if ya > yb || xa > xb { return }
        for y in ya...yb {
            for x in xa...xb {
                let dx = x - cx
                let dy = y - cy
                if dx * dx + dy * dy <= r * r {
                    pixels[y * w + x] = c
                }
            }
        }
    }

    private func drawWeapon(_ g: Game) {
        let u = max(1, h / 90)
        let bobX = Int(sin(g.bob) * Double(2 * u))
        let bobY = Int(abs(cos(g.bob)) * Double(u))
        let recoilY = Int(g.recoil * Double(6 * u))
        let cx = w / 2 + bobX
        let oy = bobY + recoilY

        if g.muzzle > 0 {
            fillCircle(cx, h - 30 * u + oy, 7 * u, rgb(255, 170, 40))
            fillCircle(cx, h - 30 * u + oy, 4 * u, rgb(255, 245, 160))
        }
        // slide
        fill(cx - 4 * u, h - 26 * u + oy, cx + 4 * u, h - 12 * u + oy, rgb(115, 115, 125))
        fill(cx - 4 * u, h - 26 * u + oy, cx + 4 * u, h - 24 * u + oy, rgb(175, 175, 185))
        fill(cx - 1 * u, h - 28 * u + oy, cx + 1 * u, h - 26 * u + oy, rgb(60, 60, 65))
        // grip
        fill(cx - 3 * u, h - 12 * u + oy, cx + 3 * u, h, rgb(90, 60, 40))
        // hand
        fill(cx - 6 * u, h - 9 * u + oy, cx + 6 * u, h, rgb(205, 150, 120))
        fill(cx - 6 * u, h - 9 * u + oy, cx - 5 * u, h, rgb(160, 110, 85))
    }

    private func drawCrosshair(halfH: Int) {
        let c = rgb(255, 255, 255)
        let cx = w / 2
        fill(cx - 5, halfH, cx - 2, halfH + 1, c)
        fill(cx + 3, halfH, cx + 6, halfH + 1, c)
        fill(cx, halfH - 5, cx + 1, halfH - 2, c)
        fill(cx, halfH + 3, cx + 1, halfH + 6, c)
    }

    private func applyTint(_ g: Game) {
        let tint: Double
        if g.state == .dead {
            tint = 0.55
        } else {
            tint = g.hurtFlash * 0.6
        }
        if tint < 0.01 { return }
        let a = Int(tint * 256.0)
        let total = w * h
        for i in 0..<total {
            let c = pixels[i]
            let r = Int(c & 0xFF)
            let gg = Int((c >> 8) & 0xFF)
            let b = Int((c >> 16) & 0xFF)
            let nr = (r * (256 - a) + 255 * a) >> 8
            let ng = (gg * (256 - a)) >> 8
            let nb = (b * (256 - a)) >> 8
            pixels[i] = UInt32(min(255, nr)) | (UInt32(ng) << 8) | (UInt32(nb) << 16) | 0xFF00_0000
        }
    }
}
