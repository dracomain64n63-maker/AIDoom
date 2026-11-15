import UIKit
import GameController

final class GameViewController: UIViewController {
    private let game = Game()
    private let renderer = Renderer(width: 320, height: 180)
    private let imageView = UIImageView()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    // Touch state
    private var moveTouch: UITouch?
    private var moveOrigin = CGPoint.zero
    private var moveCurrent = CGPoint.zero
    private var lookTouch: UITouch?
    private var lookLast = CGPoint.zero
    private var fireTouch: UITouch?
    private var lookAccum = 0.0
    private var restartRequested = false
    private var fireCenter = CGPoint.zero
    private var joyDefault = CGPoint.zero
    private let joyRadius: CGFloat = 60

    // Views
    private let joyBase = UIView()
    private let joyKnob = UIView()
    private let fireButton = UILabel()
    private let healthLabel = UILabel()
    private let ammoLabel = UILabel()
    private let killsLabel = UILabel()
    private let messageLabel = UILabel()
    private let overlayLabel = UILabel()

    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private var padConnected = false

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }
    override var shouldAutorotate: Bool { return true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { return .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.magnificationFilter = .nearest
        imageView.isUserInteractionEnabled = false
        view.addSubview(imageView)

        joyBase.backgroundColor = UIColor(white: 1, alpha: 0.12)
        joyBase.layer.borderColor = UIColor(white: 1, alpha: 0.4).cgColor
        joyBase.layer.borderWidth = 2
        joyBase.isUserInteractionEnabled = false
        view.addSubview(joyBase)

        joyKnob.backgroundColor = UIColor(white: 1, alpha: 0.4)
        joyKnob.isUserInteractionEnabled = false
        view.addSubview(joyKnob)

        fireButton.text = "FIRE"
        fireButton.font = UIFont.systemFont(ofSize: 20, weight: .heavy)
        fireButton.textColor = .white
        fireButton.textAlignment = .center
        fireButton.backgroundColor = UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 0.35)
        fireButton.layer.cornerRadius = 48
        fireButton.layer.borderWidth = 2
        fireButton.layer.borderColor = UIColor(white: 1, alpha: 0.5).cgColor
        fireButton.clipsToBounds = true
        fireButton.isUserInteractionEnabled = false
        view.addSubview(fireButton)

        styleLabel(healthLabel, size: 18, align: .left)
        styleLabel(ammoLabel, size: 18, align: .right)
        styleLabel(killsLabel, size: 18, align: .center)
        styleLabel(messageLabel, size: 16, align: .center)
        styleLabel(overlayLabel, size: 28, align: .center)
        overlayLabel.numberOfLines = 0
        overlayLabel.backgroundColor = UIColor(white: 0, alpha: 0.55)
        overlayLabel.isHidden = true

        game.onFire = { [weak self] in self?.lightImpact.impactOccurred() }
        game.onHurt = { [weak self] in self?.heavyImpact.impactOccurred() }
    }

    private func styleLabel(_ l: UILabel, size: CGFloat, align: NSTextAlignment) {
        l.font = UIFont.monospacedSystemFont(ofSize: size, weight: .heavy)
        l.textColor = UIColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1.0)
        l.textAlignment = align
        l.layer.shadowColor = UIColor.black.cgColor
        l.layer.shadowOpacity = 1
        l.layer.shadowRadius = 0
        l.layer.shadowOffset = CGSize(width: 2, height: 2)
        l.isUserInteractionEnabled = false
        view.addSubview(l)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = view.bounds
        let ins = view.safeAreaInsets
        imageView.frame = b
        healthLabel.frame = CGRect(x: ins.left + 16, y: ins.top + 8, width: 220, height: 28)
        ammoLabel.frame = CGRect(x: b.width - ins.right - 236, y: ins.top + 8, width: 220, height: 28)
        killsLabel.frame = CGRect(x: b.midX - 110, y: ins.top + 8, width: 220, height: 28)
        messageLabel.frame = CGRect(x: 0, y: ins.top + 40, width: b.width, height: 24)
        overlayLabel.frame = CGRect(x: 0, y: b.midY - 70, width: b.width, height: 140)
        fireCenter = CGPoint(x: b.width - ins.right - 100, y: b.height - max(ins.bottom, 20) - 90)
        fireButton.frame = CGRect(x: fireCenter.x - 48, y: fireCenter.y - 48, width: 96, height: 96)
        joyDefault = CGPoint(x: ins.left + 120, y: b.height - max(ins.bottom, 20) - 100)
        if moveTouch == nil {
            placeJoystick(base: joyDefault, knob: joyDefault)
        }
    }

    private func placeJoystick(base: CGPoint, knob: CGPoint) {
        let r = joyRadius + 5
        joyBase.frame = CGRect(x: base.x - r, y: base.y - r, width: r * 2, height: r * 2)
        joyBase.layer.cornerRadius = r
        joyKnob.frame = CGRect(x: knob.x - 28, y: knob.y - 28, width: 56, height: 56)
        joyKnob.layer.cornerRadius = 28
    }

    private func updateControlAlpha() {
        let a: CGFloat = padConnected ? 0.2 : 1.0
        joyBase.alpha = a
        joyKnob.alpha = a
        fireButton.alpha = a
    }

    // MARK: - Lifecycle

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startLoop()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
    }

    private func startLoop() {
        if displayLink != nil { return }
        lastTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        var dt = lastTimestamp == 0 ? 1.0 / 60.0 : link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        dt = min(max(dt, 0.001), 0.05)

        var inp = gatherInput()
        game.update(dt, &inp)
        renderer.render(game)
        imageView.image = renderer.makeImage()
        updateHUD()
    }

    // MARK: - Input gathering (touch + game controller + keyboard)

    private func deadzone(_ v: Double) -> Double {
        return abs(v) > 0.15 ? v : 0.0
    }

    private func gatherInput() -> InputState {
        var s = InputState()
        s.lookDelta = lookAccum
        lookAccum = 0
        s.restart = restartRequested
        restartRequested = false

        // Touch joystick
        if moveTouch != nil {
            var dx = (moveCurrent.x - moveOrigin.x) / joyRadius
            var dy = (moveCurrent.y - moveOrigin.y) / joyRadius
            let len = (dx * dx + dy * dy).squareRoot()
            if len > 1 {
                dx /= len
                dy /= len
            }
            if len > 0.12 {
                s.strafe = Double(dx)
                s.forward = Double(-dy)
            }
        }
        if fireTouch != nil { s.fire = true }

        // Game controllers (MFi / Xbox / PlayStation / Switch Pro)
        var havePad = false
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad else { continue }
            havePad = true
            s.strafe += deadzone(Double(pad.leftThumbstick.xAxis.value))
            s.forward += deadzone(Double(pad.leftThumbstick.yAxis.value))
            s.strafe += Double(pad.dpad.xAxis.value)
            s.forward += Double(pad.dpad.yAxis.value)
            s.turnRate += deadzone(Double(pad.rightThumbstick.xAxis.value))
            if pad.buttonA.isPressed || pad.rightTrigger.isPressed || pad.rightShoulder.isPressed || pad.buttonX.isPressed {
                s.fire = true
            }
            if pad.buttonA.isPressed || pad.buttonB.isPressed || pad.buttonX.isPressed || pad.buttonY.isPressed {
                s.restart = true
            }
        }
        if havePad != padConnected {
            padConnected = havePad
            updateControlAlpha()
        }

        // Hardware keyboard (WASD / arrows / space)
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            if kb.button(forKeyCode: .keyW)?.isPressed ?? false { s.forward += 1 }
            if kb.button(forKeyCode: .keyS)?.isPressed ?? false { s.forward -= 1 }
            if kb.button(forKeyCode: .keyD)?.isPressed ?? false { s.strafe += 1 }
            if kb.button(forKeyCode: .keyA)?.isPressed ?? false { s.strafe -= 1 }
            if kb.button(forKeyCode: .rightArrow)?.isPressed ?? false { s.turnRate += 1 }
            if kb.button(forKeyCode: .leftArrow)?.isPressed ?? false { s.turnRate -= 1 }
            if kb.button(forKeyCode: .upArrow)?.isPressed ?? false { s.forward += 1 }
            if kb.button(forKeyCode: .downArrow)?.isPressed ?? false { s.forward -= 1 }
            if kb.button(forKeyCode: .spacebar)?.isPressed ?? false {
                s.fire = true
                s.restart = true
            }
        }

        s.forward = max(-1.0, min(1.0, s.forward))
        s.strafe = max(-1.0, min(1.0, s.strafe))
        s.turnRate = max(-1.0, min(1.0, s.turnRate))
        return s
    }

    // MARK: - HUD

    private func updateHUD() {
        healthLabel.text = "HEALTH \(game.health)%"
        healthLabel.textColor = game.health < 30
            ? UIColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
            : UIColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1.0)
        ammoLabel.text = "AMMO \(game.ammo)"
        killsLabel.text = "KILLS \(game.kills)/\(game.totalEnemies)"
        messageLabel.text = game.messageTime > 0 ? game.message : ""

        switch game.state {
        case .playing:
            overlayLabel.isHidden = true
        case .dead:
            overlayLabel.isHidden = false
            overlayLabel.text = "YOU DIED\ntap / press A to restart"
        case .won:
            overlayLabel.isHidden = false
            overlayLabel.text = "E1M1 COMPLETE\nkills \(game.kills)/\(game.totalEnemies)\ntap / press A to play again"
        }
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        restartRequested = true
        for t in touches {
            let p = t.location(in: view)
            let fdx = p.x - fireCenter.x
            let fdy = p.y - fireCenter.y
            if fireTouch == nil && (fdx * fdx + fdy * fdy).squareRoot() < 80 {
                fireTouch = t
                fireButton.backgroundColor = UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 0.7)
                continue
            }
            if moveTouch == nil && p.x < view.bounds.width * 0.45 {
                moveTouch = t
                moveOrigin = p
                moveCurrent = p
                placeJoystick(base: p, knob: p)
                continue
            }
            if lookTouch == nil {
                lookTouch = t
                lookLast = p
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: view)
            if t === moveTouch {
                moveCurrent = p
                var dx = p.x - moveOrigin.x
                var dy = p.y - moveOrigin.y
                let len = (dx * dx + dy * dy).squareRoot()
                if len > joyRadius {
                    dx = dx / len * joyRadius
                    dy = dy / len * joyRadius
                }
                placeJoystick(base: moveOrigin, knob: CGPoint(x: moveOrigin.x + dx, y: moveOrigin.y + dy))
            } else if t === lookTouch {
                lookAccum += Double(p.x - lookLast.x) * 0.006
                lookLast = p
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        for t in touches {
            if t === moveTouch {
                moveTouch = nil
                placeJoystick(base: joyDefault, knob: joyDefault)
            }
            if t === lookTouch {
                lookTouch = nil
            }
            if t === fireTouch {
                fireTouch = nil
                fireButton.backgroundColor = UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 0.35)
            }
        }
    }
}
