import Foundation

let MAP_W = 36
let MAP_H = 24

enum GameState {
    case playing
    case dead
    case won
}

struct InputState {
    var forward = 0.0     // -1...1
    var strafe = 0.0      // -1...1 (right positive)
    var turnRate = 0.0    // -1...1 (right positive), scaled per second
    var lookDelta = 0.0   // radians to turn this frame (touch drag)
    var fire = false
    var restart = false
}

struct Enemy {
    var x: Double
    var y: Double
    var kind: Int          // 0 = imp, 1 = zombieman
    var hp: Int
    var alive = true
    var alerted = false
    var cooldown = 1.0
    var hurt = 0.0
    var anim = 0.0
    var moving = false
}

struct Pickup {
    var x: Double
    var y: Double
    var kind: Int          // 0 = medkit, 1 = ammo
    var taken = false
}

struct Projectile {
    var x: Double
    var y: Double
    var dx: Double
    var dy: Double
    var life: Double
}

final class Game {
    var map = [Int](repeating: 0, count: MAP_W * MAP_H)
    var floorType = [UInt8](repeating: 0, count: MAP_W * MAP_H)
    var doorOpen = [Double](repeating: 0, count: MAP_W * MAP_H)
    var doorCells: [Int] = []
    var exitCells: [Int] = []

    var px = 3.5
    var py = 11.5
    var angle = 0.0

    var health = 100
    var ammo = 50
    var kills = 0
    var totalEnemies = 0

    var enemies: [Enemy] = []
    var pickups: [Pickup] = []
    var projectiles: [Projectile] = []

    var state: GameState = .playing
    var stateTime = 0.0
    var time = 0.0

    var fireCooldown = 0.0
    var muzzle = 0.0
    var recoil = 0.0
    var hurtFlash = 0.0
    var bob = 0.0
    var slimeTimer = 0.0

    var message = ""
    var messageTime = 0.0

    var onFire: (() -> Void)?
    var onHurt: (() -> Void)?

    init() {
        reset()
    }

    func reset() {
        map = [Int](repeating: 0, count: MAP_W * MAP_H)
        floorType = [UInt8](repeating: 0, count: MAP_W * MAP_H)
        doorOpen = [Double](repeating: 0, count: MAP_W * MAP_H)
        doorCells = []
        exitCells = []
        enemies = []
        pickups = []
        projectiles = []

        for (y, row) in mapRows.enumerated() {
            for (x, ch) in row.enumerated() {
                if x >= MAP_W || y >= MAP_H { continue }
                let i = y * MAP_W + x
                let cx = Double(x) + 0.5
                let cy = Double(y) + 0.5
                switch ch {
                case "#": map[i] = 1
                case "B": map[i] = 2
                case "G": map[i] = 3
                case "R": map[i] = 4
                case "D":
                    map[i] = 5
                    doorCells.append(i)
                case "X":
                    map[i] = 6
                    exitCells.append(i)
                case "~": floorType[i] = 1
                case "P":
                    px = cx
                    py = cy
                case "e": enemies.append(Enemy(x: cx, y: cy, kind: 0, hp: 60))
                case "z": enemies.append(Enemy(x: cx, y: cy, kind: 1, hp: 20))
                case "h": pickups.append(Pickup(x: cx, y: cy, kind: 0))
                case "a": pickups.append(Pickup(x: cx, y: cy, kind: 1))
                default: break
                }
            }
        }

        angle = 0
        health = 100
        ammo = 50
        kills = 0
        totalEnemies = enemies.count
        state = .playing
        stateTime = 0
        time = 0
        fireCooldown = 0
        muzzle = 0
        recoil = 0
        hurtFlash = 0
        slimeTimer = 0
        say("E1M1: HANGAR - FIND THE EXIT")
    }

    func say(_ s: String) {
        message = s
        messageTime = 3.0
    }

    // MARK: - Collision / rays

    func cell(_ x: Int, _ y: Int) -> Int {
        if x < 0 || y < 0 || x >= MAP_W || y >= MAP_H { return 1 }
        return map[y * MAP_W + x]
    }

    func solidAt(_ fx: Double, _ fy: Double) -> Bool {
        let cx = Int(fx.rounded(.down))
        let cy = Int(fy.rounded(.down))
        let c = cell(cx, cy)
        if c == 0 { return false }
        if c == 5 { return doorOpen[cy * MAP_W + cx] < 0.75 }
        return true
    }

    func canStand(_ x: Double, _ y: Double, _ r: Double) -> Bool {
        if solidAt(x - r, y - r) { return false }
        if solidAt(x + r, y - r) { return false }
        if solidAt(x - r, y + r) { return false }
        if solidAt(x + r, y + r) { return false }
        return true
    }

    /// Distance along a normalised direction to the first wall / closed door.
    func wallDist(_ ox: Double, _ oy: Double, _ dx: Double, _ dy: Double) -> Double {
        var mapX = Int(ox.rounded(.down))
        var mapY = Int(oy.rounded(.down))
        let ddx = dx == 0 ? 1e30 : abs(1.0 / dx)
        let ddy = dy == 0 ? 1e30 : abs(1.0 / dy)
        var sdx: Double
        var sdy: Double
        let stepX: Int
        let stepY: Int
        if dx < 0 {
            stepX = -1
            sdx = (ox - Double(mapX)) * ddx
        } else {
            stepX = 1
            sdx = (Double(mapX) + 1.0 - ox) * ddx
        }
        if dy < 0 {
            stepY = -1
            sdy = (oy - Double(mapY)) * ddy
        } else {
            stepY = 1
            sdy = (Double(mapY) + 1.0 - oy) * ddy
        }
        var dist = 0.0
        for _ in 0..<80 {
            if sdx < sdy {
                dist = sdx
                sdx += ddx
                mapX += stepX
            } else {
                dist = sdy
                sdy += ddy
                mapY += stepY
            }
            let c = cell(mapX, mapY)
            if c != 0 {
                if c == 5 && doorOpen[mapY * MAP_W + mapX] >= 0.98 { continue }
                return dist
            }
        }
        return 100
    }

    func hasLineOfSight(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Bool {
        let dx = bx - ax
        let dy = by - ay
        let d = (dx * dx + dy * dy).squareRoot()
        if d < 0.01 { return true }
        return wallDist(ax, ay, dx / d, dy / d) >= d - 0.05
    }

    // MARK: - Damage

    func damagePlayer(_ n: Int) {
        if state != .playing { return }
        health -= n
        hurtFlash = 0.6
        onHurt?()
        if health <= 0 {
            health = 0
            state = .dead
            stateTime = 0
            say("YOU DIED")
        }
    }

    // MARK: - Update

    func update(_ dt: Double, _ inp: inout InputState) {
        time += dt
        stateTime += dt
        if messageTime > 0 { messageTime -= dt }
        if hurtFlash > 0 { hurtFlash = max(0, hurtFlash - dt * 2.0) }
        if muzzle > 0 { muzzle -= dt }
        if recoil > 0 { recoil = max(0, recoil - dt * 4.0) }
        if fireCooldown > 0 { fireCooldown -= dt }

        updateDoors(dt)

        if state != .playing {
            inp.lookDelta = 0
            if inp.restart && stateTime > 1.0 {
                reset()
            }
            inp.restart = false
            updateEnemies(dt, active: false)
            return
        }
        inp.restart = false

        // Turning
        angle += inp.turnRate * 2.8 * dt + inp.lookDelta
        inp.lookDelta = 0

        // Movement
        var f = max(-1.0, min(1.0, inp.forward))
        var s = max(-1.0, min(1.0, inp.strafe))
        let len = (f * f + s * s).squareRoot()
        if len > 1.0 {
            f /= len
            s /= len
        }
        let dirX = cos(angle)
        let dirY = sin(angle)
        let speed = 3.6
        let mx = (dirX * f - dirY * s) * speed * dt
        let my = (dirY * f + dirX * s) * speed * dt
        if canStand(px + mx, py, 0.25) { px += mx }
        if canStand(px, py + my, 0.25) { py += my }
        if len > 0.05 { bob += dt * 9.0 }

        // Slime
        let ci = Int(py.rounded(.down)) * MAP_W + Int(px.rounded(.down))
        if ci >= 0 && ci < floorType.count && floorType[ci] == 1 {
            slimeTimer += dt
            if slimeTimer >= 0.7 {
                slimeTimer = 0
                damagePlayer(4)
            }
        } else {
            slimeTimer = 0
        }

        // Firing
        if inp.fire && fireCooldown <= 0 {
            if ammo > 0 {
                shoot(dirX, dirY)
            } else {
                fireCooldown = 0.6
                say("OUT OF AMMO")
            }
        }

        updateEnemies(dt, active: true)
        updateProjectiles(dt)
        updatePickups()

        // Exit
        for i in exitCells {
            let ex = Double(i % MAP_W) + 0.5
            let ey = Double(i / MAP_W) + 0.5
            let d = ((px - ex) * (px - ex) + (py - ey) * (py - ey)).squareRoot()
            if d < 1.15 && state == .playing {
                state = .won
                stateTime = 0
                say("LEVEL COMPLETE")
            }
        }
    }

    func shoot(_ dirX: Double, _ dirY: Double) {
        ammo -= 1
        fireCooldown = 0.38
        muzzle = 0.08
        recoil = 1.0
        onFire?()

        let wd = wallDist(px, py, dirX, dirY)
        var best = -1
        var bestT = wd
        for (i, e) in enemies.enumerated() where e.alive {
            let ex = e.x - px
            let ey = e.y - py
            let t = ex * dirX + ey * dirY
            if t <= 0 || t >= bestT { continue }
            let perp = abs(ex * dirY - ey * dirX)
            if perp < 0.42 {
                best = i
                bestT = t
            }
        }
        if best >= 0 {
            let dmg = 5 * Int.random(in: 1...3)
            enemies[best].hp -= dmg
            enemies[best].hurt = 0.18
            enemies[best].alerted = true
            if enemies[best].hp <= 0 {
                enemies[best].alive = false
                enemies[best].moving = false
                kills += 1
            }
        }
        // Gunshots wake up nearby enemies.
        for i in 0..<enemies.count where enemies[i].alive && !enemies[i].alerted {
            let dx = enemies[i].x - px
            let dy = enemies[i].y - py
            if dx * dx + dy * dy < 100 && hasLineOfSight(enemies[i].x, enemies[i].y, px, py) {
                enemies[i].alerted = true
            }
        }
    }

    func updateDoors(_ dt: Double) {
        for i in doorCells {
            let cx = Double(i % MAP_W) + 0.5
            let cy = Double(i / MAP_W) + 0.5
            var near = false
            if state == .playing {
                let dx = px - cx
                let dy = py - cy
                near = (dx * dx + dy * dy).squareRoot() < 2.0
            }
            if !near {
                for e in enemies where e.alive {
                    let dx = e.x - cx
                    let dy = e.y - cy
                    if (dx * dx + dy * dy).squareRoot() < 1.5 {
                        near = true
                        break
                    }
                }
            }
            let target = near ? 1.0 : 0.0
            let cur = doorOpen[i]
            if cur < target {
                doorOpen[i] = min(target, cur + dt * 2.0)
            } else if cur > target {
                doorOpen[i] = max(target, cur - dt * 1.5)
            }
        }
    }

    func updateEnemies(_ dt: Double, active: Bool) {
        for i in 0..<enemies.count {
            var e = enemies[i]
            if !e.alive { continue }
            e.anim += dt
            if e.hurt > 0 { e.hurt -= dt }
            if e.cooldown > 0 { e.cooldown -= dt }
            e.moving = false

            if !active {
                enemies[i] = e
                continue
            }

            let dx = px - e.x
            let dy = py - e.y
            let dist = max(0.001, (dx * dx + dy * dy).squareRoot())
            let ux = dx / dist
            let uy = dy / dist

            if !e.alerted && dist < 11 && hasLineOfSight(e.x, e.y, px, py) {
                e.alerted = true
            }

            if e.alerted {
                let los = hasLineOfSight(e.x, e.y, px, py)
                let keepAway = (e.kind == 0) ? 1.1 : 3.5
                let speed = (e.kind == 0) ? 1.7 : 1.2
                if dist > keepAway {
                    let nx = e.x + ux * speed * dt
                    let ny = e.y + uy * speed * dt
                    if canStand(nx, e.y, 0.3) {
                        e.x = nx
                        e.moving = true
                    }
                    if canStand(e.x, ny, 0.3) {
                        e.y = ny
                        e.moving = true
                    }
                }
                if e.cooldown <= 0 {
                    if e.kind == 0 {
                        if dist < 1.4 {
                            damagePlayer(Int.random(in: 3...8))
                            e.cooldown = 1.0
                        } else if los && dist < 14 {
                            projectiles.append(Projectile(x: e.x, y: e.y, dx: ux * 5.5, dy: uy * 5.5, life: 6))
                            e.cooldown = 2.0
                        }
                    } else if los && dist < 14 {
                        if Double.random(in: 0...1) < 0.55 {
                            damagePlayer(Int.random(in: 3...8))
                        }
                        e.cooldown = 1.4
                    }
                }
            }
            enemies[i] = e
        }
    }

    func updateProjectiles(_ dt: Double) {
        var i = 0
        while i < projectiles.count {
            var p = projectiles[i]
            p.x += p.dx * dt
            p.y += p.dy * dt
            p.life -= dt
            var remove = p.life <= 0 || solidAt(p.x, p.y)
            if !remove {
                let dx = p.x - px
                let dy = p.y - py
                if dx * dx + dy * dy < 0.12 {
                    damagePlayer(Int.random(in: 8...16))
                    remove = true
                }
            }
            if remove {
                projectiles.remove(at: i)
            } else {
                projectiles[i] = p
                i += 1
            }
        }
    }

    func updatePickups() {
        for i in 0..<pickups.count where !pickups[i].taken {
            let dx = pickups[i].x - px
            let dy = pickups[i].y - py
            if dx * dx + dy * dy > 0.4 { continue }
            if pickups[i].kind == 0 {
                if health < 100 {
                    health = min(100, health + 25)
                    pickups[i].taken = true
                    say("PICKED UP A MEDKIT")
                }
            } else {
                if ammo < 200 {
                    ammo = min(200, ammo + 12)
                    pickups[i].taken = true
                    say("PICKED UP AMMO")
                }
            }
        }
    }
}
